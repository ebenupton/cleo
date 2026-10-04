#!/bin/sh
# Frame cost of the current build against a snapshot (test/snapshot.sh REF), both
# machines, each level in the list: the Master's bench (bench.mjs, 15 locations a
# level, jump and run scripts: the median of the per-location deltas, new - REF, over
# the scene-matched locations, from benchcmp.mjs) and the Model B's frame-matched work
# (bwork2.mjs, 300 frames of seed 1 on each build: the median of the per-frame
# deltas).  Negative is faster.  All the runs go in parallel; each build is opened with
# its own labels (REF/<machine>/labels.txt, build/<machine>/labels.txt).
#   sh test/perfcmp.sh REF [levels="0 2 4 6"]
# Output: a line a level, "L<n>  Master jump <d> run <d>   Model B <d>".
set -e
cd "$(dirname "$0")/.."
REF=$1; LV=${2:-"0 2 4 6"}
T=$(mktemp -d)
for l in $LV; do
    node test/bench.mjs $l $T/mo$l.json $REF/cleo.ssd $REF/master/labels.txt >/dev/null 2>&1 &
    node test/bench.mjs $l $T/mn$l.json build/cleo.ssd build/master/labels.txt >/dev/null 2>&1 &
    BDISC=$REF/cleo.ssd BLABELS=$REF/modelb/labels.txt BDUMP=$T/bo$l.json node test/bwork2.mjs 300 1 $l >/dev/null 2>&1 &
    BDUMP=$T/bn$l.json node test/bwork2.mjs 300 1 $l >/dev/null 2>&1 &
done
wait
for l in $LV; do
    printf "L%s  Master " $l
    node test/benchcmp.mjs $T/mo$l.json $T/mn$l.json 2>&1 | grep "d(jump) median" | head -1 | sed 's/.*: *d(jump) median \([-0-9]*\).*d(run) median \([-0-9]*\).*/jump \1 run \2/' | tr '\n' ' '
    node -e '
const fs=require("fs");const [o,n]=process.argv.slice(1).map(f=>JSON.parse(fs.readFileSync(f)));
const d=[];for(let i=0;i<Math.min(o.length,n.length);i++)d.push(n[i]-o[i]);d.sort((a,b)=>a-b);
console.log(`  Model B ${d[d.length>>1]}`)' $T/bo$l.json $T/bn$l.json
done
rm -rf $T
