#!/bin/sh
# Every behavioural check (titles and menus frame-synchronised: tools/menusync.mjs), both targets, against build/base (Master) and
# modelb/build/base (Model B), in parallel.  Prints one line per failing check, then
# "GATE ok" or "GATE bad".
#   tools/gate.sh [frames]
cd "$(dirname "$0")/.."
F=${1:-200}
T=$(mktemp -d)
B="build/base/cleo.ssd build/base/labels.txt build/cleo.ssd build/labels.txt"
for l in 0 1 5; do (node tools/statediff.mjs $B $l $F 2>&1 | grep -q "identical over" || echo "M state L$l" > $T/ms$l) & done
for l in 3 6; do (node tools/pixdiff.mjs $B $l $F 2>&1 | grep -q "BUFFER identical" || echo "M pix L$l" > $T/mp$l) & done
(HARNESS_ALLOW_DAMAGE=1 node tools/statediff.mjs $B 0 $F 2>&1 | grep -q "identical over" || echo "M dmg L0" > $T/md) &
(node tools/menusync.mjs master build/base/cleo.ssd build/base/labels.txt build/cleo.ssd build/labels.txt 2>&1 | grep -q "identical on" || echo "M menus" > $T/mt) &
(node tools/menusync.mjs modelb modelb/build/base/cleob.ssd modelb/build/base/labels.txt modelb/build/cleob.ssd modelb/build/labels.txt 2>&1 | grep -q "identical on" || echo "B menus" > $T/bt) &
( cd modelb
  for l in 0 5 12; do (node tools/bdiff.mjs $F 1 $l 2>&1 | grep -q "^OK" || echo "B lockstep L$l" > $T/bl$l) & done
  for l in 0 6; do (node tools/bpixdiff.mjs build/base/cleob.ssd build/base/labels.txt build/cleob.ssd build/labels.txt $F 1 $l 2>&1 | grep -q "identical over" || echo "B pix L$l" > $T/bp$l) & done
  wait )
wait
if ls $T/* >/dev/null 2>&1; then cat $T/*; echo "GATE bad"; else echo "GATE ok"; fi
rm -rf $T
