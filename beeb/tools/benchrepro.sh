#!/bin/sh
# Demonstrate that the benchmark measures the same scene regardless of code size and
# placement.   ./tools/benchrepro.sh <level> [variant ...]
#
# Builds each variant (tools/perturb.py), benches it (tools/bench.mjs) and compares
# (tools/benchcmp.mjs).  Exits non-zero if any location's scene fingerprint differs
# between builds -- that is the property being asserted, and it is all-or-nothing.
#
# Cycle counts are NOT asserted equal, because they are not equal in reality: a taken
# 6502 branch costs an extra cycle when its target lies on another page.  The one
# variant where equality IS the prediction is codepad256, which moves CODE by a whole
# page and so preserves every branch's page relationship.
set -e
cd "$(dirname "$0")/.."
LV=${1:-1}; shift || true
VARIANTS=${*:-"base codepad1 codepad3 codepad64 codepad200 codepad256 lowpad20 tablepad16 logicpad256"}
OUT=${BENCHREPRO_OUT:-build/repro}
mkdir -p "$OUT"
for v in $VARIANTS; do python3 tools/perturb.py "$v" "$OUT/$v"; done
for v in $VARIANTS; do
  node tools/bench.mjs "$LV" "$OUT/$v/L$LV.json" "$OUT/$v/cleo.ssd" "$OUT/$v/labels.txt" >/dev/null &
done
wait
set +e
ARGS=""; for v in $VARIANTS; do ARGS="$ARGS $OUT/$v/L$LV.json"; done
node tools/benchcmp.mjs $ARGS
