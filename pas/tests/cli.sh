#!/bin/bash
# The command line: exit codes, naming, refusals, --json, t, list, info,
# selftest, report, -n, --clean-temps. Exit 1 at the first failure.
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
POA=${POA:-$HERE/build/poa}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cd "$W"
n=0
ok()   { n=$((n + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1"; exit 1; }
rc()   { "$@" > out.txt 2> err.txt; echo $?; }
expect() { local want=$1 what=$2; shift 2; local got; got=$(rc "$@"); [ "$got" = "$want" ] && ok "$what (exit $want)" || { cat err.txt; fail "$what: exit $got, want $want"; }; }

cp "$HERE/tests/ogg/vorbis_click.ogg" a.ogg
cp "$HERE/tests/ogg/opus_16k_mono.opus" b.opus
echo "not ogg at all" > c.txt

expect 0 "a two files"             "$POA" a a.ogg b.opus
[ -f a.ogg.poa ] && [ -f b.opus.poa ] && ok "outputs named FILE.poa" || fail "outputs"
expect 1 "a refuses an existing output" "$POA" a a.ogg
expect 0 "a -f replaces it"        "$POA" a -f a.ogg
expect 1 "a refuses a non-Ogg file" "$POA" a c.txt
expect 2 "unknown command"         "$POA" zz a.ogg
expect 2 "unknown option"          "$POA" a --zz a.ogg
expect 2 "--cpu=avx2 refused"      "$POA" a --cpu=avx2 a.ogg
expect 0 "t"                       "$POA" t a.ogg.poa b.opus.poa
expect 0 "list"                    "$POA" list a.ogg.poa
expect 0 "info on Ogg and .poa"    "$POA" info a.ogg a.ogg.poa
expect 0 "x -o"                    "$POA" x a.ogg.poa -o back.ogg
cmp -s a.ogg back.ogg && ok "x gives the original" || fail "x output differs"
expect 1 "x refuses an existing output" "$POA" x a.ogg.poa -o back.ogg
head -c 300 a.ogg.poa > bad.poa
expect 1 "x of a truncated .poa"   "$POA" x bad.poa -o bad.ogg
[ ! -e bad.ogg ] && ok "nothing written for it" || fail "bad.ogg written"
expect 1 "t of a truncated .poa"   "$POA" t bad.poa
"$POA" t --json a.ogg.poa b.opus.poa > j.txt && python3 -c 'import json,sys; [json.loads(l) for l in open("j.txt")]' \
  && ok "--json lines parse" || fail "--json"
expect 0 "-n writes nothing"       "$POA" a -n -o dry.poa a.ogg
[ ! -e dry.poa ] && ok "no dry.poa" || fail "dry run wrote"
expect 0 "selftest"                "$POA" selftest
expect 0 "report without a file"   "$POA" report
expect 2 "report --with-file without a file" "$POA" report --with-file
touch .poa-tmp-99999-1
python3 -c 'import os,time; t=time.time()-7200; os.utime(".poa-tmp-99999-1",(t,t))'
expect 0 "--clean-temps"           "$POA" a -f --clean-temps a.ogg
[ ! -e .poa-tmp-99999-1 ] && ok "old temporary deleted" || fail "temporary left"
expect 0 "--version"               "$POA" --version
echo "$n checks passed"
