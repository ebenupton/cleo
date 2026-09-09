# Cleo for the BBC Master 128

A MODE 2 port of the 2004 J2ME platformer *Cleo* (High Energy Magic), built from the
game data and decompiled logic in the two original JARs.

## Running it

Boot `build/cleo.ssd` on a BBC Master 128 (SHIFT+BREAK). Tested in jsbeeb's Master model.

Keys: `Z`/`X` or cursor left/right run, `RETURN` (or `SPACE`, cursor up, `:`) jumps,
`/` (or cursor down) throws the boomerang, `ESCAPE` pauses. Menus use cursor keys and
`RETURN`.

## Building

Needs Python 3 with Pillow + numpy, and cc65 (`ca65`/`ld65`).

    python3 tools/convert.py   # JAR assets -> build/SPR, TIL0, TIL1, ALT, L*, TITLE (+ previews)
    ./build.sh                 # music, assemble, link, build/cleo.ssd

The original JAR contents are expected in `../v500/` (unzipped `CleoV500.jar`).

## How it works

* **Display**: MODE 2, each square game pixel becomes two vertically adjacent MODE 2
  pixels (1 MODE 2 pixel wide, 2 scanlines tall). Colours are approximated with a 2x4
  ordered dither over the 8-colour palette (`tools/convert.py`), sized so it is
  invariant under the 2-pixel horizontal scroll step.
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
  time by `tools/mkdfs.py`.
* **Logic**: a direct port of `CleoApp.run()` (all 13 object types, the player physics
  and boomerang), fixed at 25 Hz with frame skipping; rendering runs at whatever rate
  the 2 MHz 6502 manages (about 12-25 fps). Sprites that did not change since the
  buffer was last drawn are kept rather than erased and redrawn.
* **Sound**: sound effects and the title tune (converted from `thm.mid` by
  `tools/midi2snd.py`) are played on the SN76489 from the vsync interrupt.

Not ported: the level/hi-score persistence (kept in RAM only), the curtain "wipe"
transitions and the "BONUS LEVEL" banner sprite.

## Layout

    src/engine.s   display engine, interrupts, loader, sound
    src/logic.s    game logic (HAZEL)
    src/menu.s     menus and screens (HAZEL)
    src/main.s     startup, level flow, file table
    tools/         converters and disc image builder
    build/         generated data, previews, cleo.ssd
