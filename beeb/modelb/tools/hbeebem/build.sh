#!/bin/sh
# Build a headless BeebEm from its Windows source for lock-step tests against jsbeeb
# (docs/MODEL_B.md, "BeebEm").  The emulation core -- 6502, video, VIAs, memory, discs --
# has no Win32 in it; this supplies a shim windows.h, a stub BeebWin, stubs for the
# peripherals it links against, and a harness (main.cpp) that boots a disc the way
# bopen.mjs does and prints the game's state at every frame_top, with a picture, the
# display RAM, the game's section table and a CRTC log at chosen frames.
#   tools/hbeebem/build.sh [outdir]          -> outdir/hbeebem, outdir/userdata
# Needs clang++ and git.  The ROMs (OS 1.20, BASIC 2, DNFS) come from the BeebEm
# release zip's UserData/BeebFile/BBC; put that zip's UserData at $BEEBEM_USERDATA or
# let the script fetch the 4.19 zip.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/build}"
BEEBEM_COMMIT=a982ba6a74af09e801c296b29d514dbd4da09b94   # stardot/beebem-windows, Sept 2026
mkdir -p "$OUT"
[ -d "$OUT/beebem-windows" ] || git clone -q https://github.com/stardot/beebem-windows.git "$OUT/beebem-windows"
(cd "$OUT/beebem-windows" && git checkout -q $BEEBEM_COMMIT)
SRC="$OUT/src"; rm -rf "$SRC"; mkdir -p "$SRC"
cp "$OUT"/beebem-windows/Src/*.cpp "$OUT"/beebem-windows/Src/*.h "$SRC/"
cp -r "$OUT"/beebem-windows/Src/zlib "$OUT"/beebem-windows/Src/ARMulator "$SRC/"
rm "$SRC/BeebWin.h" "$SRC/Main.h" "$SRC/FileUtils.cpp"
cp "$HERE"/windows.h "$HERE"/BeebWin.h "$HERE"/Main.h "$HERE"/FileUtils.cpp "$HERE"/stubs.cpp "$HERE"/main.cpp "$SRC/"
patch -s "$SRC/Video.cpp" < "$HERE/Video.cpp.patch"   # the CRTC restart / register-write log
OBJ="$OUT/obj"; mkdir -p "$OBJ"
for f in 6502core Video SysVia UserVia Via Beebmem Disc8271 Disc1770 IC32Latch Model AtoDConv Bcd DiscInfo StringUtils FileUtils UefState RomConfigFile PALRom stubs main; do
    clang++ -std=c++17 -O2 -w -c -I"$SRC" "$SRC/$f.cpp" -o "$OBJ/$f.o"
done
for z in "$SRC"/zlib/*.c; do clang -w -c -include unistd.h -I"$SRC" -I"$SRC/zlib" "$z" -o "$OBJ/z_$(basename "$z" .c).o"; done
clang++ -O2 "$OBJ"/*.o -o "$OUT/hbeebem"
# the user data: Roms.cfg (backslashes to slashes) and the three ROMs
UD="$OUT/userdata"; mkdir -p "$UD/BeebFile/BBC"
if [ -z "$BEEBEM_USERDATA" ]; then
    [ -f "$OUT/BeebEm419.zip" ] || curl -sL -o "$OUT/BeebEm419.zip" https://github.com/stardot/beebem-windows/releases/download/4.19/BeebEm419.zip
    (cd "$OUT" && unzip -q -o BeebEm419.zip 'BeebEm/UserData/Roms.cfg' 'BeebEm/UserData/BeebFile/BBC/OS12.rom' 'BeebEm/UserData/BeebFile/BBC/BASIC2.rom' 'BeebEm/UserData/BeebFile/BBC/DNFS.rom')
    BEEBEM_USERDATA="$OUT/BeebEm/UserData"
fi
cp "$BEEBEM_USERDATA"/BeebFile/BBC/OS12.rom "$BEEBEM_USERDATA"/BeebFile/BBC/BASIC2.rom "$BEEBEM_USERDATA"/BeebFile/BBC/DNFS.rom "$UD/BeebFile/BBC/"
sed 's#\\#/#g' "$BEEBEM_USERDATA/Roms.cfg" > "$UD/Roms.cfg"
echo "built $OUT/hbeebem; run from modelb/:"
echo "  $OUT/hbeebem --userdata $UD --disc build/cleob.ssd --labels build/labels.txt --frames 240 --seed 3 --level 1 --shotevery 20 --out /tmp/hb"
echo "  node tools/bdump.mjs 240 3 1 -1 /tmp/jb 20 > /tmp/jb.txt; python3 tools/hbeebem/cmpdump.py /tmp/hb.txt /tmp/jb.txt"
echo "  python3 tools/hbeebem/cmpshots.py /tmp/hb_f20.ppm /tmp/jb_f20.png"
