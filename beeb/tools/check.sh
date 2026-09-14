#!/bin/sh
# One combined pass/fail for the current build, run in parallel.  Prints ok or bad.
#   tools/check.sh [frames]
# Levels chosen because they are the ones that have actually caught something: L1's
# respawn timer, L5's snake collision, L6's mirror-heavy redraw.  BUFFER only -- a
# DISPLAY difference is the rupture chain re-phasing to a shorter render, not a bug.
cd "$(dirname "$0")/.."
F=${1:-160}
B="build/base/cleo.ssd build/base/labels.txt build/cleo.ssd build/labels.txt"
T=$(mktemp -d)
for l in 0 1 5; do (node tools/statediff.mjs $B $l $F 2>&1 | grep -q "identical over" || echo bad > $T/s$l) & done
(node tools/pixdiff.mjs $B 6 $F 2>&1 | grep -q "BUFFER identical" || echo bad > $T/p6) &
wait
if ls $T/* >/dev/null 2>&1; then echo bad; else echo ok; fi
rm -rf $T
