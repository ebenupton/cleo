#!/bin/sh
# Find the first accumulated snapshot that fails a given check.
#   tools/bisect.sh all   -        <frames>     every check in tools/check.sh, in parallel
#   tools/bisect.sh state <level> <frames>     object state
#   tools/bisect.sh pix   <level> <frames>     drawn pixels (BUFFER only; DISPLAY
#                                              differences are rupture-chain re-phasing)
#   tools/bisect.sh dmg   <level> <frames>     object state with knockback reachable
# Snapshot N is the tree with the first N accepted proposals applied, so the answer is
# entry N of build/applied.json.  (No `timeout`: macOS has none, and the harness enforces
# its own cycle budget -- an earlier version of this script used it and every probe came
# back "bad", which makes a bisection say the first proposal is always the culprit.)
cd "$(dirname "$0")/.."
K=${1:-state}; L=${2:-0}; F=${3:-150}
N=$(ls build/accum | tail -1 | sed 's/^0*//')
B="build/base/cleo.ssd build/base/labels.txt build/cleo.ssd build/labels.txt"
probe() {
  if [ "$1" -eq 0 ]; then git checkout -- src/; else cp build/accum/$(printf %03d $1)/*.s src/; fi
  ./build.sh >/dev/null 2>&1 || { echo noasm; return; }
  case $K in
    state) node tools/statediff.mjs $B $L $F 2>&1 | grep -q "identical over" && echo ok || echo bad ;;
    dmg)   HARNESS_ALLOW_DAMAGE=1 node tools/statediff.mjs $B $L $F 2>&1 \
             | grep -q "identical over" && echo ok || echo bad ;;
    pix)   node tools/pixdiff.mjs $B $L $F 2>&1 | grep -q "BUFFER identical" && echo ok || echo bad ;;
    all)   tools/check.sh $F ;;
  esac
}
lo=0; hi=$N
echo "snapshot $hi ($K L$L): $(probe $hi)"
while [ $((hi - lo)) -gt 1 ]; do
  mid=$(( (lo + hi) / 2 )); r=$(probe $mid); echo "  snapshot $mid: $r"
  if [ "$r" = ok ]; then lo=$mid; else hi=$mid; fi
done
echo "first bad snapshot: $hi"
python3 -c "
import json,sys
d=json.load(open('build/applied.json'))
print('culprit:', d['accepted'][$hi-1])"
