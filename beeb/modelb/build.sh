#!/bin/sh
# Cleo, Model B target: the Master's sources (../src) assembled with MODELB=1 and
# MODE1=1, this directory's own files, and one level's assets packed by tools/assets.py.
set -e
cd "$(dirname "$0")"
mkdir -p build
python3 tools/assets.py ${LEVEL:-1 0}    # the level's tiles, map, tables, sprites
# the include order matters: this target's build/ and src/ before the Master's src/
ca65 -g --cpu 6502 -D MODELB=1 -D MODE1=1 -I build -I src -I ../src \
     -o build/main.o src/main.s -l build/main.lst
ld65 -C cleo_b.cfg -o build/unused.bin build/main.o -m build/map.txt -Ln build/labels.txt
ca65 --cpu 6502 -o build/loader.o src/loader.s
ld65 -C loader.cfg -o build/LOADER build/loader.o
printf '*RUN LOADER\r' > build/BOOT
python3 ../tools/mkdfs.py build build/cleob.ssd CLEOB '!BOOT:build/BOOT:0000:FFFF' \
    'LOADER:build/LOADER:1900:1900' \
    'BANK4:build/BANK4:8000:8000' 'BANK5:build/BANK5:8000:8000' \
    'BANK6:build/BANK6:8000:8000' 'BANK7:build/BANK7:8000:8000' 'BAR:build/BAR:0300:0300'
ls -l build/BANK4 build/BANK5 build/BANK6 build/BANK7 build/cleob.ssd
