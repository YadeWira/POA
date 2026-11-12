# PJA 0.9.8: the zpaq-std plugin, vendored

PJA (https://github.com/YadeWira/PJA), tag `v0.9.8`, commit `e89a500`:
only the sources the zpaq-std plugin is built from. MIT (`LICENSE`);
`NOTICE` has the third-party notes.

## What is new in 0.9.8

The 31 codecs are 0.9.6's, byte for byte (streams, ZPAQL, what each
takes). One fix for the Windows build: `pas/pjaheap.pas`, the heap the
Windows DLL uses, keeps 16 bytes after each block (`TAIL_BYTES`).
FreePascal's i386 code can load 4 bytes where it reads a 2-byte array
element, 2 bytes past the end; FreePascal's own heap always leaves room
there, the process heap may not, and on Windows XP a 32-bit DLL built the
same way failed now and then (found by PPA). Rebuilding the Windows DLLs,
the 32-bit one above all, is recommended; nothing else changes.

Checked: built from this directory alone, the plugin lists the thirty-one
codecs, pja2k at 30, and PJA's plugin probe passes on `tests/j2k` and
`tests/jpg`.

## What is new in 0.9.7

Nothing for the plugin: its 31 codecs (0 to 29, and `pja2k` at 30) are
0.9.6's, byte for byte (streams, ZPAQL, what each takes). The only change
in these sources is `PJA_VERSION` in `pas/pjacodec.pas`. 0.9.7's change is
in the `pja` command (each output's flush beside the next file's work),
which the plugin does not use. Rebuilding is optional.

Checked: built from this directory alone, the plugin lists the thirty-one
codecs, pja2k at 30, and PJA's plugin probe passes on `tests/j2k` and
`tests/jpg`.

## What is new in 0.9.6: pja2k, JPEG 2000

One codec, index 30 of `zpaqstd_codecs_v1`: **`pja2k`**, for files of the
JPEG 2000 family (JP2, JPX, JPM, Motion JPEG 2000, raw codestreams), with
a ZPAQL decoder, so any zpaq extracts its blocks without the plugin.

- **Stream**: version 8 as the command writes it, with codestream modes 0
  (raw) and 1 (the code-blocks' decisions through a model) only. HTJ2K
  codestreams (the command's modes 3 and 4) and the command's mode 2 (the
  pixels) have no ZPAQL: the plugin keeps those codestreams as bytes, and
  detect does not take a file whose codestreams are all HTJ2K. A file
  whose codestreams all stay raw is refused (compress returns an error).
- **ZPAQL**: `pas/plugin/j2kzpaql.inc`, **51,521 bytes of PCOMP** (zpaqlc
  opt=3), config `comp 0 0 $3 $4 0`. `query(ZS_QUERY_ZPAQL_ARGS)` gives
  `$3` (log2 of H's words) in bits 0-7 and `$4` (log2 of M's bytes) in
  bits 8-15; `ZS_QUERY_SEGMENTS` 1 (several files a block). The decoder
  measures both when it starts and stops with an error rather than go past
  either; the plugin takes a codestream in mode 1 only within H 2^26 words
  and M 2^28 bytes.
- **Ratio**: on 113 real codestreams (150 MB: Internet Archive, Library of
  Congress, OSGeo, Helioviewer, Sentinel-2, DICOM) about 7.7% saved (the
  command, with its pixel modes, 8.4%).
- **Speed**: the plugin decodes about 0.3 MB/s on one thread; the ZPAQL
  (libzpaq's JIT) is 4.7 to 7.9 times slower. zpaq-std decodes every
  `-sat` block with the ZPAQL before writing it, so writing costs that too.
- **Name**: it does not end in `z`, `o` or `8` (`zpaqstd_detect_v1`'s
  suffixes of other families). Frozen from 0.9.6: the name, its stream,
  what it takes and its ZPAQL.
- zpaq-std 2.3.0 does not have `pja2k` in `-sa`'s list; it is used with
  `-sae:pja:pja2k` or `-sat:pja:pja2k`.
- **Checked**: libzpaq (zpaq 7.15's engine) gives back byte for byte the
  15 files of PJA's `tests/j2k` and the 113 real codestreams, each with
  its query's H and M; zpaq-std 2.3.0 on Windows 10 x64 (`-sae:pja:pja2k
  -t4`, 8 JPEG 2000 files) and then zpaq 7.15 (`zpaq64.exe`, no plugin)
  extracting them all byte for byte; 300 damaged segments through libzpaq,
  no hang or crash.

New files: `pas/pjaj2kcs.pas`, `pas/pjaj2km.pas` (the analysis, rebuild
and mode 1), `pas/pjaj2kht.c`, `pas/pjaj2khm.c`, `pas/pjaj2kht_tab.h`
(HTJ2K, linked through pjaj2kcs.pas; the plugin does not use it),
`pas/plugin/pjazsj2k.pas` (the codec) and `pas/plugin/j2kzpaql.inc`.
`pas/build_c.sh` compiles the new C files.

Also in the shared sources since 0.9.5 (the same streams for codecs 0 to
29): `pja`'s command shares its threads by file size; JPEG 2000 has SIMD
copies of its models (taken by cpuid; every copy writes the same bits).

As in 0.6.1, either clang or gcc builds these sources; clang is the faster.
Checked: built from this directory alone (build_c.sh, then fpc as below),
the plugin lists the thirty-one codecs, pja2k at 30, and PJA's plugin
probe passes on `tests/j2k` and `tests/jpg`.

## What is new in 0.9.5

The JPEG 2000 sources (`pjaj2k.pas`, `pjaj2kt1.c`, `pjaj2kmc.c`,
`pjaj2kpm.c`), `pjathread.pas` (a thread wait without FreePascal's 100 ms
poll), `pjastage.pas` (the command's `--stats`, inert in the plugin), and
the raw-byte model's loop in C; no codec changed.

## What is new in 0.8.0: the 8 codecs

Ten codecs, indices 20 to 29 of `zpaqstd_codecs_v1`; 0 to 19 are 0.7.0's,
unchanged (streams, ZPAQL, what each takes). Each is the codec its name
has without the 8, with the same library field, streams, detect,
compress, decompress, query, H and config, and its ZPAQL compiled with
zpaqlc's opt=3 (`pas/plugin/v8zpaql.inc`): inlining, the right operand
and return values through B.

| index | codec | is | ZPAQL (PCOMP) | before |
|---|---|---|---|---|
| 20 | `pja78` | pja7 | 32,954 bytes | 35,104 |
| 21 | `pjax78` | pjax7 | 33,197 bytes | 35,211 |
| 22 | `pja7z8` | pja7z | 33,603 bytes | 35,829 |
| 23 | `pjax7z8` | pjax7z | 33,949 bytes | 35,987 |
| 24 | `pjals8` | pjals (as pjalso) | 22,430 bytes | 24,076 |
| 25 | `pjall8` | pjall (as pjallo) | 13,901 bytes | 15,058 |
| 26 | `pjalsx8` | pjalsx (as pjalsxo) | 24,611 bytes | 25,623 |
| 27 | `pjalsz8` | pjalsz (as pjalszo) | 23,046 bytes | 24,724 |
| 28 | `pjallz8` | pjallz (as pjallzo) | 14,517 bytes | 15,693 |
| 29 | `pjalsxz8` | pjalsxz (as pjalsxzo) | 25,244 bytes | 26,278 |

- In `-sa`, the ten take the place of pja7, pjax7, pjall, pjals, pjalsx
  and their z (or of the o codecs); those stay to read older archives.
- libzpaq (zpaq 7.15's engine) extracts with them 2 to 6% faster, every
  file back: 30 photos, 18 MPO and 12-bit JPEGs, 24 JPEG-LS, 36 lossless
  JPEGs, 67 subsampled JPEG-LS.
- Checked on Windows XP: zpaq 7.15 (32-bit, no plugin) extracts archives
  written by zpaq-std 2.2.2 with pja78, pjax78, pjals8, pjall8 and pjalsx8
  byte for byte, and the x86 plugin round-trips every file with each of
  the ten.
- Frozen in 0.8.0: the ten names, their streams and their ZPAQL.

As in 0.6.1, either clang or gcc builds these sources; clang is the faster.

## What is new in 0.7.0: the o codecs

Six codecs, indices 14 to 19 of `zpaqstd_codecs_v1`; 0 to 13 are 0.6.4's,
unchanged (streams, ZPAQL, what each takes):

| index | codec | is | ZPAQL (PCOMP) | frozen one it replaces in `-sa` |
|---|---|---|---|---|
| 14 | `pjalso` | pjals | 24,076 bytes | pjals, 55,989 |
| 15 | `pjallo` | pjall | 15,058 bytes | pjall, 30,508 |
| 16 | `pjalsxo` | pjalsx | 25,623 bytes | pjalsx, 60,776 |
| 17 | `pjalszo` | pjalsz | 24,724 bytes | pjalsz, 32,984 |
| 18 | `pjallzo` | pjallz | 15,693 bytes | pjallz, 18,003 |
| 19 | `pjalsxzo` | pjalsxz | 26,278 bytes | pjalsxz, 36,110 |

- Each o codec is its codec with another ZPAQL: the same library field,
  streams, detect, compress, decompress and query (its H is its codec's
  to the word), and the same config (`comp 0 0 $3 $1+1 0`; the z ones
  `comp 0 0 $3 $1 0`). The decoders are the same programs compiled with
  zpaqlc's opt=2, in `pas/plugin/ozpaql.inc`.
- libzpaq (zpaq 7.15's engine) extracts with them 2.2 to 2.3 times as
  fast: JPEG-LS 78.5 -> 36.2 s (24 files), lossless JPEG 2.8 -> 1.2 s
  (36), subsampled JPEG-LS 410.9 -> 178.6 s (67), every file back.
- Checked on Windows XP: zpaq 7.15 (32-bit, no plugin) extracts archives
  written by zpaq-std 2.2.2 with pjalso, pjallo and pjalsxo byte for byte,
  and the x86 plugin round-trips every file with each of the six.
- Frozen in 0.7.0: the six names, their streams and their ZPAQL.

As in 0.6.1, either clang or gcc builds these sources; clang is the faster.

## What is new in 0.6.0

Four codecs, indices 10 to 13 of `zpaqstd_codecs_v1`; 0 to 9 are 0.5.3's,
unchanged (streams, ZPAQL, what each takes):

| index | codec | takes | stream | ZPAQL |
|---|---|---|---|---|
| 10 | `pja7` | what `pja` takes | version 7 | `PJA7_ZPAQL`, 35,104 bytes, `comp 0 0 $3 $1+1 0` |
| 11 | `pjax7` | what `pjax` takes | `pjax`'s version 6, its parts version 7 | `PJAX7_ZPAQL`, 35,211 bytes |
| 12 | `pja7z` | what `pja` takes | as `pja7`, through the block's LZ77 (as `pjaz`) | `PJA7Z_ZPAQL`, 35,829 bytes, `comp 0 0 $3 $1 0` |
| 13 | `pjax7z` | what `pjax` takes | as `pjax7`, through the LZ77 (as `pjaxz`) | `PJAX7Z_ZPAQL`, 35,987 bytes |

- The ZPAQL decoders are in `pas/plugin/v7zpaql.inc` (handed out as
  `ZS_DATA_ZPAQL_ARGS`), `$3` from each codec's `query(ZS_QUERY_ZPAQL_ARGS)`
  (`ZpaqlArgs7`, `ZpaqlPjaxArgs(..., True)`), several segments a block.
  A z codec's compress, decompress, query and detect are its codec's.
- Detection: `pja7` and `pjax7` take what `pja` and `pjax` take, with the
  memory of version 7's decoder under the same cap (2^26 words): its
  models are 210,731 words each, two a band (version 5's: about 77,500).
- The plugin now links C: the version 7 model (`pjav7c.c`,
  `pjav7c_loop.h`) and its helpers (`pjasysc.c`), through `pjav7.pas`.
  They call no library and need no C runtime: the Windows DLL imports only
  kernel32, oleaut32 and user32, as before. x86 and x64 write the same
  bytes (checked: pja7 on 20 photos, pjax7 on an MPO; PJA's CI compares
  every platform's streams).

## Building

FreePascal 3.2.2 and a C compiler (clang, the faster, or gcc) for the same
target. The C first (`pas/build_c.sh <dir> [flags]`: `-O3 -fwrapv
-ffp-contract=off -fno-stack-protector`, and `-fno-builtin` with clang or
`-fno-tree-loop-distribute-patterns` with gcc), then fpc with `-Fo<dir>` so `pjav7.pas`'s `{$L pjav7c.o}` and
`{$L pjasysc.o}` find the objects. From this directory:

```sh
export PJA_COMMIT=e89a500
```

Linux x86_64 (position-independent C, `-fPIC`, and `-Cg`):

```sh
sh pas/build_c.sh build/lin/c -fPIC
fpc -O3 -dPJA_FAST -Cg -Fupas -Fipas -Fupas/plugin -Fipas/plugin -Fobuild/lin/c \
    -FUbuild/lin -obuild/lin/pja.so pas/plugin/pja_zpaqstd.pas
```

Linux x86 (32-bit): `CC="gcc -m32" sh pas/build_c.sh build/l32/c -fPIC`, then
the i386 fpc with `-Fobuild/l32/c`, as above.

Linux arm64: `CC=aarch64-linux-gnu-gcc sh pas/build_c.sh build/a64/c -fPIC`
(or the native gcc), then fpc for aarch64 with `-Fobuild/a64/c -Cg`.

Windows x64 (no `-fPIC`):

```sh
CC=x86_64-w64-mingw32-gcc sh pas/build_c.sh build/win64/c
fpc -Twin64 -Px86_64 -O3 -dPJA_FAST -Fupas -Fipas -Fupas/plugin -Fipas/plugin -Fobuild/win64/c \
    -FUbuild/win64 -obuild/win64/pja.dll pas/plugin/pja_zpaqstd.pas
```

Windows x86: `CC=i686-w64-mingw32-gcc sh pas/build_c.sh build/win32/c`
(build_c.sh adds `-fno-pic` for 32-bit x86), then `ppc386 -n -Twin32 ...
-Fobuild/win32/c`, as 0.5.3's with `-Fo` added.

macOS arm64: `sh pas/build_c.sh build/mac/c -fPIC` with clang, then fpc with
`-Fobuild/mac/c -Cg`, output `pja.so` (zpaq-std loads `codecs/<name>.so` off
Windows; 0.6.3's release named it `pja.dylib`).

`-dPJA_FAST` as before. On x86 the C has SSE4.1 and AVX2 copies of its
loop, taken by cpuid at run time; every copy writes the same bits.

## Checked

zpaq-std, through its whole path (`-sa -t8`, branch exp/v7, against its
2.0.3): photos -3.1%, corpus -2.4%, MPO -1.0%, arithmetic-coded -3.1%,
generated -2.6%; writing 1.3 to 1.6 times as fast, extracting natively
1.2 to 1.6 times, zpaq 7.15 with the ZPAQL 1.5 to 1.6 times. Every file
back, natively and with zpaq 7.15, with the smallest valid window forced
in each group too; its CI (run 41227860640) on its six platforms, the
same archive on every one.

PJA: every file back, natively and through the ZPAQL with libzpaq (zpaq
7.15's engine), at the `$3` the query gives:

| set | v5 codec | v7 codec | compress (one thread) | decompress |
|---|---|---|---|---|
| 151 photos (pja / pja7) | 75.03% | **72.68%** | 52.7 -> 33.5 s | 53.5 -> 35.9 s |
| corpus, the 65 pja takes | 73.85% | **72.22%** | 25.6 -> 19.6 s | 20.4 -> 15.2 s |
| 244 arithmetic-coded | 76.35% | **74.44%** | 6.2 -> 5.0 s | 5.9 -> 4.8 s |
| 640 generated | 75.47% | **73.58%** | 12.5 -> 9.4 s | 12.9 -> 10.1 s |
| MPO, the 4 pjax takes (pjax / pjax7) | 73.93% | **73.18%** | 23.5 -> 16.8 s | 22.1 -> 16.0 s |

The ZPAQL: libzpaq extracts 30 photos in 46.4 s with pja7's, 108.6 s with
pja's. In one block through a test LZ77 (the z, $1 = 24): arithmetic
17.70% (pjaz) -> 17.18% (pja7z), generated 16.77% -> 16.34%; MPO + corpus
through pjax7z 70.47%; a 4 KB window too; 150 damaged segments a codec,
no hang. PJA's suite decodes pja7 and pjax7 segments, and their z, in its
ZPAQL interpreter.

## Frozen

`pja7`, `pjax7`, `pja7z` and `pjax7z`: their streams, their ZPAQL
(`pas/plugin/v7zpaql.inc`) and what each takes do not change under these
names, as codecs 0 to 9's.
