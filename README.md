# POA

**packOGG Algorithm**: lossless recompression of **Ogg** files (Vorbis,
Opus, FLAC, Speex, Theora), in FreePascal, with C for the hot loops; no
libraries. A new project of the
[pack-algorithm family](https://github.com/YadeWira/PJA): it has its own
codec and format, and every file is verified before anything is written.

**Status: early development.** There is no release yet. The Ogg container
layer (pages, CRCs, logical streams, packets) is done and rebuilds every
test file byte for byte; the codec models come next.

| Sibling | Formats | Successor of |
|---|---|---|
| [PJA](https://github.com/YadeWira/PJA) | JPEG, JPEG-LS and JPEG 2000 | [packJPG](https://github.com/YadeWira/packJPG) |
| [PMPA](https://github.com/YadeWira/PMPA) | MPEG audio (MP1, MP2, MP3) | [packMP3](https://github.com/YadeWira/packMP3), [packMP2](https://github.com/YadeWira/packMP2) |
| [PRA](https://github.com/YadeWira/PRA) | raster images (PNM, BMP, TIFF, PSD, HDR, ...) | [packPNM](https://github.com/packjpg/packPNM) |
| [PPA](https://github.com/YadeWira/PPA) | the PNG family (PNG, APNG, MNG, JNG) | [packPNG](https://github.com/YadeWira/packPNG) |
| [PAIA](https://github.com/YadeWira/PAIA) | animated images (GIF, WebP, FLI/FLC, ANI, ...) | (new) |
| **POA** | Ogg (Vorbis, Opus, FLAC, Speex, Theora) | (new) |

## Building

FreePascal 3.2.2 or later:

    fpc -O2 -Fupas -FUbuild -FEbuild pas/tests/test_ogg.pas
    ./build/test_ogg file.ogg ...

## License

MIT (see [LICENSE](LICENSE)); third-party credits in [NOTICE](NOTICE).
