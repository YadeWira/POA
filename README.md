# POA

**packOGG Algorithm**: lossless recompression of **Ogg** files (Vorbis,
Opus, FLAC, Speex, Theora), in FreePascal; no
libraries. A new project of the
[pack-algorithm family](https://github.com/YadeWira/PJA): it has its own
codec and format, and every file is verified before anything is written.

**Status: early development.** There is no release yet and the format
still changes. What works today:

- the Ogg container (pages, CRCs, logical streams, chained files, junk
  between pages) is rebuilt byte for byte from the packets;
- Vorbis audio packets are read down to their symbols and coded with a
  context-mixing model; Vorbis headers are predicted from a dictionary of
  libvorbis setups;
- cover art in Vorbis and Opus comment headers (METADATA_BLOCK_PICTURE) is
  taken out of its base64, and a JPEG picture goes through PJA (vendored,
  0.9.8): a Vorbis file with a 17.6 KB cover went from 55.93% to 30.26%;
- the other codecs (Opus, Speex, FLAC, Theora) are coded as bytes for now;
- libpoa (`pas/lib/poa.h`) is POA as a C library and, in the same file, a
  7-Zip plugin: the method `POA` (`7z a -m0=POA -m1=LZMA2 music.7z music/`),
  see [doc/LIBRARY.md](doc/LIBRARY.md).

Vorbis, measured on 11/11/2026 against balrogg 1.3 (`-4`, the default) on
the 45 Vorbis files both take from our test sets (9,867,467 bytes):

| Tool | Output | Of the input |
|---|---|---|
| balrogg 1.3 | 8,410,830 | 85.24% |
| POA (main) | 8,214,122 | 83.24% |

balrogg refuses 4 more files of the set (old 2001 encoders); POA takes
them (70-89%). POA is about 10x slower than balrogg for now.

| Sibling | Formats | Successor of |
|---|---|---|
| [PJA](https://github.com/YadeWira/PJA) | JPEG, JPEG-LS and JPEG 2000 | [packJPG](https://github.com/YadeWira/packJPG) |
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| **POA** | Ogg (Vorbis, Opus, FLAC, Speex, Theora) | (new) |

## Building

FreePascal 3.2.2 or later, no libraries:

    ./build.sh                       # build/poa and build/tests/*
    build/poa a file.ogg             # -> file.ogg.poa (verified before writing)
    build/poa x file.ogg.poa -o out.ogg
    pas/tests/corpus.sh tests/ogg/*  # round trip of the test samples

## License

MIT (see [LICENSE](LICENSE)); third-party credits in [NOTICE](NOTICE).
