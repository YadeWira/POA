#!/bin/sh
# What CI runs on every platform: build (FPC from $FPC), the unit tests,
# the command line's checks, the round trip of every sample, libpoa (its C
# test, and 7-Zip with the plugin where there is one), and hash.txt:
# the SHA-256 of every sample's .poa, which must be the same everywhere.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
case ${CC:-} in /*) PATH=$(dirname "$CC"):$PATH; export PATH ;; esac
./build.sh build/ci
OUT=$HERE/build/ci
FPC=${FPC:-fpc}
T=$OUT/tests
"$T/test_blake3" pas/tests/kat.txt | tail -1
"$T/test_side" | tail -1
"$T/test_ogg" tests/ogg/* | tail -1
"$T/test_vorbis" tests/ogg/*.og? | tail -1
"$T/test_vbmodel" tests/ogg/*.og? | tail -1
POA=$OUT/poa pas/tests/cli.sh | tail -1
"$OUT/poa" selftest | tail -1
POA=$OUT/poa LC_ALL=C pas/tests/corpus.sh tests/ogg/* | tail -1
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
echo "== libpoa"
# a C compiler given by its full path (MSYS2's MinGW-w64 gcc on Windows)
# needs its own folder on PATH for its DLLs and its cc1/as; without it, it
# fails without a word (from PJA's test.sh)
case ${CC:-} in /*) PATH=$(dirname "$CC"):$PATH; export PATH ;; esac
# a few samples of each codec: the test runs each one several ways
LIBSET="tests/ogg/vorbis_click.ogg tests/ogg/vorbis_q3_8000_mono.ogg tests/ogg/vorbis_chained.ogg tests/ogg/vorbis_51.ogg tests/ogg/opus_16k_mono.opus tests/ogg/speex_16k.spx tests/ogg/theora_vorbis.ogv"
sh pas/lib/build.sh "$OUT/lib" > "$OUT/lib.log" 2>&1 || { cat "$OUT/lib.log"; echo "FAIL: libpoa did not build"; exit 1; }
LIBF=$(tail -1 "$OUT/lib.log")
# its C objects call no library either (the DLL has no C runtime)
# (the objects' own symbols aside: poa7z.o calls poafilter.o)
# (the 32-bit PIC objects name the GOT, which the linker makes: not a library)
if [ "$(uname -s)" = Linux ] && command -v nm > /dev/null; then
  nm "$OUT"/lib/c/*.o | awk '$2 ~ /^[TDBR]$/ {print $3}' | sort -u > "$OUT/lib/defined.txt"
  nm -u "$OUT"/lib/c/*.o | awk 'NF {print $NF}' | grep -v ':$' | grep -vx '_GLOBAL_OFFSET_TABLE_' | sort -u | comm -23 - "$OUT/lib/defined.txt" > "$OUT/lib/undefined.txt"
  if [ -s "$OUT/lib/undefined.txt" ]; then cat "$OUT/lib/undefined.txt"; echo "FAIL: libpoa's C objects need a library"; exit 1; fi
fi
# the test finds the library by its rpath alone (no DYLD_LIBRARY_PATH: on
# macOS the install name a program records is @rpath/poa.dylib, not the
# path the library was built at)
RP=; case "$(uname -s)" in Linux) RP="-pthread -Wl,-rpath,$(dirname "$LIBF")" ;; Darwin) RP="-Wl,-rpath,$(dirname "$LIBF")" ;; esac
if [ "$(uname -s)" = Darwin ]; then
  ID=$(otool -D "$LIBF" | tail -1)
  [ "$ID" = "@rpath/poa.dylib" ] || { echo "FAIL: libpoa's install name is $ID"; exit 1; }
fi
# shellcheck disable=SC2086
${CC:-cc} -O2 -Ipas/lib pas/lib/test_lib.c -o "$OUT/lib/test_lib$EXE" "$LIBF" $RP
"$OUT/lib/test_lib$EXE" $LIBSET > "$OUT/lib/test.txt" \
  || { cat "$OUT/lib/test.txt"; echo "FAIL: libpoa's test"; exit 1; }
tail -3 "$OUT/lib/test.txt"
# 7-Zip 23 or later (not p7zip, whose IUnknown differs): a copy with the
# plugin in its Codecs folder (the same word size as the library), an
# archive written and extracted. Linux: 7-Zip's package; Windows: the
# 7-Zip installed (64-bit on the runners), and for a 32-bit library the
# 32-bit 7-Zip in SEVEN32 (CI's windows-x86 job unpacks one there: the
# Windows XP heap fault of 0.1.1 showed only in a 32-bit 7-Zip)
case "$LIBF" in
  *.dll) SEVEN="/c/Program Files/7-Zip"; SLIB=7z.dll
    [ -f "$SEVEN/$SLIB" ] || { S=$(command -v 7z 2> /dev/null) && SEVEN=$(dirname "$S"); } || SEVEN= ;;
  *.so) SEVEN=/usr/lib/7zip; SLIB=7z.so ;;
  *) SEVEN=; SLIB= ;;
esac
case "${CC:-} $FPC" in *-m32*|*i386*) SEVEN=${SEVEN32:-} ;; esac
if [ -z "$SEVEN" ] || [ ! -f "$SEVEN/$SLIB" ] || [ ! -f "$SEVEN/7z$EXE" ]; then
  echo "7-Zip: none of the library's word size here, not tried"
else
  Z="$OUT/7z"; rm -rf "$Z" "$OUT/7in" "$OUT/7x" "$OUT/a.7z"; mkdir -p "$Z/Codecs" "$OUT/7in" "$OUT/7x"
  cp "$SEVEN/7z$EXE" "$SEVEN/$SLIB" "$Z/"
  cp "$LIBF" "$Z/Codecs/"
  cp tests/ogg/* README.md "$OUT/7in/"
  "$Z/7z$EXE" i | grep -q '37F50 POA' || { echo "FAIL: 7-Zip does not list POA (37F50)"; exit 1; }
  # a fresh folder and -y: 7-Zip asks before replacing a file, and waits for
  # an answer that never comes (a rerun in the same tree hung that way); a
  # hang is a failure anyway, with the step (timeout where there is one)
  TO=; command -v timeout > /dev/null && TO="timeout 600"
  (cd "$OUT/7in" && $TO "../7z/7z$EXE" a -bso0 -bsp0 -m0=POA -m1=LZMA2 ../a.7z .) || { echo "FAIL: 7z a (exit $?)"; exit 1; }
  $TO "$Z/7z$EXE" x -y -bso0 -bsp0 -o"$OUT/7x" "$OUT/a.7z" || { echo "FAIL: 7z x (exit $?)"; exit 1; }
  for f in "$OUT"/7in/*; do
    cmp -s "$f" "$OUT/7x/$(basename "$f")" || { echo "FAIL: 7-Zip: $(basename "$f") does not come back"; exit 1; }
  done
  echo "7-Zip with the POA plugin: every sample back, $(wc -c < "$OUT/a.7z" | tr -d ' ') bytes"
fi

# the .poa of every sample, hashed
D=$OUT/poas
rm -rf "$D"; mkdir -p "$D"
for f in tests/ogg/*; do
  "$OUT/poa" a -q --no-sync "$f" -o "$D/$(basename "$f").poa"
done
python3 -c '
import hashlib, os, sys
d = sys.argv[1]
for n in sorted(os.listdir(d)):
    print(hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest(), n)
' "$D" > hash.txt
echo "hash.txt: $(wc -l < hash.txt) streams"
