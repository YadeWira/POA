/* libpoa: POA as a library, for archivers and other programs.

   POA recompresses Ogg files losslessly (Vorbis today; Opus, FLAC, Speex
   and Theora pass as bytes): the original comes back byte for byte. The
   library is one shared object (poa.so, poa.dll, poa.dylib) with a C
   interface, shaped as PPA's libppa and PJA's libpja; every function may
   be called from several threads at once.

   Two ways to use it:

   - One file in memory: poa_compress() writes a .poa (the same format as
     the `poa` command, with the original's size and BLAKE3 hash), and
     poa_decompress() gives the original back. A file POA does not take,
     or does not make smaller, comes back as POA_E_NOT_TAKEN, and the
     caller stores it its own way.

   - A filter over a stream of any bytes, for an archiver that puts many
     files in one stream (a solid block): poa_filter_encode() finds the
     Ogg files inside, recompresses each one that comes back byte for
     byte, and passes every other byte through untouched, so the
     archiver's own compressor (LZMA2, zstd...) still sees them.
     poa_filter_decode() gives the stream back. The filter's format is in
     doc/LIBRARY.md.

   Every buffer the library returns is freed with poa_free(), never with
   free().

   POA's formats are not frozen before 0.9.0: what a published release
   wrote is read by every later one; a .poa or a filter stream a later
   release wrote may not open in an earlier one, which says so with
   POA_E_VERSION. */
#ifndef POA_H
#define POA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(_WIN64)
#define POA_CALL __cdecl
#else
#define POA_CALL
#endif

enum {
  POA_OK = 0,
  POA_E_NOT_TAKEN = 1,  /* poa_compress: not an Ogg file, or not made smaller (store it as is) */
  POA_E_DATA = 2,       /* the input is damaged or not POA's */
  POA_E_MEMORY = 3,     /* out of memory, or over a size limit */
  POA_E_READ = 4,       /* the filter's read callback failed */
  POA_E_WRITE = 5,      /* the filter's write callback failed */
  POA_E_ARG = 6,        /* a null pointer or a bad argument */
  POA_E_VERSION = 7     /* written by a newer POA: a .poa format, a filter
                           version or record this release does not know;
                           also damage that lands on one of those bytes,
                           which cannot be told apart */
};

/* Error codes may be added; a caller treats one it does not know as an
   error, as it treats POA_E_DATA. */

/* "poa 0.0.1" */
const char *POA_CALL poa_version(void);

/* An Ogg file -> a .poa, verified by decoding it back. threads: accepted
   (1 to 64) for the family's interface; a file is coded on one thread. On
   POA_OK, *out holds *out_size bytes, to free with poa_free(). */
int POA_CALL poa_compress(const void *in, size_t in_size, void **out, size_t *out_size, int threads);

/* A .poa -> the original, checked against its size and hash. max_size caps
   the original's size (0: no cap but the library's own, 2^31; above the
   cap: POA_E_MEMORY, before decoding); a decode also takes the models'
   tables, up to about 60 MB. POA_E_VERSION: a newer POA wrote it. */
int POA_CALL poa_decompress(const void *in, size_t in_size, void **out, size_t *out_size,
                            size_t max_size, int threads);

void POA_CALL poa_free(void *p);

/* The filter's callbacks. read: up to size bytes into buf; returns how
   many (0 at the end), or -1 on an error. write: all size bytes; returns 0,
   or -1 on an error. */
typedef ptrdiff_t (POA_CALL *poa_read_fn)(void *ctx, void *buf, size_t size);
typedef int (POA_CALL *poa_write_fn)(void *ctx, const void *buf, size_t size);

/* Every byte read -> the filter's stream, written. */
int POA_CALL poa_filter_encode(poa_read_fn read, void *read_ctx, poa_write_fn write, void *write_ctx,
                               int threads);
/* The filter's stream, read -> the original bytes, written. POA_E_VERSION:
   a newer POA wrote it (a filter version or a record it does not know, or a
   file's .poa of a later format); what came before it may have
   been written already. */
int POA_CALL poa_filter_decode(poa_read_fn read, void *read_ctx, poa_write_fn write, void *write_ctx,
                               int threads);

#ifdef __cplusplus
}
#endif
#endif
