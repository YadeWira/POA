#!/bin/sh
# What CI runs on every platform: build (FPC from $FPC), the unit tests,
# the command line's checks, the round trip of every sample, and hash.txt:
# the SHA-256 of every sample's .poa, which must be the same everywhere.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
./build.sh build/ci
OUT=$HERE/build/ci
T=$OUT/tests
"$T/test_blake3" pas/tests/kat.txt | tail -1
"$T/test_side" | tail -1
"$T/test_ogg" tests/ogg/* | tail -1
"$T/test_vorbis" tests/ogg/*.og? | tail -1
"$T/test_vbmodel" tests/ogg/*.og? | tail -1
POA=$OUT/poa pas/tests/cli.sh | tail -1
"$OUT/poa" selftest | tail -1
POA=$OUT/poa LC_ALL=C pas/tests/corpus.sh tests/ogg/* | tail -1
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
