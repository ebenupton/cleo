#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build
python3 tools/assets.py > /dev/null      # the level's tiles, map, sprites and masks
ca65 -g --cpu 6502 -I src -I build -o build/main.o src/main.s -l build/main.lst
ld65 -C cleo_b.cfg -o build/unused.bin build/main.o -m build/map.txt -Ln build/labels.txt
ca65 --cpu 6502 -o build/loader.o src/loader.s
ld65 -C loader.cfg -o build/LOADER build/loader.o
printf '*RUN LOADER\r' > build/BOOT
python3 ../tools/mkdfs.py build build/cleob.ssd CLEOB '!BOOT:build/BOOT:0000:FFFF' \
    'LOADER:build/LOADER:1900:1900' \
    'BANK4:build/BANK4:8000:8000' 'BANK5:build/BANK5:8000:8000' \
    'BANK6:build/BANK6:8000:8000' 'BANK7:build/BANK7:8000:8000'
ls -l build/BANK4 build/BANK5 build/BANK6 build/BANK7 build/cleob.ssd
