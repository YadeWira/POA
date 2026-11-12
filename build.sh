#!/bin/bash
# Builds poa (release: -O3, POA_FAST for the model units) and the tests
# (-O1 with every check on) into build/ (or $1).
#   ./build.sh            -> build/poa, build/tests/*
#   FPC="fpc -Pi386" ./build.sh build32
# poa --version shows the commit from POA_COMMIT, taken from git when it is
# not set (a build outside git says "commit:" and nothing).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export POA_COMMIT=${POA_COMMIT:-$(git -C "$HERE" describe --always --dirty --abbrev=7 2> /dev/null || true)}
OUT=${1:-build}
FPC=${FPC:-fpc}
# FPC gets paths relative to the repository: on Windows (Git Bash) an
# absolute /d/a/... path would reach it mangled. OUT is relative to it too.
cd "$HERE"
HERE=.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
mkdir -p "$OUT/rel" "$OUT/tests/u" "$OUT/c"
# the vendored PJA's C part (the covers' JPEGs), objects found through -Fo
sh vendor/pja/pas/build_c.sh "$OUT/c" > "$OUT/cc.log" 2>&1 || { cat "$OUT/cc.log"; exit 1; }
V="-Fuvendor/pja/pas -Fivendor/pja/pas -Fo$OUT/c"
# -B: the program is rebuilt every time, so that it takes the commit and the date
$FPC -B -O3 -dPOA_FAST -dPJA_FAST $V -Fu"$HERE/pas" -FU"$OUT/rel" -o"$OUT/poa$EXE" "$HERE/pas/poa.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
cp "$OUT/fpc.log" "$OUT/fpc-poa.log"
for t in test_ogg test_vorbis test_vbmodel test_side test_blake3; do
  $FPC -O1 $V -Fu"$HERE/pas" -FU"$OUT/tests/u" -o"$OUT/tests/$t$EXE" "$HERE/pas/tests/$t.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done
echo "built $OUT/poa and $OUT/tests"
