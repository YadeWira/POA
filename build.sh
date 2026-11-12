#!/bin/bash
# Builds poa (release: -O3, POA_FAST for the model units) and the tests
# (-O1 with every check on) into build/ (or $1).
#   ./build.sh            -> build/poa, build/tests/*
#   FPC="fpc -Pi386" ./build.sh build32
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/build}
FPC=${FPC:-fpc}
mkdir -p "$OUT/rel" "$OUT/tests/u"
$FPC -O3 -dPOA_FAST -Fu"$HERE/pas" -FU"$OUT/rel" -o"$OUT/poa" "$HERE/pas/poa.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
for t in test_ogg test_vorbis test_vbmodel test_side test_blake3; do
  $FPC -O1 -Fu"$HERE/pas" -FU"$OUT/tests/u" -o"$OUT/tests/$t" "$HERE/pas/tests/$t.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done
echo "built $OUT/poa and $OUT/tests"
