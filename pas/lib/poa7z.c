/* libpoa as a 7-Zip codec plugin: put poa.dll (poa.so) in the Codecs folder
   next to 7-Zip (7z.exe, or 7z and 7z.so on Linux), or 7-Zip-zstd, and the
   method POA is there:

     7z a -m0=POA -m1=LZMA2 music.7z music/          (7-Zip-zstd: -m1=zstd)

   POA is a filter in 7-Zip's sense of a first coder: it takes the solid
   block, recompresses the Ogg files in it (poafilter.c) and passes every
   other byte on to the next coder, its own data among them. Extracting
   needs the plugin too. From PPA's ppa7z.c (itself from PJA's pja7z.c),
   the same COM layer.

   7-Zip's interfaces are C++ classes with only virtual methods, which is a
   table of function pointers first in the object: plain C builds them. On
   Windows x86 they are __stdcall; elsewhere the default convention. IUnknown
   has no virtual destructor (GetModuleProp says so: 7-Zip on Linux since
   v23 checks it). The exported functions are poalib.pas's, which call the
   poa7z_* ones here.

   The method's ID, 03 7F 50, is in the slot 7-Zip's DOC/Methods.txt leaves
   for an experimental method (the family's decades: PJA 03 7F 0x, PPA 1x,
   PMPA 2x, PRA 3x, PAIA 4x, POA 5x, so that every plugin can sit in the
   same Codecs folder), until 7-Zip gives POA an ID of its own. POA's
   formats are not frozen before 0.9.0: an archive
   a later plugin wrote may not open with an earlier one (the other way
   round it always does). */
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && !defined(_WIN64)
#define COMCALL __stdcall
#define POA_CALL __cdecl
#else
#define COMCALL
#define POA_CALL
#endif

typedef int32_t HRESULT;
#define S_OK ((HRESULT)0)
#define S_FALSE ((HRESULT)1)
#define E_NOTIMPL ((HRESULT)0x80004001u)
#define E_NOINTERFACE ((HRESULT)0x80004002u)
#define E_ABORT ((HRESULT)0x80004004u)
#define E_FAIL ((HRESULT)0x80004005u)
#define E_OUTOFMEMORY ((HRESULT)0x8007000Eu)
#define E_INVALIDARG ((HRESULT)0x80070057u)
#define CLASS_E_CLASSNOTAVAILABLE ((HRESULT)0x80040111u)

typedef struct { uint32_t d1; uint16_t d2, d3; uint8_t d4[8]; } guid_t;

enum { VT_EMPTY = 0, VT_BOOL = 11, VT_UI4 = 19, VT_UI8 = 21, VT_BSTR = 8 };
typedef struct {
  uint16_t vt, r1, r2, r3;
  union { uint64_t u64; uint32_t u32; int16_t b; void *p; } v;
} propvariant_t;

/* what poalib.pas gives: a BSTR the way this platform's 7-Zip frees it
   (Windows: OLE's SysAllocStringByteLen; elsewhere 7-Zip's own layout, a
   32-bit byte count before the string, from malloc), and the filter */
typedef struct {
  void *(*bstr)(const void *bytes, uint32_t len);
  void *(*alloc)(size_t size);
  void (*release)(void *p);
  int threads;    /* when 7-Zip says nothing: the processors, up to 8 */
} host7z_t;
static host7z_t H7;
void poa7z_host(const host7z_t *h) { H7 = *h; }

typedef ptrdiff_t (POA_CALL *poa_read_fn)(void *ctx, void *buf, size_t size);
typedef int (POA_CALL *poa_write_fn)(void *ctx, const void *buf, size_t size);
int poafilter_encode(poa_read_fn read, void *read_ctx, poa_write_fn write, void *write_ctx, int threads);
int poafilter_decode(poa_read_fn read, void *read_ctx, poa_write_fn write, void *write_ctx, int threads);

/* The method: the filter (poafilter.c), one stream, which goes on to the
   next coder of the chain */
typedef struct { const char *name; uint64_t id; uint32_t streams; } method_t;
static const method_t METHODS[] = {
  {"POA", 0x037F50, 1},
};
enum { NUM_METHODS = sizeof METHODS / sizeof METHODS[0] };

/* {23170F69-40C1-278A-0000-00gg00ss0000}: 7-Zip's interfaces, group g and
   sub-id s; the coder classes: Data3 2790 (decoder) or 2791 (encoder) and
   the method's ID in Data4, little-endian */
static int is_7zip_iid(const guid_t *g, uint8_t group, uint8_t sub) {
  return g->d1 == 0x23170F69u && g->d2 == 0x40C1 && g->d3 == 0x278A && g->d4[0] == 0 && g->d4[1] == 0
         && g->d4[2] == 0 && g->d4[3] == group && g->d4[4] == 0 && g->d4[5] == sub && g->d4[6] == 0
         && g->d4[7] == 0;
}
static int is_iunknown(const guid_t *g) {
  static const uint8_t d4[8] = {0xC0, 0, 0, 0, 0, 0, 0, 0x46};
  if (g->d1 || g->d2 || g->d3) return 0;
  for (int k = 0; k < 8; k++) if (g->d4[k] != d4[k]) return 0;
  return 1;
}
enum { G_STREAM = 3, G_CODER = 4, S_CODER = 0x05, S_CODER2 = 0x18, S_PROGRESS = 0x04, S_CODER_MT = 0x25 };

/* ---------- the streams 7-Zip hands in ---------- */

typedef struct instream instream_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(instream_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(instream_t *);
  uint32_t (COMCALL *Release)(instream_t *);
  HRESULT (COMCALL *Read)(instream_t *, void *data, uint32_t size, uint32_t *processed);
} instream_vt;
struct instream { const instream_vt *vt; };

typedef struct outstream outstream_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(outstream_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(outstream_t *);
  uint32_t (COMCALL *Release)(outstream_t *);
  HRESULT (COMCALL *Write)(outstream_t *, const void *data, uint32_t size, uint32_t *processed);
} outstream_vt;
struct outstream { const outstream_vt *vt; };

typedef struct progress progress_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(progress_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(progress_t *);
  uint32_t (COMCALL *Release)(progress_t *);
  HRESULT (COMCALL *SetRatioInfo)(progress_t *, const uint64_t *in_size, const uint64_t *out_size);
} progress_vt;
struct progress { const progress_vt *vt; };

/* one run of the coder: progress and the first error, shared by its
   streams */
typedef struct {
  progress_t *progress;
  uint64_t in_pos, out_pos, next_report;
  HRESULT err;    /* the first error a stream or the progress gave */
} run_t;
typedef struct {
  instream_t *in;
  outstream_t *out;
  run_t *run;
} io_t;

enum { REPORT_EVERY = 1 << 20 };

static void report(run_t *r) {
  if (!r->progress || r->in_pos + r->out_pos < r->next_report) return;
  r->next_report = r->in_pos + r->out_pos + REPORT_EVERY;
  HRESULT h = r->progress->vt->SetRatioInfo(r->progress, &r->in_pos, &r->out_pos);
  if (h != S_OK && !r->err) r->err = h;
}

static ptrdiff_t POA_CALL io_read(void *ctx, void *buf, size_t size) {
  io_t *io = ctx;
  run_t *r = io->run;
  if (r->err) return -1;
  if (size > 0x40000000u) size = 0x40000000u;
  uint32_t got = 0;
  HRESULT h = io->in->vt->Read(io->in, buf, (uint32_t)size, &got);
  if (h != S_OK) { r->err = h; return -1; }
  r->in_pos += got;
  report(r);
  return r->err ? -1 : (ptrdiff_t)got;
}

static int POA_CALL io_write(void *ctx, const void *buf, size_t size) {
  io_t *io = ctx;
  run_t *r = io->run;
  const uint8_t *p = buf;
  while (size && !r->err) {
    uint32_t n = size > 0x40000000u ? 0x40000000u : (uint32_t)size, done = 0;
    HRESULT h = io->out->vt->Write(io->out, p, n, &done);
    if (h != S_OK) { r->err = h; break; }
    if (!done) { r->err = E_FAIL; break; }
    p += done; size -= done; r->out_pos += done;
  }
  report(r);
  return r->err ? -1 : 0;
}

static HRESULT result(const run_t *r, int res) {
  if (r->err) return r->err;
  switch (res) {
    case 0: return S_OK;
    case 3: return E_OUTOFMEMORY;
    case 2: return S_FALSE;    /* 7-Zip's "data error" */
    /* POA_E_VERSION, a later POA's stream: 7-Zip says "Unsupported
       Method" for the files of the block, as for a method it lacks */
    case 7: return E_NOTIMPL;
    default: return E_FAIL;
  }
}

/* ---------- the coder ---------- */

/* ICompressCoder */
typedef struct coder coder_t;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(coder_t *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(coder_t *);
  uint32_t (COMCALL *Release)(coder_t *);
  HRESULT (COMCALL *Code)(coder_t *, instream_t *, outstream_t *, const uint64_t *in_size,
                          const uint64_t *out_size, progress_t *);
} coder_vt;
typedef struct {
  HRESULT (COMCALL *QueryInterface)(void *, const guid_t *, void **);
  uint32_t (COMCALL *AddRef)(void *);
  uint32_t (COMCALL *Release)(void *);
  HRESULT (COMCALL *SetNumberOfThreads)(void *, uint32_t threads);
} coder_mt_vt;
struct coder {
  const coder_vt *vt;
  const coder_mt_vt *mt_vt;    /* ICompressSetCoderMt: a second table, at &c->mt_vt */
  int32_t refs;
  int encode, streams;
  int threads;
};

static coder_t *from_mt(void *p) { return (coder_t *)((char *)p - offsetof(coder_t, mt_vt)); }

static HRESULT COMCALL c_query(coder_t *c, const guid_t *iid, void **out);
/* a plain count, as 7-Zip's own coders keep it (CMyUnknownImp): a coder is
   used by one thread at a time */
static uint32_t COMCALL c_addref(coder_t *c) { return (uint32_t)++c->refs; }
static uint32_t COMCALL c_release(coder_t *c) {
  int32_t n = --c->refs;
  if (!n) H7.release(c);
  return (uint32_t)n;
}

static HRESULT COMCALL c_code(coder_t *c, instream_t *in, outstream_t *out, const uint64_t *in_size,
                              const uint64_t *out_size, progress_t *progress) {
  (void)in_size; (void)out_size;
  if (!in || !out) return E_INVALIDARG;
  run_t r = {progress, 0, 0, REPORT_EVERY, S_OK};
  io_t io = {in, out, &r};
  int res = c->encode ? poafilter_encode(io_read, &io, io_write, &io, c->threads)
                      : poafilter_decode(io_read, &io, io_write, &io, c->threads);
  return result(&r, res);
}

static HRESULT COMCALL m_query(void *p, const guid_t *iid, void **out) { return c_query(from_mt(p), iid, out); }
static uint32_t COMCALL m_addref(void *p) { return c_addref(from_mt(p)); }
static uint32_t COMCALL m_release(void *p) { return c_release(from_mt(p)); }
static HRESULT COMCALL m_threads(void *p, uint32_t threads) {
  coder_t *c = from_mt(p);
  c->threads = threads < 1 ? 1 : threads > 64 ? 64 : (int)threads;
  return S_OK;
}

static const coder_vt CODER_VT = {c_query, c_addref, c_release, c_code};
static const coder_mt_vt CODER_MT_VT = {m_query, m_addref, m_release, m_threads};

static HRESULT COMCALL c_query(coder_t *c, const guid_t *iid, void **out) {
  if (!out) return E_INVALIDARG;
  *out = 0;
  if (is_iunknown(iid) || is_7zip_iid(iid, G_CODER, S_CODER)) *out = c;
  else if (is_7zip_iid(iid, G_CODER, S_CODER_MT)) *out = &c->mt_vt;
  else return E_NOINTERFACE;
  c_addref(c);
  return S_OK;
}

static HRESULT new_coder(uint32_t index, int encode, const guid_t *iid, void **out) {
  if (!out) return E_INVALIDARG;
  *out = 0;
  if (index >= NUM_METHODS) return CLASS_E_CLASSNOTAVAILABLE;
  coder_t *c = H7.alloc(sizeof *c);
  if (!c) return E_OUTOFMEMORY;
  c->streams = (int)METHODS[index].streams;
  c->vt = &CODER_VT;
  c->mt_vt = &CODER_MT_VT; c->refs = 1; c->encode = encode;
  /* extracting, 7-Zip tells only the first coder of the chain that takes
     it (LZMA2 or zstd) how many threads to use; POA uses the processors */
  c->threads = H7.threads > 0 ? H7.threads : 1;
  HRESULT r = c_query(c, iid, out);
  c_release(c);
  return r;
}

/* ---------- what the plugin exports (through poalib.pas) ---------- */

HRESULT poa7z_GetNumberOfMethods(uint32_t *n) {
  if (!n) return E_INVALIDARG;
  *n = NUM_METHODS;
  return S_OK;
}

static void set_bstr(propvariant_t *v, const void *bytes, uint32_t len) {
  void *b = H7.bstr(bytes, len);
  if (b) { v->vt = VT_BSTR; v->v.p = b; }
}
static void class_id(uint32_t index, uint16_t data3, guid_t *g) {
  g->d1 = 0x23170F69u; g->d2 = 0x40C1; g->d3 = data3;
  for (int k = 0; k < 8; k++) g->d4[k] = (uint8_t)(METHODS[index].id >> (8 * k));
}

enum { P_ID, P_NAME, P_DECODER, P_ENCODER, P_PACK_STREAMS, P_UNPACK_STREAMS, P_DESCRIPTION,
       P_DECODER_ASSIGNED, P_ENCODER_ASSIGNED, P_DIGEST_SIZE, P_IS_FILTER };

HRESULT poa7z_GetMethodProperty(uint32_t index, uint32_t prop, propvariant_t *v) {
  if (!v) return E_INVALIDARG;
  if (index >= NUM_METHODS) return E_INVALIDARG;
  v->vt = VT_EMPTY;
  guid_t g;
  const method_t *m = &METHODS[index];
  switch (prop) {
    case P_ID: v->vt = VT_UI8; v->v.u64 = m->id; break;
    case P_NAME: {
      /* a BSTR holds wchar_t: 2 bytes on Windows, 4 on Linux and macOS */
      __WCHAR_TYPE__ w[8];
      unsigned n = 0;
      while (m->name[n] && n < 7) { w[n] = (__WCHAR_TYPE__)(uint8_t)m->name[n]; n++; }
      w[n] = 0;
      set_bstr(v, w, (uint32_t)(sizeof w[0] * n));
      break;
    }
    case P_DECODER: class_id(index, 0x2790, &g); set_bstr(v, &g, sizeof g); break;
    case P_ENCODER: class_id(index, 0x2791, &g); set_bstr(v, &g, sizeof g); break;
    case P_PACK_STREAMS:
      if (m->streams != 1) { v->vt = VT_UI4; v->v.u32 = m->streams; }
      break;
    case P_DECODER_ASSIGNED: case P_ENCODER_ASSIGNED: v->vt = VT_BOOL; v->v.b = -1; break;
    case P_IS_FILTER: v->vt = VT_BOOL; v->v.b = 0; break;
    default: break;
  }
  return S_OK;
}

HRESULT poa7z_CreateDecoder(uint32_t index, const guid_t *iid, void **out) {
  return new_coder(index, 0, iid, out);
}
HRESULT poa7z_CreateEncoder(uint32_t index, const guid_t *iid, void **out) {
  return new_coder(index, 1, iid, out);
}
/* CreateObject / CreateCoder: by class ID */
HRESULT poa7z_CreateObject(const guid_t *clsid, const guid_t *iid, void **out) {
  if (out) *out = 0;
  if (!clsid) return E_INVALIDARG;
  for (uint32_t i = 0; i < NUM_METHODS; i++) {
    guid_t d, e;
    class_id(i, 0x2790, &d); class_id(i, 0x2791, &e);
    int isd = 1, ise = 1;
    const uint8_t *a = (const uint8_t *)clsid, *bd = (const uint8_t *)&d, *be = (const uint8_t *)&e;
    for (unsigned k = 0; k < sizeof d; k++) { if (a[k] != bd[k]) isd = 0; if (a[k] != be[k]) ise = 0; }
    if (isd || ise) return new_coder(i, ise, iid, out);
  }
  return CLASS_E_CLASSNOTAVAILABLE;
}

enum { M_INTERFACE_TYPE = 0, M_VERSION = 1 };
HRESULT poa7z_GetModuleProp(uint32_t prop, propvariant_t *v) {
  if (!v) return E_INVALIDARG;
  v->vt = VT_EMPTY;
  if (prop == M_INTERFACE_TYPE) { v->vt = VT_UI4; v->v.u32 = 0; }   /* no virtual destructor */
  else if (prop == M_VERSION) { v->vt = VT_UI4; v->v.u32 = (0u << 16) | 11u; }   /* 0.11 = POA 0.1.1, checked against poasysinfo's VERSION by run_tests.sh */
  return S_OK;
}
