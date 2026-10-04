#!/bin/sh
# The whole behavioural check, the current build (build/) against a reference (REF: a
# directory from test/snapshot.sh -- its cleo.ssd with master/ and modelb/ labels.txt,
# game.dbg and defs_ld.inc of THAT disc; every check opens each build with its own
# labels), both machines, in parallel; prints only what fails, and exits 1 if anything
# does.  The current build is snapshotted first, so a rebuild during the run is safe.
#   sh test/sweep.sh REF [jobs=7]
# The 89 checks:
#   each of the 16 levels, the Master: the displayable window and the scene, 400 frames
#     of the fixed key pattern, and 200 after the level ends and loads again (RELOAD=1)
#     (wincmp.mjs); the Model B: both buffers' windows and the bar, 300 frames
#     (bwincmp.mjs); and each level on both machines with seeded random keys, throws
#     and fire included (SEED=7, 500 frames) -- 80 checks
#   the Model B on Watford and Solidisk boards (BBOARD), level 8, 300 frames -- 2
#   the menus, frame-synchronised (menusync.mjs), on both machines -- 2
#   the frame period through a load from the menu (loadsync2.mjs), the new build alone:
#     Master, 8271, 1770 (BMODEL=B1770) -- 3
#   on Watford and Solidisk boards, a whole session's stores into sideways RAM, each to
#     the bank paged (boardcheck.mjs), the new build alone -- 2
# A check passes on its last result line: "window identical; scene identical",
# "windows identical", "menus: identical", " 0 irregular" or "every store to the bank
# paged"; anything else (an error, no result) is printed with the check's name.  About
# 4-5 minutes with 7 jobs (measured 4 Oct 2026).
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
        echo "SEED=7 node test/wincmp.mjs $REF/cleo.ssd $REF/master/labels.txt $NEW/cleo.ssd $NEW/master/labels.txt $l 500 > $OUT/master_keys_L$l.txt"
        echo "SEED=7 node test/bwincmp.mjs $REF/cleo.ssd $REF/modelb/labels.txt $NEW/cleo.ssd $NEW/modelb/labels.txt $l 500 > $OUT/modelb_keys_L$l.txt"
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
