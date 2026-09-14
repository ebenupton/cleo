#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build
printf '*RUN CLEO\r' > build/BOOT
python3 tools/midi2snd.py
DATA="SPR:build/SPR:8000 TILESO:build/TILESO:8000 TILESI:build/TILESI:8000 SPRAND:build/SPRAND:8000 BOX:build/BOX:B000 MUSIC:build/MUSIC:B800 ALT:build/ALT:AD00 TITLE:build/TITLE:8000"
for l in 0 1 2 3 4 5 6 7; do for s in A B; do DATA="$DATA L$l$s:build/L$l$s:8400"; done; done
# LOGIC goes last: it is written by the same link that reads files.inc, so only its
# own length may move, and the file table takes that from the linker, not from here
[ -f build/LOGIC ] || : > build/LOGIC
DATA="$DATA LOGIC:build/LOGIC:8900"
python3 tools/mkdfs.py table build/files.inc '!BOOT:build/BOOT' $DATA
ca65 -g --cpu 65C02 ${MODE1:+-D MODE1=1} -I src -I build -o build/main.o src/main.s -l build/main.lst
ld65 -C cleo.cfg -o build/CLEO build/main.o -m build/map.txt -Ln build/labels.txt --dbgfile build/cleo.dbg
python3 tools/mkdfs.py build build/cleo.ssd CLEO '!BOOT:build/BOOT:0000:FFFF' $DATA 'CLEO:build/CLEO:0E00:0E00'
ls -l build/CLEO build/cleo.ssd
