#!/bin/bash
# Builds the Windows test kits (w64.zip, w32.zip) for scripts/vm-test.bat
# from a CI run's binaries: poa.exe and poa.dll, test_lib.exe (built here
# with MinGW against that DLL), some samples, and a portable 7-Zip of each
# word size. Then, on a Windows VM: unzip, run test.bat, read PASS/FAIL.
#   scripts/vm-kit.sh RUN_ID OUT_DIR 7ZIP64_DIR 7ZIP32_DIR
# (7ZIP*_DIR: a folder with 7z.exe and 7z.dll of 7-Zip 23 or later)
set -euo pipefail
RUN=$1 OUT=$2 Z64=$3 Z32=$4
HERE=$(cd "$(dirname "$0")/.." && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"
gh run download "$RUN" -R YadeWira/POA -n bin-windows-x64 -D "$OUT/w64"
gh run download "$RUN" -R YadeWira/POA -n bin-windows-x86 -D "$OUT/w32"
x86_64-w64-mingw32-gcc -O2 -I"$HERE/pas/lib" "$HERE/pas/lib/test_lib.c" -o "$OUT/w64/test_lib.exe" "$OUT/w64/poa.dll"
i686-w64-mingw32-gcc -O2 -I"$HERE/pas/lib" "$HERE/pas/lib/test_lib.c" -o "$OUT/w32/test_lib.exe" "$OUT/w32/poa.dll"
cp -r "$Z64" "$OUT/w64/7z"; cp -r "$Z32" "$OUT/w32/7z"
rm -rf "$OUT/w64/7z/Codecs" "$OUT/w32/7z/Codecs"
for a in w64 w32; do
  mkdir -p "$OUT/$a/s"
  cp "$HERE"/tests/ogg/{vorbis_click.ogg,vorbis_q3_8000_mono.ogg,vorbis_chained.ogg,vorbis_51.ogg,opus_16k_mono.opus,speex_16k.spx,theora_vorbis.ogv,vorbis_q6_44k_st.ogg} "$OUT/$a/s/"
  cp "$HERE/scripts/vm-test.bat" "$OUT/$a/test.bat"
  (cd "$OUT/$a" && zip -qr "../$a.zip" .)
done
ls -la "$OUT"/*.zip
