#!/bin/sh
# The Model B target: plain 6502, no shadow screen, no status bar.  The data files
# and their sector layout are the ones build.sh made, so run that first.
set -e
cd "$(dirname "$0")"
DATA="SPR:build/SPR:8000 TILESO:build/TILESO:8000 TILESI:build/TILESI:8000 SPRAND:build/SPRAND:8000 BOX:build/BOX:B000 MUSIC:build/MUSIC:B800 ALT:build/ALT:AD00 TITLE:build/TITLE:8000"
for l in 0 1 2 3 4 5 6 7; do for s in A B; do DATA="$DATA L$l$s:build/L$l$s:8400"; done; done
[ -f build/LOGICB ] || : > build/LOGICB
DATA="$DATA LOGIC:build/LOGICB:8900"
ca65 -g -DMODELB --cpu 6502 -I src -I build -o build/mainb.o src/main.s -l build/mainb.lst
ld65 -C cleo_b.cfg -o build/CLEOB build/mainb.o -m build/mapb.txt -Ln build/labelsb.txt
python3 tools/mkdfs.py build build/cleob.ssd CLEO '!BOOT:build/BOOT:0000:FFFF' $DATA 'CLEO:build/CLEOB:2000:2000'   # loads clear of the DFS workspace; reloc.s moves it to $0E00
ls -l build/CLEOB build/LOGICB build/cleob.ssd
