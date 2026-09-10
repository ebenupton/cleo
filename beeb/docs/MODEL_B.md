# Model B target (64K sideways RAM)

A second build of the same game for a BBC Model B fitted with 64K of sideways RAM
(four banks) and a WD1770 disc controller.  One disc boots on both machines; the
loader detects which one it is on and loads the matching binaries.

## What the Model B does not have

| Master resource | Size | Model B substitute |
|---|---|---|
| Shadow screen (ACCCON) | 20K | two 10K carousels inside the one 20K screen |
| HAZEL ($C000-$DFFF) | 8054 bytes of code | a sideways bank, reached by trampoline |
| ANDY ($8000, ROMSEL bit 7) | 4096 bytes of sprite data | space freed in bank 7 |
| 65C02 | 393 instruction sites | 6502 expansions, about 800 bytes larger |

Everything else is the same: four 16K sideways banks, 20K of screen at $3000, and
main RAM from $0206 to $2FFF.

## Screen

The window is 64 chars by 20 rows: 128 by 160 pixels, centred, no status bar.

MODE 2 stores 8 bytes per char cell, so one buffer is 64 x 20 x 8 = 10240 bytes and
two are exactly the 20K the mode already reserves.  The CRTC row pitch (R1) is 64
chars, so the 20K is a ring of 40 char rows, and the two buffers are simply two start
addresses 10K apart in that one ring.  Each shows 20 of the 40 rows, so together they
tile the ring exactly and can never overlap, however far the game has scrolled.  Both
starts advance by 512 bytes per row of vertical scroll and by 8 bytes per char of
horizontal scroll; the video hardware's 20K wrap (screen size %10 on the system VIA
addressable latch, the same setting MODE 2 uses) closes the ring on its own.

No status bar means no vertical rupture, so the Master's CRTC section chain and its
VIA T1 interrupt chain are not needed here.  A single vsync interrupt re-points R12
and R13 at the buffer that has just been finished.

## Memory budget

Measured from the current Master build.

Code and tables:

| Segment | Bytes | Model B home |
|---|---|---|
| CODE (engine, renderer, loader) | 8330 | main RAM $0E00 |
| TABLES | 2222 | main RAM $0400 |
| LOW, LOW2 (NMI and MOS pages) | 569 | unchanged |
| HAZEL (game logic, menus) | 8054 | sideways bank |

Main RAM from $0206 to $2FFF is 11.7K, which holds the engine and its tables with
about 700 bytes to spare before the 6502 expansions.  The logic does not fit, so it
moves to a bank.

Data, as built today:

| File | Bytes |
|---|---|
| SPR | 16384 |
| SPRAND | 4096 |
| TIL0 + TIL1 | 32096 |
| level pack (L*A + L*B) | 14848 per level |
| TITLE | 7447 |

That is about 67K of resident data against 64K of banks, before any code at all.

Two savings make it fit.

**Solid tiles carry no data.**  470 tiles are built, but 47 of them are a single
colour throughout, either the cyan sky or a blackened backdrop, and drawrow fills
those from a constant without ever reading their 64 bytes.  Numbering them above all
the others means their bytes need not be emitted: 3008 bytes back, and bank 6 drops
from 15712 to 12704.

**A level uses a fraction of the tile set.**  Tiles with data, per level:

| | A (bonus) | B (main) |
|---|---|---|
| 0 | 153 | 207 |
| 1 | 75 | 167 |
| 2 | 160 | 267 |
| 3 | 102 | 127 |
| 4 | 149 | 267 |
| 5 | 95 | 110 |
| 6 | 128 | 245 |
| 7 | 77 | 139 |

The whole set is 423 tiles and 27072 bytes; the worst single level is 267 tiles and
17088 bytes.  So the tile banks hold about 10K more than any one level needs.  Tiles
are now numbered locally to a level: the disc keeps one copy of the tile set, and
level loading reads it a track at a time into the screen and copies out just the
tiles that level's bitmap asks for, in order, which is exactly the numbering its page
tables use.  That returns nearly 10K of bank space and costs about three seconds of
level loading, because each of the eleven tracks waits most of a revolution for its
first sector.  Reading each track from wherever the head happens to be and unwrapping
it in the buffer would get most of that back.

It also displaced the music, which was hidden in bit 6 of the tile bytes and so only
worked while the whole tile set was resident.  It is 2028 bytes of its own file in
bank 6 now.

**The menus need not be resident.**  The title logo, the big Cleo frames and the
win and lose art are already a separate pack that overlays the level in bank 7, and
the same is true of everything else the menus use.  The font and the digits sit at
the front of SPR, and the status bar image with them; the Model B has no status bar
at all, so during play those 2240 bytes of bank 4 are dead weight.  Menu code is
another 1410 bytes of the logic that never runs during a level.  Paging the lot in
only while a menu is up returns about 3.6K, and the freed space at the front of
bank 4 is where the menu overlay itself lands.

## Bank layout

As built.  Everything below is in place and running on the Master.

| Bank | Contents |
|---|---|
| 4 | SPR: font, digits and status bar image at the front, sprite data from $88C0 |
| 5 | this level's tiles, ids 0-255 |
| 6 | tiles 256 and up at $8000, row page $8400, page tables $8500 and $8700, map $8900, the row address tables at $A900, box stars $B000, music $B800 |
| 7 | header $8000, objects $8100, attributes $8500 and $8600, alt classes $8700, **free $8900-$AFFF**, object state $B000, alt page $BC00, alt class table $BE00 |

The title pack loads into bank 6 at $8900, where the map goes during a level.
SPRAND is still in the Master's ANDY and needs a home on a Model B: 2240 bytes of
it can go where the menu art is paged out of bank 4, and the rest in bank 6, which
has about 1.3K spare.

Bank 7 is free from $8900 to $AFFF, 10496 bytes, against 8054 bytes of logic and
menu code.

## Cross-bank calls

Main RAM is always visible, so code in a bank may call main RAM freely.  Two things
need help, and the traffic is small: eleven entry points into the logic, and fifteen
routines the logic calls back into.

- Main RAM calling the logic: page in bank 7, then tail-jump to the routine, so its
  own return goes straight back to the original caller.  Six bytes per entry plus a
  shared eight-byte paging routine.
- The logic calling main RAM: `jsr` the routine, then jump to a shared routine that
  puts bank 7 back and returns.  Six bytes per call plus eight shared.

That is about 170 bytes of stubs, and main RAM has roughly 160 bytes spare in the
old MOS vector and NMI pages plus the 60 the HAZEL copy loop gives back.  It fits,
but only just, which is the same squeeze the 6502 expansions face.

The renderer stays in main RAM because it alternates between the sprite bank and the
tile bank inside a single frame, which is exactly what bank-resident code cannot do.
The logic reaches the map through the bank-6 selection in maptile, which costs about
twenty cycles a call against six to a hundred calls a frame.

## Disc

`src/disc.s` reads sectors directly, without the filing system, because DFS cannot be
asked to load into a sideways bank.  It detects the machine with OSBYTE 0 and patches
itself for the board it is on:

| | control register | status, track, sector, data |
|---|---|---|
| Master | $FE24 | $FE28 - $FE2B |
| Model B, Acorn 1770 | $FE80 | $FE84 - $FE87 |

The control register bits differ too.  On the Master, bit 2 is reset, bit 5 density,
bit 4 side.  On the Model B board, bit 5 is reset, bit 3 density, bit 2 side.  Both
have the drives on bits 0 and 1 and both treat reset and density as active low, so
the values written are $20 then $25 on a Master and $08 then $29 on a Model B.

Verified in jsbeeb: both machines read 20 sectors and match the disc image byte for
byte.  The 8271 is drafted in the same file but not yet detected or tested.

## 6502

The build uses `--cpu 6502`, so the 65C02 instructions are macros that expand:

| Instruction | Sites | Expansion cost |
|---|---|---|
| `stz` | 187 | 2 bytes, clobbers A unless the macro is told otherwise |
| `bra` | 115 | 1 byte |
| `(zp)` non-indexed | 52 | 2 bytes, needs Y = 0 |
| `inc A` / `dec A` | 28 | 2 bytes |
| `phx`, `phy`, `plx`, `ply` | 11 | 2 bytes each |

About 800 bytes of growth in total, most of it in the engine, which is the part with
the least room.  `stz` is the one to audit: the backward liveness pass in
`tools/dfscan.py` can list the sites where A is dead and the cheap expansion is safe.

## Staging

1. Disc driver for both boards.  **Done**, and both read the disc byte for byte.
2. Solid tiles numbered out of the tile data.  **Done**.
3. Per-level tile numbering and the scatter loader.  **Done**.
4. The level pack split across banks 6 and 7, freeing $8900-$AFFF in bank 7.
   **Done**, with the title pack moved to bank 6 and the map queries selecting it.
5. Logic and menus relocated into bank 7, with the twenty-six stubs above.  This can
   be tested on a Master, where it costs a little speed and gains nothing, so both
   machines will run the same layout rather than two.
6. Screen: 64 x 20 window, two 10K carousels in the one 20K ring, vsync flip, and
   the rupture sections rebuilt for a 64-char pitch with no status bar.
7. Menu art paged in over the front of bank 4, and SPRAND into the space it leaves.
8. 6502 expansions and the code-size audit.
9. Machine detection at boot, and a second link configuration.
