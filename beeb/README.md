# Cleo for the BBC Micro

A MODE 1 port of the 2004 J2ME platformer *Cleo* (High Energy Magic), built from the
game data and decompiled logic in the two original JARs. One disc runs on a BBC
Master 128 and on a Model B with 64K of sideways RAM.

## Running it

Boot `build/cleo.ssd` (SHIFT+BREAK).

- **Master 128**: as it comes.
- **Model B**: four 16K banks of sideways RAM in any sockets, written through ROMSEL
  or by a Watford or Solidisk write-select board. The loader finds them and patches
  the game for the ones it finds. The disc is read by an 8271 or an Acorn 1770,
  whichever DFS is fitted.

Keys: `Z`/`X` or cursor left/right run, `RETURN` (or `SPACE`, cursor up, `:`) jumps,
`/` (or cursor down) throws the boomerang. There is no pause. Menus use cursor keys and
`RETURN`.

## Building

Needs Python 3 with Pillow and numpy, and cc65 (`ca65`/`ld65`). The original JAR
contents are expected in `../v500/` (unzipped `CleoV500.jar`).

    sh build.sh                 # the tune, the assets, both machines, one disc: build/cleo.ssd
    TILEMIRROR=1 sh build.sh    # the same with the tile blitter's mirrored tiles (unused)

## Testing

The tests drive jsbeeb (found by `test/harness.mjs`) and compare a build with a
reference, frame by frame:

    sh test/snapshot.sh REF     # keep the current build as a reference
    ...change something, sh build.sh...
    sh test/sweep.sh REF        # every level on both machines, the menus, the loads

`test/bench.mjs` and `test/bwork2.mjs` measure frame cost on the Master and the
Model B respectively, and `test/hbeebem/` runs the Model B in BeebEm, lock-stepped
with jsbeeb.

## How it works

`docs/DESIGN.md` has the detail.

- **One structure, two machines.** The sources are assembled twice: `BHW=1` for the
  Model B's hardware, `BHW=0` for the Master's. Both keep their code in the four
  sideways banks, beside the data each inner loop reads:
  - bank 4: the sprite blitter and most sprites;
  - bank 5: more sprites, the level's map and the tile gather;
  - bank 6: the tile blitter and the level's tiles;
  - bank 7: the game logic and the level's tables.

  Bank 7 calls into the others through fixed thunks in low RAM.
- **Display.** MODE 1, each square game pixel a 2x2 block of MODE 1 pixels, coloured
  by a cyan/magenta/yellow/black dither per game pixel (`tools/convert.py`).
  Horizontal scrolling is by whole characters through the CRTC start address.
  Vertical scrolling is smooth, by a rupture: the frame is several CRTC frames
  (status bar, partial top row, playfield, partial bottom row, blanking), re-
  programmed from a chain of VIA timer interrupts and re-phased at every vsync.
  - **Master:** double-buffered in main and shadow RAM, each buffer a
    hardware-wrapped ring of 32 character rows.
  - **Model B:** two software rings of 23 rows in its 32K, each with a mirror of
    the row that straddles the ring's end.
- **Loading.** After boot the MOS is abandoned. The game's own disc driver reads by
  sector under NMI, from a sector table built with the disc (`tools/mkdfs.py`), and a
  load-time program gathers each level into the banks. Everything a level needs is
  packed per level (`tools/assets.py`): its tiles, its sprites and where they go, its
  map and tables.
- **Logic.** A direct port of `CleoApp.run()`: all 13 object types, the player's
  physics and the boomerang. It runs fixed at 25 Hz with frame skipping, and drawing
  runs as fast as the 2 MHz 6502 allows. Sprites that have not changed since a buffer
  was last drawn are kept, not erased and redrawn.
- **Sound.** The sound effects and the title tune (from `thm.mid`,
  `tools/midi2snd.py`) play on the SN76489 from the vsync interrupt.

Not ported: the level/hi-score persistence (kept in RAM only), the curtain "wipe"
transitions and the "BONUS LEVEL" banner sprite.

## Layout

    build.sh           the build: both machines, one disc
    src/               the 6502 sources (main.s includes the rest)
    cfg/               the linker configurations
    tools/             the asset pipeline and the disc image builder
    test/              the jsbeeb harness and the checks
    docs/              DESIGN.md; history/ has the plans and records of earlier work
    build/             generated: the shared assets, build/modelb/, build/master/, cleo.ssd
