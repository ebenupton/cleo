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

That is about 67K of resident data against 64K of banks, before any code.  The tile
set is what gives: it holds 470 tiles, but only 226 distinct tiles across all eight
levels ever need pixel data, because the blackened backdrops and the flat cyan sky
are drawn by fill and carry no source bytes at all.  A tile set reduced to what the
levels actually reference is 226 x 64 = 14464 bytes, one bank instead of two.

Distinct tiles needing data, per level:

| Level | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | union |
|---|---|---|---|---|---|---|---|---|---|
| tiles | 130 | 70 | 144 | 92 | 134 | 81 | 113 | 71 | 226 |
| bytes | 8320 | 4480 | 9216 | 5888 | 8576 | 5184 | 7232 | 4544 | 14464 |

## Bank layout

| Bank | Contents | Bytes |
|---|---|---|
| 4 | SPR | 16384 |
| 5 | reduced tile set | 14464 |
| 6 | logic and menu code, plus the level's small tables | about 14700 |
| 7 | map (8K), SPRAND (4K), music; TITLE overlays the map before a level starts | about 14300 |

The split of the level pack between banks 6 and 7 is the point of the design.  The
logic reads the page tables, object list, object state, attributes and grid on nearly
every call, so those sit in the same bank as the logic code and cost nothing.  The
map is the one big item, 8K, and it moves to bank 7.

## Cross-bank calls

Main RAM is always visible, so code in a bank may call main RAM freely.  Two things
need help:

- Main RAM calling the logic: a trampoline pages in bank 6, calls, restores the
  caller's bank.  This happens a handful of times per frame, at frame granularity.
- The logic reading or writing the map: a main-RAM helper pages bank 7, does the
  access, and restores bank 6.  A trace of level 2 shows 6.6 map queries per frame
  standing still; even a busy frame is under a hundred, so the roughly 25 cycles per
  call is noise against a 320000 cycle frame.

The renderer stays in main RAM because it alternates between the sprite bank and the
tile bank inside a single frame, which is exactly what bank-resident code cannot do.

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

1. Disc driver for both boards.  Done and verified.
2. Machine detection and a loader that reads the right binaries into banks.
3. Screen setup: 64 x 20 window, two carousels, vsync flip, no rupture.
4. Reduced tile set in `tools/convert.py`, with the music no longer hidden in tile
   bytes but carried as its own file.
5. Split of the level pack across banks 6 and 7, and the map trampoline.
6. Logic and menus relocated into bank 6.
7. 6502 expansions and the code-size audit.
