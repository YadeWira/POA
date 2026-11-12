/* libpoa's test, in C against poa.h, the way an archiver uses it (from
   PPA's pas/lib/test_lib.c, itself from PJA's):

     test_lib FILE...

   Each file through poa_compress and poa_decompress (a file POA does not
   take, or does not make smaller, must say so, and nothing else may fail),
   the same bytes on 1 and 2 threads; a damaged .poa refused. What a newer
   POA would write (a .poa format, a filter version or record)
   must give POA_E_VERSION. Several threads compressing at once must give
   the same bytes, and many short-lived threads must not run out of memory
   (nothing kept per thread). Then every file put
   together into one stream with bytes around them (and false signatures),
   through the filter in read sizes of 1 byte to 1 MiB, and back: the same
   bytes, every time. A damaged filter stream must give an error or other
   bytes, never a crash. Prints a line per check that fails and "N checks,
   M failures" at the end. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "poa.h"
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

static int checks, failures;
static void check(int ok, const char *what, const char *name) {
  checks++;
  if (!ok) { failures++; printf("  FAIL  %s %s\n", what, name); }
}

typedef struct { const unsigned char *d; size_t n, p, step; } src_t;
typedef struct { unsigned char *d; size_t n, cap; } dst_t;

static ptrdiff_t rd(void *ctx, void *buf, size_t size) {
  src_t *s = ctx;
  size_t k = s->n - s->p;
  if (k > size) k = size;
  if (k > s->step) k = s->step;
  memcpy(buf, s->d + s->p, k);
  s->p += k;
  return (ptrdiff_t)k;
}
static int wr(void *ctx, const void *buf, size_t size) {
  dst_t *d = ctx;
  if (d->n + size > d->cap) {
    d->cap = (d->n + size) * 2 + 4096;
    d->d = realloc(d->d, d->cap);
    if (!d->d) return -1;
  }
  memcpy(d->d + d->n, buf, size);
  d->n += size;
  return 0;
}

static unsigned char *slurp(const char *name, size_t *n) {
  FILE *f = fopen(name, "rb");
  if (!f) return 0;
  fseek(f, 0, SEEK_END);
  long k = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *d = malloc(k > 0 ? (size_t)k : 1);
  *n = fread(d, 1, (size_t)k, f);
  fclose(f);
  return d;
}

/* a filter stream through the decoder: its result */
static int filter_result(const unsigned char *a, size_t an) {
  src_t ia = {a, an, 0, 4096};
  dst_t o = {0};
  int r = poa_filter_decode(rd, &ia, wr, &o, 1);
  free(o.d);
  return r;
}

/* what a newer POA wrote: POA_E_VERSION, never POA_E_DATA nor a crash. poa
   is a .poa (poa_compress's): its format byte is byte 4 */
static void versions(const unsigned char *poa, size_t pn) {
  unsigned char *p = malloc(pn);
  void *back = 0;
  size_t bn = 0;
  int bad = 0;
  memcpy(p, poa, pn);
  for (int v = 2; v < 256; v++) {
    p[4] = (unsigned char)v;
    bad += poa_decompress(p, pn, &back, &bn, 0, 1) != POA_E_VERSION;
    poa_free(back); back = 0;
  }
  check(bad == 0, "a .poa of format 2 to 255: POA_E_VERSION", "");
  p[4] = 0;
  check(poa_decompress(p, pn, &back, &bn, 0, 1) == POA_E_DATA, "a .poa of format 0: POA_E_DATA", "");
  poa_free(back);
  free(p);
  static const unsigned char f2[] = {'P', 'O', 'A', 'F', 2, 0xFF}, f1end[] = {'P', 'O', 'A', 'F', 1, 0xFF},
    f1cut[] = {'P', 'O', 'A', 'F', 1};
  check(filter_result(f2, sizeof f2) == POA_E_VERSION, "filter version 2: POA_E_VERSION", "");
  check(filter_result(f1end, sizeof f1end) == POA_OK, "filter version 1, empty", "");
  check(filter_result(f1cut, sizeof f1cut) == POA_E_DATA, "filter version 1 cut short: POA_E_DATA", "");
  bad = 0;
  for (int t = 0x02; t < 0xFF; t++) {
    /* a raw record first, then the unknown one */
    unsigned char s1[] = {'P', 'O', 'A', 'F', 1, 0x00, 0x01, 'x', (unsigned char)t, 0x01, 0x01, 0xFF};
    bad += filter_result(s1, sizeof s1) != POA_E_VERSION;
  }
  check(bad == 0, "filter records 02 to FE: POA_E_VERSION", "");
  bad = 0;
  for (int v = 2; v < 256; v++) {
    /* a file of 100 bytes whose .poa (30 bytes, a header alone) is of format v */
    unsigned char s1[5 + 3 + 30 + 1] = {'P', 'O', 'A', 'F', 1, 0x01, 100, 30, 'P', 'O', 'A', 0x1A, (unsigned char)v, 0, 100};
    s1[sizeof s1 - 1] = 0xFF;
    bad += filter_result(s1, sizeof s1) != POA_E_VERSION;
  }
  check(bad == 0, "a filter record whose .poa is of format 2 to 255: POA_E_VERSION", "");
  printf("what a newer POA wrote: POA_E_VERSION (.poa format, filter version and records)\n");
}

/* ---------- threads ---------- */

typedef struct { const unsigned char *d; size_t n; void *out; size_t on; int r; } work_t;

#ifdef _WIN32
static DWORD WINAPI worker(LPVOID arg) {
  work_t *w = arg;
  w->r = poa_compress(w->d, w->n, &w->out, &w->on, 1);
  return 0;
}
static void run_threads(work_t *w, int n) {
  HANDLE h[16];
  for (int k = 0; k < n; k++) h[k] = CreateThread(NULL, 0, worker, &w[k], 0, NULL);
  for (int k = 0; k < n; k++) { WaitForSingleObject(h[k], INFINITE); CloseHandle(h[k]); }
}
#else
static void *worker(void *arg) {
  work_t *w = arg;
  w->r = poa_compress(w->d, w->n, &w->out, &w->on, 1);
  return 0;
}
static void run_threads(work_t *w, int n) {
  pthread_t t[16];
  for (int k = 0; k < n; k++) pthread_create(&t[k], NULL, worker, &w[k]);
  for (int k = 0; k < n; k++) pthread_join(t[k], NULL);
}
#endif

/* the same file from 4 threads at once, 3 rounds, then 40 threads one after
   another (each its own models, given back when it returns): the same
   bytes as on the main thread, every time */
static void threads_test(const unsigned char *d, size_t n, const void *want, size_t wn, const char *name) {
  work_t w[16];
  int bad = 0;
  for (int round = 0; round < 3; round++) {
    for (int k = 0; k < 4; k++) { w[k].d = d; w[k].n = n; w[k].out = 0; w[k].on = 0; w[k].r = -1; }
    run_threads(w, 4);
    for (int k = 0; k < 4; k++) {
      bad += w[k].r != POA_OK || w[k].on != wn || memcmp(w[k].out, want, wn) != 0;
      poa_free(w[k].out);
    }
  }
  check(bad == 0, "4 threads at once: the same bytes", name);
  bad = 0;
  for (int k = 0; k < 40; k++) {
    w[0].d = d; w[0].n = n; w[0].out = 0; w[0].on = 0; w[0].r = -1;
    run_threads(w, 1);
    bad += w[0].r != POA_OK || w[0].on != wn || memcmp(w[0].out, want, wn) != 0;
    poa_free(w[0].out);
  }
  check(bad == 0, "40 short-lived threads: the same bytes", name);
  printf("threads (%s): 4 at once, 3 rounds, and 40 one after another: %s\n", name, bad ? "FAILED" : "the same bytes");
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);   /* every line out at once, even if a check hangs */
  printf("%s\n", poa_version());
  unsigned char *all = 0;
  size_t alln = 0, taken = 0, insum = 0, outsum = 0;
  unsigned seed = 1;
  int versioned = 0, threaded = 0;
  for (int a = 1; a < argc; a++) {
    size_t n;
    unsigned char *d = slurp(argv[a], &n);
    if (!d) { check(0, "read", argv[a]); continue; }
    void *p = 0, *back = 0;
    size_t pn = 0, bn = 0;
    int r = poa_compress(d, n, &p, &pn, 2);
    check(r == POA_OK || r == POA_E_NOT_TAKEN, "compress", argv[a]);
    if (r == POA_OK && !versioned && pn > 40 && n > 8 && d[0] == 'O' && !(((unsigned char *)p)[5] & 1)) {
      versions(p, pn);
      versioned = 1;
    }
    if (r == POA_OK) {
      void *p2 = 0;                                /* again, on one thread */
      size_t pn2 = 0;
      check(poa_compress(d, n, &p2, &pn2, 1) == POA_OK && pn2 == pn && memcmp(p2, p, pn) == 0,
            "the same bytes on 1 thread", argv[a]);
      poa_free(p2);
      if (!threaded) { threads_test(d, n, p, pn, argv[a]); threaded = 1; }
      taken++; insum += n; outsum += pn;
      r = poa_decompress(p, pn, &back, &bn, 0, 2);
      check(r == POA_OK && bn == n && memcmp(back, d, n) == 0, "decompress", argv[a]);
      poa_free(back); back = 0;
      r = poa_decompress(p, pn, &back, &bn, n - 1, 1);
      check(r == POA_E_MEMORY, "decompress, max_size below the original: POA_E_MEMORY", argv[a]);
      poa_free(back);
      if (pn > 40) {                               /* one flipped byte: caught */
        ((unsigned char *)p)[pn / 2] ^= 0x55;
        back = 0;
        r = poa_decompress(p, pn, &back, &bn, 0, 1);
        check(r != POA_OK, "damaged .poa refused", argv[a]);
        poa_free(back);
      }
    }
    poa_free(p);
    /* the stream: some bytes, a false signature, the file */
    size_t junk = (seed = seed * 1103515245u + 12345u) % 3000;
    all = realloc(all, alln + junk + n + 12);
    for (size_t k = 0; k < junk; k++) all[alln++] = (unsigned char)((seed >> (k % 24)) ^ k);
    static const unsigned char fake[12] = {'O', 'g', 'g', 'S', 0, 2, 0, 0, 0, 0, 0, 13};
    memcpy(all + alln, fake, sizeof fake); alln += sizeof fake;
    memcpy(all + alln, d, n); alln += n;
    free(d);
  }
  printf("%zu of %d files taken: %zu -> %zu bytes as .poa\n", taken, argc - 1, insum, outsum);
  check(versioned, "an Ogg file for the version checks", "");
  check(threaded, "an Ogg file for the thread checks", "");
  {                                                /* null pointers: an error, not a crash */
    static const unsigned char some[8] = {'O', 'g', 'g', 'S', 0, 2, 0, 0};
    void *p = 0;
    size_t pn = 0;
    check(poa_compress(some, 8, NULL, &pn, 1) == POA_E_ARG, "compress, null out", "");
    check(poa_compress(some, 8, &p, NULL, 1) == POA_E_ARG, "compress, null out_size", "");
    check(poa_decompress(some, 8, NULL, &pn, 0, 1) == POA_E_ARG, "decompress, null out", "");
    check(poa_decompress(some, 8, &p, NULL, 0, 1) == POA_E_ARG, "decompress, null out_size", "");
    check(poa_compress(NULL, 0, &p, &pn, 1) == POA_E_NOT_TAKEN, "compress, nothing: not taken", "");
    check(poa_compress(some, 8, &p, &pn, 1) == POA_E_NOT_TAKEN, "compress, a signature alone: not taken", "");
    check(poa_filter_encode(NULL, NULL, NULL, NULL, 1) == POA_E_ARG, "filter, null functions", "");
    check(poa_filter_decode(NULL, NULL, NULL, NULL, 1) == POA_E_ARG, "filter decode, null functions", "");
  }
  static const size_t steps[] = {1 << 20, 4096, 1000, 7, 1};
  dst_t enc = {0};
  for (unsigned s = 0; s < sizeof steps / sizeof steps[0]; s++) {
    if (steps[s] < 1000 && alln > (8u << 20)) continue;   /* byte by byte only on small sets */
    src_t in = {all, alln, 0, steps[s]};
    dst_t e = {0}, b = {0};
    int r = poa_filter_encode(rd, &in, wr, &e, 4);
    check(r == POA_OK, "filter encode", "");
    src_t in2 = {e.d, e.n, 0, steps[s]};
    r = poa_filter_decode(rd, &in2, wr, &b, 4);
    check(r == POA_OK && b.n == alln && memcmp(b.d, all, alln) == 0, "filter round trip", "");
    if (s > 0) check(e.n == enc.n && memcmp(e.d, enc.d, e.n) == 0, "filter: the same stream whatever the reads", "");
    printf("filter, reads of %zu: %zu -> %zu bytes, %s\n", steps[s], alln, e.n,
           r == POA_OK && b.n == alln ? "back" : "NOT back");
    if (s == 0) enc = e; else free(e.d);
    free(b.d);
  }
  check(enc.n < alln, "filter: smaller", "");
  /* the same stream on one thread: the same bytes */
  {
    src_t in = {all, alln, 0, 1 << 20};
    dst_t e = {0};
    check(poa_filter_encode(rd, &in, wr, &e, 1) == POA_OK && e.n == enc.n && memcmp(e.d, enc.d, e.n) == 0,
          "filter: the same stream on 1 thread", "");
    free(e.d);
  }
  /* damaged filter streams: about 300 bytes spread over the stream
     flipped, one at a time, and cut short at a few places */
  int bad = 0, same = 0;
  for (size_t k = 0; k < enc.n; k += enc.n / 300 + 1) {
    enc.d[k] ^= 0x41;
    src_t in = {enc.d, enc.n, 0, 1 << 20};
    dst_t b = {0};
    int r = poa_filter_decode(rd, &in, wr, &b, 1);
    if (r != POA_OK) bad++;
    else same += b.n == alln && memcmp(b.d, all, alln) == 0;
    free(b.d);
    enc.d[k] ^= 0x41;
  }
  for (size_t cut = 0; cut < enc.n; cut += enc.n / 7 + 1) {
    src_t in = {enc.d, cut, 0, 1 << 20};
    dst_t b = {0};
    check(poa_filter_decode(rd, &in, wr, &b, 1) != POA_OK, "cut filter stream refused", "");
    free(b.d);
  }
  printf("damaged filter streams: %d refused, %d decoded the same, the rest other bytes, no crash\n",
         bad, same);
  free(enc.d);
  free(all);
  printf("%d checks, %d failures\n", checks, failures);
  return failures != 0;
}
