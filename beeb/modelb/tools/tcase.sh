#!/bin/sh
# tcase.sh Y X F [out.png] -- build with a fixed window and shoot it
set -e
cd "$(dirname "$0")/.."
ca65 -g --cpu 6502 -DTESTY=$1 -DTESTX=$2 -DTESTF=$3 -I src -I build -o build/main.o src/main.s
ld65 -C cleo_b.cfg -o build/unused.bin build/main.o -m build/map.txt -Ln build/labels.txt 2>/dev/null
python3 ../tools/mkdfs.py build build/cleob.ssd CLEOB '!BOOT:build/BOOT:0000:FFFF' \
    'LOADER:build/LOADER:1900:1900' 'BANK4:build/BANK4:8000:8000' 'BANK5:build/BANK5:8000:8000' \
    'BANK6:build/BANK6:8000:8000' 'BANK7:build/BANK7:8000:8000' >/dev/null
node tools/bshot.mjs 16000000 ${4:-build/shot.png} 2>&1 | grep -v "Loading\|Running"
