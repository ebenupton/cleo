# Cleo for the BBC Master 128

A MODE 1 port of the 2004 J2ME platformer *Cleo* (High Energy Magic), built from the
game data and decompiled logic in the two original JARs.

## Running it

Boot `build/cleo.ssd` on a BBC Master 128 (SHIFT+BREAK). Tested in jsbeeb's Master model.

Keys: `Z`/`X` or cursor left/right run, `RETURN` (or `SPACE`, cursor up, `:`) jumps,
`/` (or cursor down) throws the boomerang. There is no pause. Menus use cursor keys and
`RETURN`.

## Building

Needs Python 3 with Pillow + numpy, and cc65 (`ca65`/`ld65`).

    python3 tools/convert.py   # JAR assets -> build/SPR, TIL0, TIL1, ALT, L*, TITLE (+ previews)
    ./build.sh                 # music, assemble, link, build/cleo.ssd

The original JAR contents are expected in `../v500/` (unzipped `CleoV500.jar`).

## How it works

* **Display**: MODE 1, each square game pixel becomes a 2x2 block of MODE 1 pixels
  (2 pixels wide, 2 scanlines tall). Colours are approximated by choosing, per game
  pixel, the four cyan/magenta/yellow/black inks nearest the source colour and laying
  them in a fixed kernel order (`tools/convert.py`), so the pattern is invariant under
  the 2-pixel horizontal scroll step.
* **Double buffering**: the main-RAM screen and the shadow RAM (LYNNE) at &3000-&7FFF
  are alternated with the ACCCON D bit; the CPU draws into the other one via the X bit.
* **Scrolling**: each 20K buffer is a linear ring of 32 character rows. Horizontal
  scrolling is by whole characters (2 game pixels) using the CRTC start address;
  vertical scrolling is smooth (2 scanlines = 1 game pixel) using a vertical rupture:
  the frame is split into CRTC "frames" (status bar / partial top row / playfield /
  partial bottom row / blanking) re-programmed from a VIA timer 1 interrupt chain
  that re-phases the CRTC at every vsync, so a late interrupt cannot leave the
  display out of step.
  The partial top row is displayed from a copy of the bottom lines of the first row.
* **Memory**: engine code and tables live below 12K (&0400-&2FFF). Game logic and
  menus live in HAZEL (8K at &C000, copied there at start). All data is in the four
  sideways RAM banks: 4 = sprites/font/bar, 5+6 = the 467 distinct 8x8 tiles, 7 = the
  current level (map, page tables, objects, altitude data) and the title pack.
* **Loading**: after `*RUN CLEO` the MOS is abandoned; a small WD1770 driver reads the
  data files by sector (multi-sector reads under NMI) using a table generated at build
  time by `tools/mkdfs.py`. It reads whichever drive DFS had current at `*RUN`, so a
  Gotek on drive 1 works after `*DRIVE 1` (or `*DIR :1`); `*RUN :1.CLEO` alone does not
  change the current drive.
* **Logic**: a direct port of `CleoApp.run()` (all 13 object types, the player physics
  and boomerang), fixed at 25 Hz with frame skipping; rendering runs at whatever rate
  the 2 MHz 6502 manages (about 12-25 fps). Sprites that did not change since the
  buffer was last drawn are kept rather than erased and redrawn.
* **Sound**: sound effects and the title tune (converted from `thm.mid` by
  `tools/midi2snd.py`) are played on the SN76489 from the vsync interrupt.

Not ported: the level/hi-score persistence (kept in RAM only), the curtain "wipe"
transitions and the "BONUS LEVEL" banner sprite.

## The Model B

`modelb/` builds the same game for a Model B with 64K of sideways RAM (four banks)
from these sources with `MODELB=1`: `sh modelb/build.sh` writes `modelb/build/cleob.ssd`.
All sixteen levels, loaded from the disc by the game's own driver (8271 or Acorn 1770,
decided at boot), the Master's tiles unfolded, 21 visible rows, the menus in an
overlay.  `modelb/DESIGN.md`.

## Layout

    src/engine.s   display engine, interrupts, loader, sound
    src/logic.s    game logic (HAZEL)
    src/menu.s     menus and screens (HAZEL)
    src/main.s     startup, level flow, file table
    tools/         converters and disc image builder
    build/         generated data, previews, cleo.ssd
