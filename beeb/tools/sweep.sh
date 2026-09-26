#!/bin/sh
# The wide behavioural sweep, both targets, against build/base and modelb/build/base:
# every level, several key seeds, 600 frames, damage reachable, every sideways RAM
# board and a spread of socket layouts, both disc controllers.  Eight at a time.
# Prints each failing run, then "SWEEP ok" or "SWEEP bad: N".
#   tools/sweep.sh [frames]
cd "$(dirname "$0")/.."
F=${1:-600}
B="build/base/cleo.ssd build/base/labels.txt build/cleo.ssd build/labels.txt"
BB="build/base/cleob.ssd build/base/labels.txt build/cleob.ssd build/labels.txt"
{
for l in 0 1 2 3 4 5 6 7; do
  echo "M state L$l|node tools/statediff.mjs $B $l $F|identical over"
  echo "M dmg L$l|HARNESS_ALLOW_DAMAGE=1 node tools/statediff.mjs $B $l $F|identical over"
  echo "M pix L$l|node tools/pixdiff.mjs $B $l $F|BUFFER identical"
done
for l in $(seq 0 15); do for s in 1 2 3; do
  echo "B lockstep L$l s$s|cd modelb && node tools/bdiff.mjs $F $s $l|^OK"; done
  echo "B pix L$l|cd modelb && node tools/bpixdiff.mjs $BB $F 2 $l|identical over"
done
for l in 0 5 10 15; do
  echo "B watford L$l|cd modelb && BBOARD=watford node tools/bdiff.mjs 300 4 $l|^OK"
  echo "B solidisk L$l|cd modelb && BBOARD=solidisk node tools/bdiff.mjs 300 4 $l|^OK"
done
echo "B sockets 4,7,9,13|cd modelb && BSWRAM=4,7,9,13 node tools/bdiff.mjs 300 5 2|^OK"
echo "B sockets 1,6,12,15 watford|cd modelb && BSWRAM=1,6,12,15 BBOARD=watford node tools/bdiff.mjs 300 5 12|^OK"
echo "B sockets 2,3,8,11 solidisk|cd modelb && BSWRAM=2,3,8,11 BBOARD=solidisk node tools/bdiff.mjs 300 5 6|^OK"
echo "B 1770 L8|cd modelb && BMODEL=B1770 node tools/bdiff.mjs 300 4 8|^OK"
echo "B 1770 L3|cd modelb && BMODEL=B1770 node tools/bdiff.mjs 300 6 3|^OK"
echo "M menus|node tools/menusync.mjs master $B|identical on"
echo "B menus|node tools/menusync.mjs modelb modelb/$(echo $BB | sed 's# # modelb/#g')|identical on"
} > /tmp/sweep.jobs
T=$(mktemp -d)
i=0
while IFS='|' read -r name cmd want; do
  i=$((i+1))
  ( sh -c "$cmd" > $T/out$i 2>&1; grep -q "$want" $T/out$i || { echo "FAIL $name: $(grep -vE '^(Loading|Running)' $T/out$i | tail -1)" > $T/fail$i; } ) &
  [ $((i % 8)) = 0 ] && wait
done < /tmp/sweep.jobs
wait
cat $T/fail* 2>/dev/null
n=$(ls $T/fail* 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 0 ] && echo "SWEEP ok ($i runs)" || echo "SWEEP bad: $n of $i runs"
rm -rf $T
