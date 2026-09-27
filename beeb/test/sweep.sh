#!/bin/sh
# The whole check, the current build against a reference (test/snapshot.sh), both
# machines, in parallel; prints only what fails, and exits 1 if anything does.
#   sh test/sweep.sh REF [jobs=7]
#   each level, the Master: the visible window and the scene, 400 frames, and 200 after
#     the level ends and loads again (wincmp.mjs); the Model B: both buffers' windows
#     and the bar, 300 frames (bwincmp.mjs), and on Watford and Solidisk boards
#   the menus, frame-synchronised (menusync.mjs), on both machines
#   the frame period through a load from the menu (loadsync2.mjs): Master, 8271, 1770
#   on Watford and Solidisk boards, a whole session's stores into sideways RAM, each
#     to the bank paged (boardcheck.mjs)
set -e
cd "$(dirname "$0")/.."
REF=$1; JOBS=${2:-7}
[ -f "$REF/cleo.ssd" ] || { echo "usage: sh test/sweep.sh REF [jobs]  (REF from test/snapshot.sh)"; exit 2; }
NEW=$(mktemp -d); OUT=$(mktemp -d)
sh test/snapshot.sh "$NEW" >/dev/null
jobs() {
    for l in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        echo "node test/wincmp.mjs $REF/cleo.ssd $REF/master/labels.txt $NEW/cleo.ssd $NEW/master/labels.txt $l 400 > $OUT/master_L$l.txt"
        echo "RELOAD=1 node test/wincmp.mjs $REF/cleo.ssd $REF/master/labels.txt $NEW/cleo.ssd $NEW/master/labels.txt $l 200 > $OUT/master_reload_L$l.txt"
        echo "node test/bwincmp.mjs $REF/cleo.ssd $REF/modelb/labels.txt $NEW/cleo.ssd $NEW/modelb/labels.txt $l 300 > $OUT/modelb_L$l.txt"
    done
    for b in watford solidisk; do
        echo "BBOARD=$b node test/bwincmp.mjs $REF/cleo.ssd $REF/modelb/labels.txt $NEW/cleo.ssd $NEW/modelb/labels.txt 8 300 > $OUT/modelb_$b.txt"
    done
    echo "node test/menusync.mjs master $REF/cleo.ssd $REF/master/labels.txt $NEW/cleo.ssd $NEW/master/labels.txt > $OUT/menus_master.txt"
    echo "node test/menusync.mjs modelb $REF/cleo.ssd $REF/modelb/labels.txt $NEW/cleo.ssd $NEW/modelb/labels.txt > $OUT/menus_modelb.txt"
    echo "node test/loadsync2.mjs master $NEW/cleo.ssd $NEW/master/labels.txt > $OUT/load_master.txt"
    echo "node test/loadsync2.mjs modelb $NEW/cleo.ssd $NEW/modelb/labels.txt > $OUT/load_8271.txt"
    echo "BMODEL=B1770 node test/loadsync2.mjs modelb $NEW/cleo.ssd $NEW/modelb/labels.txt > $OUT/load_1770.txt"
    for b in watford solidisk; do
        echo "node test/boardcheck.mjs $b $NEW/cleo.ssd $NEW/modelb/labels.txt > $OUT/boardstores_$b.txt"
    done
}
jobs | tr '\n' '\0' | xargs -0 -P "$JOBS" -n 1 sh -c 'eval "$0" 2>/dev/null || true'
fail=0; n=0
for f in "$OUT"/*.txt; do
    n=$((n + 1))
    r=$(grep -hE '^L[0-9]|^B L|menus:|frames from|^board |Error' "$f" | tail -1)
    case "$r" in
        *"window identical; scene identical"*|*"windows identical"*|*"menus: identical"*|*" 0 irregular"*|*"every store to the bank paged"*) ;;
        *) echo "$(basename "$f" .txt): ${r:-no result}"; fail=1;;
    esac
done
[ $fail = 0 ] && echo "sweep: all $n checks pass" || echo "sweep: FAILURES above ($n checks)"
rm -rf "$NEW" "$OUT"
exit $fail
