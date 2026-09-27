#!/bin/sh
# Cleo: one disc (build/cleo.ssd) for the BBC Model B (64K of sideways RAM) and the
# Master 128, built by beebgame's driver (beebgame/tools/build.sh) from Cleo's sources
# (src/) and the engine's (beebgame/src).  The tune, then per machine the assets
# (tools/assets.py, which runs tools/convert.py over the original game's data).
#   sh build.sh                 # build/cleo.ssd
#   TILEMIRROR=1 sh build.sh    # the tile blitter's mirrored tiles too (no level needs them)
set -e
cd "$(dirname "$0")"
[ -f beebgame/tools/build.sh ] || { echo "beebgame is missing: git submodule update --init"; exit 1; }
export GAME_MAIN=src/main.s GAME_SRC=src DISC_TITLE=CLEO DISC_OUT=build/cleo.ssd GAME_NAME=Cleo
export GAME_MUSIC="python3 beebgame/tools/midi2snd.py ../v500/thm.mid build/MUSIC"
export GAME_ASSETS="python3 tools/assets.py"
exec sh beebgame/tools/build.sh
