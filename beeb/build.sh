#!/bin/sh
# Cleo's build: one disc (build/cleo.ssd) for the BBC Model B (64K of sideways RAM) and the
# Master 128, made by beebgame's driver (beebgame/tools/build.sh) from Cleo's sources (src/)
# and the engine's (beebgame/src).  This script only sets the driver's variables: the game's
# root source and include directory, the disc's title, image and name, the tune (midi2snd.py
# over assets/v500/thm.mid, run once) and the packer (tools/assets.py, run once per machine;
# it runs tools/convert.py over the original game's data, assets/v500, the contents of
# CleoV500.jar).
#   sh build.sh                 # build/cleo.ssd
#   NFLAT=n sh build.sh         # n flat tiles a level (4 by default: eight of the sixteen
#                               # maps use all four)
# The driver's own variables (MASTERONLY, ALLLEVELS, SKIP_ASSETS, ...) pass through the
# environment.  A build without ALLLEVELS also copies the disc to the repository's root
# (../cleo.ssd), the copy kept in git.
set -e
cd "$(dirname "$0")"
[ -f beebgame/tools/build.sh ] || { echo "beebgame is missing: git submodule update --init"; exit 1; }
export GAME_MAIN=src/main.s GAME_SRC=src DISC_TITLE=CLEO DISC_OUT=build/cleo.ssd GAME_NAME=Cleo
export GAME_MUSIC="python3 beebgame/tools/midi2snd.py assets/v500/thm.mid build/MUSIC"
export GAME_ASSETS="python3 tools/assets.py"
sh beebgame/tools/build.sh
[ -n "$ALLLEVELS" ] || cp build/cleo.ssd ../cleo.ssd
