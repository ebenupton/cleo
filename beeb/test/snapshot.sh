#!/bin/sh
# Keep the current build as a reference for test/sweep.sh: the disc, and each
# machine's labels and debug info (the harness finds game.dbg beside the labels).
#   sh test/snapshot.sh DIR
set -e
cd "$(dirname "$0")/.."
[ -n "$1" ] || { echo "usage: sh test/snapshot.sh DIR"; exit 2; }
mkdir -p "$1/modelb" "$1/master"
cp build/cleo.ssd "$1/"
for m in modelb master; do cp build/$m/labels.txt build/$m/game.dbg "$1/$m/"; done
echo "snapshot of build/cleo.ssd in $1"
