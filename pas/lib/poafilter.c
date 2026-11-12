/* libpoa's filter (poa.h: poa_filter_encode and poa_filter_decode, through
   poalib.pas): the Ogg files inside a stream of any bytes, recompressed by
   POA; every other byte passed through as it was, for the archiver's own
   compressor. From PPA's ppafilter.c (itself from PJA's pjafilter.c, its
   version 1), with Ogg files.

   The filter's stream (doc/LIBRARY.md):

     "POAF" 01                     magic and version
     records, each a tag byte:
       00 n bytes                  n raw bytes (n a LEB128 number, >= 1)
       01 size n stream            a file of `size` bytes, as a .poa of n
                                   bytes (poaformat's PoaEncode)
       FF                          the end
     02 to FE are left for records of later releases: a decoder that meets
     one stops with POA_E_VERSION, as it does at a version past its own.

   The encoder finds a file by its first page (OggS, version 0, the flag
   that begins a logical stream), then walks whole pages (ogg_extent) until
   every stream it began has ended, or until the next bytes are not a page.
   A file that POA does not take, that does not come back byte for byte
   (the job verifies) or that does not get smaller stays raw; so do the
   bytes after it, and anything past MAX_FILE.

   Like the codec, this file calls no library: the host (poalib.pas) gives
   it memory and POA's codec through poafilter_host. */
#include <stddef.h>
#include <stdint.h>

#define POA_OK 0
#define POA_E_DATA 2
#define POA_E_MEMORY 3
#define POA_E_READ 4
#define POA_E_WRITE 5
#define POA_E_ARG 6
#define POA_E_VERSION 7

#if defined(_WIN32) && !defined(_WIN64)
#define POA_CALL __cdecl
#else
#define POA_CALL
#endif

typedef ptrdiff_t (POA_CALL *poa_read_fn)(void *ctx, void *buf, size_t size);
typedef int (POA_CALL *poa_write_fn)(void *ctx, const void *buf, size_t size);

/* what poalib.pas gives: memory, and a pool of threads that runs POA's
   codec on one file at a time each. A job is submitted, runs when a thread
   is free, and is waited for, in any order. Then ok is set and, when ok,
   out (from alloc) and out_size: encoding, POA's codec stream of the file
   (ok = 0 when POA does not take it); decoding, the file, which must be
   `expected` bytes. threads: how many threads the file's images may use. */
typedef struct {
  const uint8_t *in;
  size_t size, expected;
  uint8_t *out;
  size_t out_size;
  int ok, threads;
  volatile int done;  /* set by the pool */
  /* decoding, not ok: why, when it is not damage (POA_E_DATA): 1, the
     file's codec stream is of a later version (POA_E_VERSION); 2, there
     was no memory for it (POA_E_MEMORY) */
  int cause;
} job_t;
typedef struct {
  void *(*alloc)(size_t size);
  void (*release)(void *p);
  void *(*pool_open)(int threads, int encode);
  void (*pool_submit)(void *pool, job_t *job);
  void (*pool_wait)(void *pool, job_t *job);
  void (*pool_close)(void *pool);
} host_t;

static host_t H;

void poafilter_host(const host_t *h) { H = *h; }

enum {
  MAX_FILE = 256 << 20,         /* the largest file recompressed; past it, raw */
  WINDOW = 1 << 20,             /* the encoder's first buffer */
  RAW_RUN = 1 << 18,            /* the longest raw record */
  AHEAD_BYTES = 64 << 20,       /* the files' bytes in the pool at most */
  IOBUF = 1 << 16,              /* the decoder's read buffer */
  TAG_RAW = 0x00, TAG_FILE = 0x01, TAG_END = 0xFF
};
static const uint8_t MAGIC[5] = {'P', 'O', 'A', 'F', 1};

static void copy(uint8_t *d, const uint8_t *s, size_t n) {
  while (n--) *d++ = *s++;
}
static void move_down(uint8_t *d, const uint8_t *s, size_t n) {  /* d < s */
  while (n--) *d++ = *s++;
}

/* ---------- where an Ogg file ends ---------- */

enum { EXT_NOT = 0, EXT_MORE = -1 };
enum { OGG_HDR = 27, MAX_SERIALS = 64 };

/* p[0..n) at least 6 bytes: 0 when an Ogg file starts there (a page,
   version 0, that begins a logical stream), -1 if not */
static int signature(const uint8_t *p) {
  return (p[0] == 'O' && p[1] == 'g' && p[2] == 'g' && p[3] == 'S' && p[4] == 0 && (p[5] & 2)) ? 0 : -1;
}

/* Ogg's CRC-32 (polynomial 04C11DB7, not reflected, initial 0), with the
   CRC field counted as zeros */
static uint32_t crc_tab[256];
static void crc_init(void) {
  if (crc_tab[1]) return;
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t r = i << 24;
    for (int j = 0; j < 8; j++) r = (r & 0x80000000u) ? (r << 1) ^ 0x04C11DB7u : r << 1;
    crc_tab[i] = r;
  }
}
static uint32_t page_crc(const uint8_t *p, size_t n) {
  uint32_t c = 0;
  for (size_t i = 0; i < n; i++) {
    uint8_t b = (i >= 22 && i < 26) ? 0 : p[i];
    c = (c << 8) ^ crc_tab[((c >> 24) ^ b) & 0xFF];
  }
  return c;
}

static uint32_t rd32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* p[0..n): an Ogg file that starts with a page that begins a stream. Its
   length: whole pages, one after the other, up to the page after which
   every stream it began has ended (EOS), or up to where the next bytes are
   not a whole page (at the end of the input, eof). EXT_MORE if n bytes are
   not enough to tell. x keeps where it got to between calls on the same
   file with more bytes each time (start it as EXT_START), so that a long
   file is walked once. A page whose CRC does not match ends the file
   before it (a false signature, inside other data, has almost never a
   right CRC): what follows goes through as bytes and the search goes on. */
typedef struct { size_t i; int pages, nopen; uint32_t open[MAX_SERIALS]; } ext_t;
static const ext_t EXT_START = {0, 0, 0, {0}};
static ptrdiff_t ogg_extent(const uint8_t *p, size_t n, int eof, ext_t *x) {
  size_t i = x->i;
  crc_init();
  for (;;) {
    x->i = i;
    if (x->pages && !x->nopen) return (ptrdiff_t)i;
    if (i + OGG_HDR > n) {
      if (eof) return x->pages ? (ptrdiff_t)i : EXT_NOT;
      return EXT_MORE;
    }
    const uint8_t *h = p + i;
    if (!(h[0] == 'O' && h[1] == 'g' && h[2] == 'g' && h[3] == 'S' && h[4] == 0))
      return x->pages ? (ptrdiff_t)i : EXT_NOT;
    int nseg = h[26];
    if (i + OGG_HDR + (size_t)nseg > n) {
      if (eof) return x->pages ? (ptrdiff_t)i : EXT_NOT;
      return EXT_MORE;
    }
    size_t body = 0;
    for (int k = 0; k < nseg; k++) body += h[OGG_HDR + k];
    size_t end = i + OGG_HDR + (size_t)nseg + body;
    if (end > MAX_FILE) return x->pages ? (ptrdiff_t)i : EXT_NOT;
    if (end > n) {
      if (eof) return x->pages ? (ptrdiff_t)i : EXT_NOT;
      return EXT_MORE;
    }
    if (page_crc(h, end - i) != rd32(h + 22)) return x->pages ? (ptrdiff_t)i : EXT_NOT;
    uint32_t serial = rd32(h + 14);
    int k = 0;
    while (k < x->nopen && x->open[k] != serial) k++;
    if (h[5] & 2) {                               /* BOS: a stream begins */
      if (k == x->nopen) {
        /* a new stream once the first page is past and all others ended
           would be the next file; past MAX_SERIALS, the file ends here */
        if (x->nopen == MAX_SERIALS) return x->pages ? (ptrdiff_t)i : EXT_NOT;
        x->open[x->nopen++] = serial;
      }
    } else if (k == x->nopen) {                   /* a page of no stream begun here */
      return x->pages ? (ptrdiff_t)i : EXT_NOT;
    }
    if ((h[5] & 4) && k < x->nopen) {             /* EOS */
      x->open[k] = x->open[--x->nopen];
    }
    x->pages++;
    i = end;
  }
}

/* ---------- writing ---------- */

typedef struct {
  poa_write_fn write;
  void *ctx;
  int err;
} out_t;

static void put(out_t *o, const void *b, size_t n) {
  if (o->err || !n) return;
  if (o->write(o->ctx, b, n) != 0) o->err = POA_E_WRITE;
}
static void put_num(out_t *o, uint64_t v) {
  uint8_t b[10];
  int k = 0;
  do { b[k] = (uint8_t)(v & 0x7F); v >>= 7; if (v) b[k] |= 0x80; k++; } while (v);
  put(o, b, (size_t)k);
}
static void put_raw(out_t *o, const uint8_t *b, size_t n) {
  if (!n) return;
  uint8_t t = TAG_RAW;
  put(o, &t, 1); put_num(o, n); put(o, b, n);
}

/* ---------- the encoder ---------- */

/* Files go to the pool as they are found, up to 8 per thread (or
   AHEAD_BYTES) ahead of the oldest, which is written as soon as it is done,
   with the raw bytes before it; so reading, compressing and writing
   overlap. What is written does not depend on any of this (nor on how the
   bytes were read): raw bytes go out in records of RAW_RUN bytes counted
   from the end of the last file written, the rest of a run just before the
   next file. */

typedef struct {
  poa_read_fn read;
  void *ctx;
  uint8_t *buf;
  size_t cap, have;
  int eof, err;
  /* buf[rs..): not written yet; files in the pool, oldest first: a ring of
     np from first, their place in buf in at[] */
  size_t rs;
  job_t *files;
  size_t *at;
  int first, np, maxp;
  size_t pbytes;
  void *pool;
  int threads;
} in_t;

/* more bytes. When the buffer is full, what is before rs (written already)
   makes room, and every position kept moves with it (*x, the files); if it
   is still full, the buffer doubles. */
static void fill(in_t *s, size_t *x) {
  if (s->have == s->cap && s->rs) {
    size_t d = s->rs;
    move_down(s->buf, s->buf + d, s->have - d);
    s->have -= d; *x -= d; s->rs = 0;
    for (int k = 0; k < s->np; k++) s->at[(s->first + k) % s->maxp] -= d;
  }
  if (s->have == s->cap) {
    size_t c = s->cap * 2;
    uint8_t *b = H.alloc(c);
    if (!b) { s->err = POA_E_MEMORY; return; }
    copy(b, s->buf, s->have);
    H.release(s->buf);
    s->buf = b; s->cap = c;
  }
  ptrdiff_t got = s->read(s->ctx, s->buf + s->have, s->cap - s->have);
  if (got < 0) s->err = POA_E_READ;
  else if (got == 0) s->eof = 1;
  else s->have += (size_t)got;
}

/* raw bytes up to `to`: whole RAW_RUN records only, unless `all` */
static void raw_upto(in_t *s, out_t *o, size_t to, int all) {
  while (to - s->rs >= RAW_RUN) { put_raw(o, s->buf + s->rs, RAW_RUN); s->rs += RAW_RUN; }
  if (all) { put_raw(o, s->buf + s->rs, to - s->rs); s->rs = to; }
}

/* the file buf[c..c+len) to the pool, as a copy (the buffer moves) */
static void submit(in_t *s, size_t c, size_t len) {
  int k = (s->first + s->np) % s->maxp;
  job_t *f = &s->files[k];
  uint8_t *in = H.alloc(len);
  if (!in) { s->err = POA_E_MEMORY; return; }
  copy(in, s->buf + c, len);
  f->in = in; f->size = len; f->expected = 0; f->out = 0; f->out_size = 0; f->ok = 0; f->done = 0; f->cause = 0;
  /* a file alone gets the threads for its images; more files share them */
  f->threads = s->threads / (s->np + 1);
  if (f->threads < 1) f->threads = 1;
  s->at[k] = c;
  s->np++; s->pbytes += len;
  H.pool_submit(s->pool, f);
}

/* an error already: what is left is only waited for */
static int failed(const in_t *s, const out_t *o) {
  return s->err || o->err;
}

/* a file of size bytes POA took and made smaller, in a record the decoder
   takes (size <= MAX_FILE, 0 < n < size) */
static int smaller(const job_t *f, size_t size) {
  return f->ok && f->out_size && f->out_size + 12 < size && size <= MAX_FILE;
}

/* the oldest file in the pool, waited for and written with the raw bytes
   before it; one POA did not take, or that did not get smaller, stays in
   the raw run around it */
static void retire(in_t *s, out_t *o) {
  int k = s->first;
  job_t *f = &s->files[k];
  size_t size = f->size;
  H.pool_wait(s->pool, f);
  if (smaller(f, size) && !failed(s, o)) {
    raw_upto(s, o, s->at[k], 1);
    uint8_t t = TAG_FILE;
    put(o, &t, 1); put_num(o, size); put_num(o, f->out_size);
    put(o, f->out, f->out_size);
    s->rs = s->at[k] + size;
  }
  if (f->out) H.release(f->out);
  H.release((void *)f->in);
  s->first = (s->first + 1) % s->maxp;
  s->np--; s->pbytes -= f->size;
}

int poafilter_encode(poa_read_fn read, void *read_ctx, poa_write_fn write, void *write_ctx, int threads) {
  if (!read || !write || !H.alloc) return POA_E_ARG;
  if (threads < 1) threads = 1;
  in_t s = {0};
  s.read = read; s.ctx = read_ctx; s.cap = WINDOW;
  s.maxp = 8 * threads; s.threads = threads;
  out_t o = {write, write_ctx, 0};
  s.buf = H.alloc(s.cap);
  s.files = H.alloc(sizeof(job_t) * (size_t)s.maxp);
  s.at = H.alloc(sizeof(size_t) * (size_t)s.maxp);
  s.pool = H.pool_open(threads, 1);
  if (!s.buf || !s.files || !s.at || !s.pool) s.err = POA_E_MEMORY;
  put(&o, MAGIC, sizeof MAGIC);
  size_t pos = 0;                                 /* where the search goes on */
  while (!failed(&s, &o)) {
    size_t c = pos;
    int kind = -1;
    while (c + 6 <= s.have && (kind = signature(s.buf + c)) < 0) c++;
    if (!s.np) raw_upto(&s, &o, c, 0);
    if (c + 6 > s.have) {                         /* no file starts in what is here */
      if (s.eof) {
        while (s.np) retire(&s, &o);
        raw_upto(&s, &o, s.have, 1);
        break;
      }
      pos = c;
      /* files in the pool while raw bytes pile up behind them: write them,
         so that the buffer does not grow with the raw bytes */
      if (s.np && s.have - s.rs >= AHEAD_BYTES) while (s.np) retire(&s, &o);
      fill(&s, &pos);
      continue;
    }
    ptrdiff_t len;
    ext_t x = EXT_START;
    for (;;) {
      len = ogg_extent(s.buf + c, s.have - c, s.eof, &x);
      if (len != EXT_MORE || s.eof || s.err || s.have - c > MAX_FILE) break;
      fill(&s, &c);
    }
    if (s.err) break;
    if (len <= 0) { pos = c + 1; continue; }
    while (s.np && (s.np == s.maxp || s.pbytes + (size_t)len > AHEAD_BYTES)) retire(&s, &o);
    submit(&s, c, (size_t)len);
    pos = c + (size_t)len;
  }
  /* on an error, the files still in the pool are waited for and dropped */
  while (s.np) {
    job_t *f = &s.files[s.first];
    H.pool_wait(s.pool, f);
    if (f->out) H.release(f->out);
    H.release((void *)f->in);
    s.first = (s.first + 1) % s.maxp; s.np--;
  }
  if (!failed(&s, &o)) { uint8_t t = TAG_END; put(&o, &t, 1); }
  if (s.pool) H.pool_close(s.pool);
  if (s.buf) H.release(s.buf);
  if (s.files) H.release(s.files);
  if (s.at) H.release(s.at);
  return s.err ? s.err : o.err;
}

/* ---------- the decoder ---------- */

typedef struct {
  poa_read_fn read;
  void *ctx;
  uint8_t *buf;
  size_t p, n;
  int err;
} rd_t;

static size_t rd(rd_t *r, uint8_t *d, size_t want) {
  size_t got = 0;
  while (got < want && !r->err) {
    if (r->p == r->n) {
      ptrdiff_t k = r->read(r->ctx, r->buf, IOBUF);
      if (k < 0) { r->err = POA_E_READ; break; }
      if (k == 0) break;
      r->p = 0; r->n = (size_t)k;
    }
    size_t k = r->n - r->p;
    if (k > want - got) k = want - got;
    copy(d + got, r->buf + r->p, k);
    r->p += k; got += k;
  }
  return got;
}
static int rd_byte(rd_t *r) {
  if (r->p == r->n) {
    if (r->err) return -1;
    ptrdiff_t k = r->read(r->ctx, r->buf, IOBUF);
    if (k < 0) r->err = POA_E_READ;
    if (k <= 0) return -1;
    r->p = 0; r->n = (size_t)k;
  }
  return r->buf[r->p++];
}
static int rd_num(rd_t *r, uint64_t *v) {
  *v = 0;
  for (int sh = 0; sh < 64; sh += 7) {
    int b = rd_byte(r);
    if (b < 0) return 0;
    *v |= (uint64_t)(b & 0x7F) << sh;
    if (!(b & 0x80)) return 1;
  }
  return 0;
}

/* The decoder works the same way: each file's stream goes to the pool as
   it is read, raw records wait in memory behind the files before them, and
   the oldest item is written as soon as it can be: up to 8 files per
   thread (or AHEAD_BYTES) ahead. */
typedef struct {
  int file;          /* 1: job holds a file in the pool; 0: raw bytes in job.in */
  job_t job;
} item_t;
typedef struct {
  item_t *items;     /* a ring of n from first */
  int first, n, max, files, maxf;
  size_t bytes;
  void *pool;
} queue_t;

static void drop(queue_t *q, item_t *it) {
  if (it->file) {
    H.pool_wait(q->pool, &it->job);
    if (it->job.out) H.release(it->job.out);
    q->files--;
  }
  H.release((void *)it->job.in);
  q->bytes -= it->file ? it->job.expected : it->job.size;
  q->first = (q->first + 1) % q->max; q->n--;
}

/* the oldest item written; POA_E_DATA when its file did not come back
   (POA_E_VERSION when a later POA wrote its codec stream) */
static int retire_item(queue_t *q, out_t *o) {
  item_t *it = &q->items[q->first];
  int res = POA_OK;
  if (!it->file) put(o, it->job.in, it->job.size);
  else {
    H.pool_wait(q->pool, &it->job);
    if (!it->job.ok) res = it->job.cause == 1 ? POA_E_VERSION : it->job.cause == 2 ? POA_E_MEMORY : POA_E_DATA;
    else if (it->job.out_size != it->job.expected) res = POA_E_DATA;
    else put(o, it->job.out, it->job.out_size);
  }
  drop(q, it);
  return res;
}

int poafilter_decode(poa_read_fn read, void *read_ctx, poa_write_fn write, void *write_ctx, int threads) {
  if (!read || !write || !H.alloc) return POA_E_ARG;
  if (threads < 1) threads = 1;
  rd_t r = {read, read_ctx, 0, 0, 0, 0};
  out_t o = {write, write_ctx, 0};
  queue_t q = {0};
  q.maxf = 8 * threads; q.max = 2 * q.maxf + 2;
  r.buf = H.alloc(IOBUF);
  q.items = H.alloc(sizeof(item_t) * (size_t)q.max);
  q.pool = H.pool_open(threads, 0);
  int res = POA_E_DATA;
  if (!r.buf || !q.items || !q.pool) { res = POA_E_MEMORY; goto done; }
  /* the magic, then the version: one past this release's is a later POA's
     (POA_E_VERSION) */
  {
    for (size_t k = 0; k + 1 < sizeof MAGIC; k++) if (rd_byte(&r) != MAGIC[k]) goto done;
    int v = rd_byte(&r);
    if (v > MAGIC[4]) { res = POA_E_VERSION; goto done; }
    if (v != MAGIC[4]) goto done;
  }
  for (;;) {
    int t = rd_byte(&r);
    uint64_t n, size;
    if (t == TAG_END) {
      res = POA_OK;
      while (q.n && res == POA_OK && !o.err) res = retire_item(&q, &o);
      break;
    }
    /* room for one more item */
    int bad = 0;
    while (q.n && (q.n >= q.max - 1 || q.files >= q.maxf || q.bytes >= AHEAD_BYTES)) {
      int rr = retire_item(&q, &o);
      if (rr != POA_OK) { res = rr; bad = 1; break; }
    }
    if (bad || o.err) break;
    item_t *it = &q.items[(q.first + q.n) % q.max];
    if (t == TAG_RAW) {
      if (!rd_num(&r, &n) || !n || n > RAW_RUN) break;
      uint8_t *b = H.alloc((size_t)n);
      if (!b) { res = POA_E_MEMORY; break; }
      it->file = 0; it->job.in = b; it->job.size = (size_t)n; it->job.out = 0;
      q.n++; q.bytes += (size_t)n;
      if (rd(&r, b, (size_t)n) != n) break;
    } else if (t == TAG_FILE) {
      if (!rd_num(&r, &size) || !rd_num(&r, &n) || !size || size > MAX_FILE || !n || n >= size) break;
      uint8_t *st = H.alloc((size_t)n);
      if (!st) { res = POA_E_MEMORY; break; }
      it->file = 0; it->job.in = st; it->job.size = (size_t)n; it->job.expected = (size_t)size;
      it->job.out = 0; it->job.out_size = 0; it->job.ok = 0; it->job.done = 0; it->job.cause = 0;
      q.n++; q.bytes += (size_t)n;
      if (rd(&r, st, (size_t)n) != n) break;
      q.bytes += (size_t)size - (size_t)n;
      it->file = 1; q.files++;
      it->job.threads = threads / q.files; if (it->job.threads < 1) it->job.threads = 1;
      H.pool_submit(q.pool, &it->job);
    } else {
      /* 02 to FE: a record of a later POA; anything else (the end of the
         input) a data error */
      if (t >= 0x02 && t < TAG_END) res = POA_E_VERSION;
      break;
    }
  }
done:
  if (q.items) while (q.n) drop(&q, &q.items[q.first]);
  if (q.pool) H.pool_close(q.pool);
  if (q.items) H.release(q.items);
  if (r.buf) H.release(r.buf);
  if (r.err) return r.err;
  if (o.err) return o.err;
  return res;
}
