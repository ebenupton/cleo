#!/bin/sh
# Keep the current build as a reference for test/sweep.sh and test/perfcmp.sh: the
# disc, and each machine's labels, debug info and constants (labels.txt, game.dbg,
# defs_ld.inc: the harness finds the last two beside the labels).  A reference must
# carry the labels of its own disc -- every check opens each build with its own.
#   sh test/snapshot.sh DIR
# Output: DIR/cleo.ssd, DIR/modelb/..., DIR/master/...; exit 2 without a DIR.
set -e
cd "$(dirname "$0")/.."
[ -n "$1" ] || { echo "usage: sh test/snapshot.sh DIR"; exit 2; }
mkdir -p "$1/modelb" "$1/master"
cp build/cleo.ssd "$1/"
for m in modelb master; do cp build/$m/labels.txt build/$m/game.dbg build/$m/defs_ld.inc "$1/$m/"; done
echo "snapshot of build/cleo.ssd in $1"
