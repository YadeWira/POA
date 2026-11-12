# libpoa: POA as a library and a 7-Zip plugin

`libpoa` is one shared object (`poa.so`, `poa.dll`, `poa.dylib`) that does
two jobs, as PPA's `libppa` and PJA's `libpja` do (its shape, and their
code where the format does not differ):

- a **C library** (`pas/lib/poa.h`) for any program: one file in memory to
  a `.poa` and back, and a **filter** over a stream of any bytes;
- a **codec plugin for 7-Zip and 7-Zip-zstd**, the method `POA`, which is
  that filter.

POA's formats are not frozen before 0.9.0: a `.poa`, a filter stream or a
7-Zip archive a later release wrote may not open in an earlier one, which
then says so (`POA_E_VERSION`, 7-Zip's "Unsupported Method").

It is built from `pas/lib/`: `poalib.pas` (the library, its exports and
POA's codec), `poafilter.c` (the filter), `poa7z.c` (7-Zip's interfaces).
The C calls no library (the DLL has no C runtime); CI checks it with `nm`.

```sh
pas/lib/build.sh build/lib                                   # Linux: poa.so
CC=x86_64-w64-mingw32-gcc FPC="fpc -Twin64 -Px86_64" pas/lib/build.sh build/w64   # poa.dll
```

## The C interface

`poa.h` has it all; in short:

| function | what it does |
|---|---|
| `poa_version()` | `"poa 0.0.1"` |
| `poa_compress(in, size, &out, &out_size, threads)` | an Ogg file -> a `.poa` (the same format as the `poa` command), verified by decoding it back. `POA_E_NOT_TAKEN` when it is not Ogg or would not get smaller: the caller stores it its own way |
| `poa_decompress(in, size, &out, &out_size, max_size, threads)` | a `.poa` -> the original, checked against its size and BLAKE3-128. `max_size` caps the original (0: the library's own cap, 2 GiB) |
| `poa_filter_encode(read, ctx, write, ctx, threads)` | the filter (below) over a stream given by callbacks |
| `poa_filter_decode(...)` | its stream back |
| `poa_free(p)` | frees what the library returned (never `free()`) |

Errors: `POA_E_DATA` (damaged, or not POA's), `POA_E_MEMORY` (out of memory
or over a cap), `POA_E_READ`/`POA_E_WRITE` (a callback failed),
`POA_E_ARG` (a null pointer), `POA_E_VERSION` (a newer POA wrote it). Every
function may be called from several threads at once; no exception leaves
the library.

## The filter

An archiver that puts many files into one stream (7-Zip's solid blocks)
cannot hand POA one file at a time. The filter takes the stream as it is,
finds the Ogg files inside it, recompresses each one (verified: it must
come back byte for byte), and passes **every other byte through
untouched**, so that the archiver's own compressor still sees them:

```
solid block ──► POA filter ──► [ raw bytes | Ogg as .poa | raw bytes | ... ] ──► LZMA2 ──► archive
```

### How it finds a file

By its first page: `OggS`, version 0, with the flag that begins a logical
stream (BOS). Then it walks whole pages (a 27-byte header, the lacing, the
data), each with a CRC that matches, until every logical stream it began
has ended (EOS), or until the next bytes are not such a page. A false
signature inside other data has almost never a right CRC, so the search
goes on right after it. A file that POA does not take, that does not come
back, or that does not get smaller stays among the raw bytes, and so does
anything past 256 MiB. A chained file (one link after another) is found as
one file per link.

### The stream

```
"POAF" 01                 magic and version
records, each a tag byte:
  00 n bytes              n raw bytes (n a LEB128 number, 1 to 256 KiB)
  01 size n stream        a file of `size` bytes as a .poa of n bytes
                          (0 < n < size <= 256 MiB)
  FF                      the end
```

Tags 02 to FE are left for records of later releases: a decoder that meets
one stops with `POA_E_VERSION`, as it does at a filter version past its
own or at a `.poa` of a later format. Raw bytes go out in records of
256 KiB counted from the end of the last file written, so the stream is
the same however the input was read, and whatever the threads.

### Threads

Files go to a pool of threads as the filter finds them, up to eight per
thread (or 64 MiB) ahead of the oldest, which is written as soon as it is
done: reading, compressing and writing overlap, and extracting works the
same way. A file is coded on one thread. None of this changes the stream.

## The 7-Zip plugin

Put the library in the `Codecs` folder next to 7-Zip: `7z.exe` on Windows
(7-Zip or 7-Zip-zstd), `7z` and `7z.so` on Linux. The library's build must
be 7-Zip's: the x64 `poa.dll` for 64-bit 7-Zip, the x86 one for 32-bit
7-Zip. `7z i` lists the method:

```
 1  ED     37F50 POA
```

```sh
7z a -m0=POA -m1=LZMA2 music.7z music/        # 7-Zip
7z a -m0=POA -m1=zstd  music.7z music/        # 7-Zip-zstd
7z x music.7z
```

A stream a newer POA wrote comes out of the plugin as "Unsupported Method"
for the block's files, and damaged data as "Data Error". **The archive
needs the plugin to be extracted**, in every 7-Zip that opens it. It works
with 7-Zip on Windows and with 7-Zip 23 or later on Linux and macOS; p7zip
(the old port, `7z` 16.02) builds its interfaces differently and does not
load it.

Measured on 11/11/2026 with 7-Zip 25.01 on Linux, on the 45 audio files of
our test corpus (Vorbis, Opus, Speex; 25,587,561 bytes), every file
extracted and compared:

| | archive | of the input | write / extract |
|---|---|---|---|
| 7-Zip + POA (`-m0=POA -m1=LZMA2 -mmt=8`) | 22,600,015 | **88.32%** | 23.9 s / 12.7 s |
| 7-Zip alone (`-m0=LZMA2 -mx=9`) | 24,366,066 | 95.23% | 2.4 s |

POA models Vorbis only for now: the Opus and Speex files of the set go
through it nearly as they are.

The method ID, `03 7F 50`, is in the slot 7-Zip's `DOC/Methods.txt` keeps
for an experimental method; the family shares that slot by decades (PJA
`03 7F 0x`, PPA `1x`, PMPA `2x`, PRA `3x`, PAIA `4x`, POA `5x`), so that
every plugin can sit in the same `Codecs` folder. POA will move to an ID of
its own with 1.0.0 and stay able to read this one.

On Windows the library takes its memory from the process heap
(`pas/poaheap.pas`, PPA's `ppaheap.pas`, from PJA's `pjaheap.pas`), not
FreePascal's own: FreePascal 3.2.2's heap, in a DLL, deletes its lock when
the thread that loaded the DLL ends, and 7-Zip's file manager loads its
codecs from such a short-lived thread. With the memory gone it returns
nil, never a runtime error. Each block has 16 bytes to spare after it, for
FreePascal's reads a few bytes past the end of an array (PPA found a
32-bit 7-Zip on Windows XP failing with "Data Error" without them).

How it is made: 7-Zip's interfaces are C++ classes with only virtual
methods, which is a table of function pointers at the start of the object,
so `poa7z.c` builds them in plain C (`__stdcall` on 32-bit Windows). The
library exports `GetNumberOfMethods`, `GetMethodProperty`,
`CreateDecoder`, `CreateEncoder`, `CreateObject` and `GetModuleProp`.
CI builds the library on all six platforms, runs `test_lib`, and on Linux
and Windows x64 writes an archive of every sample through a real 7-Zip and
extracts it.
