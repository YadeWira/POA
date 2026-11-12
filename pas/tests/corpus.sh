#!/bin/bash
# Compress, extract and compare every file given; prints one line per file
# and a total. Exit 1 if any file does not come back byte for byte.
set -u
POA=${POA:-$(dirname "$0")/../../build/poa}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fail=0; ta=0; tc=0
for f in "$@"; do
  n=$(basename "$f")
  if ! "$POA" a "$f" -o "$W/$n.poa" > "$W/log" 2>&1; then
    echo "FAIL(a) $n: $(head -1 "$W/log")"; fail=1; continue
  fi
  if ! "$POA" x "$W/$n.poa" -o "$W/$n" > /dev/null 2>&1 || ! cmp -s "$f" "$W/$n"; then
    echo "FAIL(x) $n"; fail=1; continue
  fi
  a=$(stat -c%s "$f"); c=$(stat -c%s "$W/$n.poa")
  ta=$((ta + a)); tc=$((tc + c))
  printf '%10d -> %10d  %6.2f%%  %s\n' "$a" "$c" "$(echo "100*$c/$a" | bc -l)" "$n"
  rm -f "$W/$n" "$W/$n.poa"
done
printf 'total %d -> %d  %.2f%%\n' "$ta" "$tc" "$(echo "100*$tc/($ta+1)" | bc -l)"
exit $fail
