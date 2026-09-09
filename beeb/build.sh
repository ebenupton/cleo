#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build
printf '*RUN CLEO\r' > build/BOOT
python3 tools/midi2snd.py
python3 tools/embed_music.py
DATA="SPR:build/SPR:8000 SPRAND:build/SPRAND:8000 TIL0:build/TIL0:8000 TIL1:build/TIL1:8000 ALT:build/ALT:AB00 TITLE:build/TITLE:8000"
for l in 0 1 2 3 4 5 6 7; do for s in A B; do DATA="$DATA L$l$s:build/L$l$s:8000"; done; done
python3 tools/mkdfs.py table build/files.inc '!BOOT:build/BOOT' $DATA
ca65 -g --cpu 65C02 -I src -I build -o build/main.o src/main.s -l build/main.lst
ld65 -C cleo.cfg -o build/CLEO build/main.o -m build/map.txt -Ln build/labels.txt --dbgfile build/cleo.dbg
python3 tools/mkdfs.py build build/cleo.ssd CLEO '!BOOT:build/BOOT:0000:FFFF' $DATA 'CLEO:build/CLEO:0E00:0E00'
ls -l build/CLEO build/cleo.ssd
