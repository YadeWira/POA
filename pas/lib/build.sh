#!/bin/sh
# libpoa: POA as a shared library (poa.h) and 7-Zip codec plugin, from
# poalib.pas, the filter (poafilter.c) and the 7-Zip side (poa7z.c), all
# position-independent. From PPA's pas/lib/build.sh (itself from PJA's).
#
#   pas/lib/build.sh <out dir>     -> <out dir>/poa.so (poa.dll, poa.dylib)
#
# FPC picks the FreePascal compiler and its target options (fpc by default:
# "fpc -Twin64 -Px86_64" cross-compiles), CC the C compiler for the same
# target.
set -eu
OUT=${1:?usage: build.sh <out dir>}
# a folder's absolute path; on Windows (MSYS, Git Bash) in Windows' form,
# since FreePascal gets it glued to an option (-Fu...), which MSYS does not
# translate
apath() {
  p=$(cd "$1" && pwd)
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) p=$(echo "$p" | sed -E 's|^/([A-Za-z])/|\1:/|') ;; esac
  echo "$p"
}
HERE=$(apath "$(dirname "$0")"); PAS=$(dirname "$HERE")
FPC=${FPC:-fpc}
CC=${CC:-cc}
mkdir -p "$OUT/c" "$OUT/u"
OUT=$(apath "$OUT")
# Windows: a native build (MSYS, Git Bash: by uname, as .github/test.sh)
# or a cross one
WIN=; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; esac
case "$CC $FPC" in *mingw*|*-Twin*) WIN=1 ;; esac
if [ -n "$WIN" ]; then PIC=; EXT=dll; else PIC=-fPIC; EXT=so; fi
# macOS: the install name is @rpath/poa.dylib, not the path it was built
# at, so that a program linked against it finds it by its own rpath
LDN=
if [ -z "$WIN" ] && [ "$(uname -s)" = Darwin ]; then EXT=dylib; LDN="-k-install_name -k@rpath/poa.dylib"; fi
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector"
# no memset or memcpy calls: the DLL has no C runtime
if $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-builtin"
else
  FLAGS="$FLAGS -fno-tree-loop-distribute-patterns"
fi
# 32-bit x86: any 686
case "$CC $($CC -dumpmachine 2>/dev/null)" in
  *-m32*|*i686*|*i386*|*i586*) FLAGS="$FLAGS -march=i686" ;;
esac
# shellcheck disable=SC2086
for f in poafilter poa7z; do
  $CC $FLAGS $PIC -c "$HERE/$f.c" -o "$OUT/c/$f.o"
done
CG=; [ -n "$PIC" ] && CG=-Cg
echo "units from $PAS, objects in $OUT/c"
# MSYS would take "-Fud:/..." for a list of paths (the colon) and rewrite
# it: no conversion for FreePascal's arguments
# shellcheck disable=SC2086
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' $FPC -O3 -dPOA_FAST $CG $LDN -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$OUT/u" -o"$OUT/poa.$EXT" "$HERE/poalib.pas" \
  > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
echo "$OUT/poa.$EXT"
