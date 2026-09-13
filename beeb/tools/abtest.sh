#!/bin/sh
# A/B the working tree against the committed baseline in build/bench_L<n>.json.
#   ./tools/abtest.sh <name> ["<levels>"]
# Builds the current (possibly dirty) tree, benches it, and prints signed deltas plus
# the scene-agreement check -- a delta is only meaningful where the scene matched.
set -e
cd "$(dirname "$0")/.."
NAME=${1:-cand}
LEVELS=${2:-"0 1 6"}
OUT=build/ab/$NAME
mkdir -p "$OUT"
./build.sh >/dev/null
cp build/cleo.ssd build/labels.txt "$OUT/"
for l in $LEVELS; do node tools/bench.mjs "$l" "$OUT/L$l.json" "$OUT/cleo.ssd" "$OUT/labels.txt" >/dev/null & done
wait
for l in $LEVELS; do
  printf '=== L%s ' "$l"
  node tools/benchcmp.mjs "build/bench_L$l.json" "$OUT/L$l.json" | grep -E "SCENE:|d\(jump\)|moved at all" | sed 's/^/  /'
done
