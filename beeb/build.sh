#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build
printf '*RUN CLEO\r' > build/BOOT
python3 tools/midi2snd.py
DATA="SPR:build/SPR:8000 TILESO0:build/TILESO0:3000 TILESI0:build/TILESI0:3000 SPRAND:build/SPRAND:8000 BOX:build/BOX:B000 MUSIC:build/MUSIC:B800 ALT:build/ALT:AD00 TITLE:build/TITLE:8000"
for l in 0 1 2 3 4 5 6 7; do for s in A B; do DATA="$DATA L$l$s:build/L$l$s:8400"; done; done
# LOGIC goes last: it is written by the same link that reads files.inc, so only its
# own length may move, and the file table takes that from the linker, not from here
[ -f build/LOGIC ] || : > build/LOGIC
# TABLES is written by the link too, but at a fixed size (fill = yes)
[ -s build/TABLES ] || head -c 2304 /dev/zero > build/TABLES
DATA="$DATA TABLES:build/TABLES:0400 TILESO1:build/TILESO1:3000 TILESI1:build/TILESI1:3000 LOGIC:build/LOGIC:8900"
python3 tools/mkdfs.py table build/files.inc '!BOOT:build/BOOT' $DATA
ca65 -g --cpu 65C02 ${DBGHIT:+-D DBGHIT=1} ${DBGTILE:+-D DBGTILE=1} ${DBGSND:+-D DBGSND=1} ${PARALLAX:+-D PARALLAX=1} ${VISROWSDEF:+-D VISROWSDEF=$VISROWSDEF} -I src -I build -o build/main.o src/main.s -l build/main.lst
ld65 -C cleo.cfg -o build/CLEO build/main.o -m build/map.txt -Ln build/labels.txt --dbgfile build/cleo.dbg
python3 tools/mkdfs.py build build/cleo.ssd CLEO '!BOOT:build/BOOT:0000:FFFF' $DATA 'CLEO:build/CLEO:0E00:0E00'
ls -l build/CLEO build/cleo.ssd
