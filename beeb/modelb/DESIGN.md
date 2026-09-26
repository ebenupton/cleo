# Cleo on a Model B with 64K of sideways RAM

The whole game -- title, help, level select, all sixteen levels, win/lose, hi-score --
from the same sources as the Master's MODE 1 build.  `../src/engine.s`, `logic.s`,
`game.s` and `menu.s` are assembled with `MODELB=1`; what that define changes is
addresses (where each routine and table lives), the 65C02 spellings (`src/cpu.inc`),
and the handful of places where a bank has to be reached across a boundary.  Nothing
in the game logic or the blitters is written twice.  `tools/bdiff.mjs` runs a 20-row
Master build and this one in lock step and compares every byte of logic state after
every frame; `tools/bcheck2.mjs` + `bring2.py` compare both rings against a render of
the map.  The plan this was built to is `../docs/PLAN_MODELB_FULL.md`.

## Main RAM: 29K of display, 2K of everything else

```
$0000-$00EF  zero page      the Master's layout unchanged ($00-$A1 engine + logic,
                            $A8-$DE the logic's temps), the gaps taken by what the
                            Master keeps in main-RAM tables (defs.inc)
$0100-$013F  stack          64 bytes
$0140-$0203  low BSS        SPRLIST, the digit cache, the chain's state, the mirror's,
                            the level's shape (sprtab, mapshr, MAPSTRIDE), MUSON,
                            title_res, and the buffers' state bank 7 reads too
                            (BUF_VALID, PART_LO/HI, BUF_BARQ, spbank, DIRTYCNT)
$0206-$02FF  low code       farcall, the interrupt stub, maprow/mapbyte/mapput
                            (the Master's own), maprow5/mapstrip/dirfetch
$0300-$07FF  status bar     2 rows, loaded into place at every level, never redrawn
$0800-$0A7F  mirror A       a copy of ring A's last slot row (below)
$0A80-$43FF  ring A         23 slots x 640
$4400-$467F  mirror B
$4680-$7FFF  ring B
```

Everything from the bar up is display: 23 slots (21 visible, the composed
fine-scroll row, the bottom straddle).  23 x 640 is not a whole number of pages, so
`ringup` folds 16 bits wide on this target; both ring ends are page aligned, so its
test stays a byte compare against the buffer's `ringehi`, and both bases are at
xx80, so the low byte folds by a constant.  Nothing else is in main RAM: the code
every bank once called from a block at $7C00 (a display row's worth, with two holes
of state) is bank 5's now, and the little of its state bank 7 reads is in low BSS.

While a level loads the display is black and $0D00-$7BFF is the loader's: the NMI
transfer routine at $0D00, the load-time program at $0E00, a shared file staged at
$1C00, the level's own file at $5C00 (8K at most), the level's objects at $7C00 (LV_OBJS: main
RAM, read once by level_init before the first render; the file is staged below them
because they are copied while it is still being read).

## The four banks: code beside the data its inner loop reads

| Bank | Fixed | Per level (the loader's) | During the menus |
|---|---|---|---|
| 4 | the far table, SWAPTAB + MASKTAB0..3 at $8300, the sprite row loop at $BBE0 (`SPRITE_LOOPS 1, 0`) | images and masks $8800-$BBDF, masks alone in the hole $8040-$82FF | (untouched) |
| 5 | the far table, then init5 + take_over in the low corner ($8040, once only); from $B620 the tile blitter (drawrect, its clip, the row loop, the gather), ringaddr and the ring modulus, select_backbuf (which points ringaddr at its buffer's assembled row table), scroll_validate, the dirty lists and mark/draw_dirty, copy_partial, blank_below, mirdirty, and the buffers' state (BUF_CX/CY, PART_CY/F, FLATTAB) | the full tiles from $8100 (up to 193: L4B), the half tiles' stored rows from the 32-byte slot after them (up to 34), their pair table after those | the menu overlay from $8100: menu.s, the tune and its player, the font |
| 6 | the far table, the start-up and the low-RAM image at $8040, MASKTAB0..3 at $8400, the row loop without the mirrored blitter at $BD60 (`SPRITE_LOOPS 0, 1`) | the map at $8800 (up to 8K), the sprite directory above it (`sprtab`), the rest of the sprites, more in the hole $8180-$8300 and the page SWAPTAB would take | the title pack at $8900, over the map |
| 7 | the far table, the entry vector, the sprite records below $8300 with the disc driver's helpers, the logic, the game loop, `render_frame` and `render_core`, match_sprites and erase_old (they read the records), the sprite prologue and SPRMASK, draw_sprites, calc_ring, the display driver and the interrupt's work, the sound, the HUD, the disc driver, the object state, sprmul5 and the row multiples, sext and a second mirdirty | the level's tables at $8300: attr, altcls, the header | (untouched) |

Every bank starts with the same far table at $8000 (banks.s `COMMON_TABLES`), so the
thunk in low RAM reads it whatever bank is paged in (17 entries).  The small tables
are assembled in the bank of the code that indexes them: sprmul5 and the row
multiples in bank 7 (the prologue, the records, the chain), the ring modulus in
bank 5 (ringaddr; RINGROWS x 5 entries, the `ringmod` macro brings a row under
that with two subtractions).  Bank 7 has its own `ringaddr7` for the sprite
prologue -- the modulus by subtraction (`ringmod7`, calc_ring's too), the row
multiple from its own tables, the base from select_backbuf's `ringbhi` -- so a
sprite's address never crosses.  What does cross each frame: render_core (bank 7)
makes three far calls into bank 5 -- select_backbuf; scroll_validate, draw_dirty
and blank_below; copy_partial -- and the logic one per tile it changes
(m_mark_dirty, which parks X in `farx` because the thunk takes X).  The two
crossings that happen once a sprite and once an erased rect skip the far table
(~90 cycles) for low RAM's `callbank` (~30): page the bank, `jsr BANKENTRY` --
$BFFD, a `jmp` to the sprite row loop in banks 4 and 6 and to drawrect_clip in
bank 5 -- and bank 7 back through `pagelogic`.  `mapstrip`, the row loop's, pages
bank 5 back directly (dirfetch, the prologue's, restores 7 itself).  The mask
tables are assembled too.

Bank 5 is nearly all tiles because the level's tiles are the Master's own, none
folded away: L4B's 253 ids would be 15.8K as full tiles.  So only the tile
blitter's row loop and the two routines that call it run there, and the tiles'
addresses are arithmetic (64 bytes each from $8100, page aligned) rather than a
table beside them.  The ids and the lists that gather a level's tiles come from one
packer for both targets (`tools/convert.py` pack_tiles), laid out for this bank.  A *flat* tile -- one colour's dither, which in
MODE 1 is the same two bytes alternating down every char -- is not stored at all:
it gets an id from FLAT0 (250) and two bytes in FLATTAB (bank 5, the loader's),
the two solids being the table's last entries, and the row loop fills a run of them
from the pair (the gather flags a fill in the high byte's bit 6 and indexes the pair
with the low byte) -- Commando's `drawfill`, from the other port.  A *half* tile has
one char row that is such a fill, or equal to the other: only the other row is
stored, 32 bytes in a region above the full tiles, with the fill's pair in a table
after the halves (the row loop reaches it through two operands the loader patches).
Its id is from `half0`, in three runs -- top row fills, bottom row fills, both rows
the stored one -- and the gather puts the half's flags in the low byte's bottom
bits (bit 2 a half, bits 0-1 which row fills); the run path, which decides copy or
fill once per tile and char row anyway, reads them.  Tiles identical in bytes,
attribute and altitude class share an id.  A *mirrored* tile -- another stored
tile reversed left to right -- is not stored either, while the bank is short: its id
is from `mir0`, after the halves, and MIRTAB gives its source's slot; the gather
marks it kind 3, and the row loop draws its chars right to left, each byte's two
game pixels swapped, `((b & $33) << 2) | ((b & $CC) >> 2)`.  That is exact: the
dither is per game pixel with no position term, so a pixel's 2x2 dots move as one.
It is a char-at-a-time path, so the packer mirrors only what the bank cannot hold,
the least used first: L2B 11 tiles, L4B 16, no other level.  L4B: 191 full tiles,
40 halves, 16 mirrors, 4 flats -- 13.5K of the 13.6K.  There is one tile set for
both kinds of level, 390 tiles, in three files cut by who uses a tile: TILES0 the
outdoor levels' alone (223), TILES1 both kinds' (61), TILES2 the indoor levels'
(106), at most 256 a file (16K, STAGE's size), the tiles most levels use first.  A
level stages its side's file and the shared one in turn, and its tile list names the
files and how many of its tiles each gives.  Every level shows the Master's pixels.  drawrect's head -- the mirror and partial-row
notes, the per-rect invariants, the ring address, the map row pointer -- is main
RAM's, and the rows are one far call; the sprite prologue and its records went to
bank 7 with the logic that queues the sprites; match_sprites and erase_old are main
RAM's and run with bank 7 paged (the records).  A frame is one far call into bank
5, one per tile rectangle, one per sprite.

A far call (`farjsr`, low.s) pushes the caller's bank, a return into `fcret` and the
target, and rts's into it: ~90 cycles, nesting and interrupt safe; A goes in and
comes back, Y survives, X does not.  Two things the Master does inline go through
main RAM here because a bank cannot page another over itself: the tile blitter's map
row is fetched into MAPBUF a tile row at a time (`mapstrip`, which returns to the
caller's bank), and the sprite prologue's directory entry comes into MAPBUF too
(`dirfetch`, which is mapstrip with a count of 8; the title pack's entries and mask
addresses come the same way).

The map's row address is arithmetic on both sides (`maprow` in low RAM for the
logic, `maprow5` for the blitter): a map is 32, 64, 128 or 256 tiles wide, and row
x 2^lw is row x 256 shifted right by `mapshr` = 8 - lw, which the loader sets from
the header along with `MAPSTRIDE` (the blitter's row step) and `sprtab` (where the
directory sits: just above a map of 1 << (lw + lh) bytes).  Both keep X, which the
logic has live across them.

## The disc, and the loader

The game abandons the MOS, so it has its own disc driver (disc.s, bank 7) -- for
the 8271 the Model B was born with and for the Acorn 1770 board -- and the loader
that gathers a level into the banks (ldprog.s) runs in main RAM, where it can page
banks freely.  Both controllers raise NMI for every byte, so the transfer routine is
copied to $0D00 for a load (a jump there picks the controller's stub) and keeps its
state in that page.  The boot loader (loader.s, under the MOS) first finds the RAM:
the game needs four 16K banks it can write through ROMSEL, and takes them from
whatever sockets they are in.  The probe is the one Stuart McConnachie's sideways
RAM Elite loader used (1988, in Mark Moxon's commentary): page each of the 16 banks
through $F4 and $FE30, flip bit 0 of the ROM type byte at $8006, see whether it
stuck, put it back.  Write-protected RAM fails it and so does a floating bus.  Each
RAM bank is then classed -- empty; holding a ROM image the MOS is not running (no
entry in its table at $02A1); holding a ROM the MOS recognised -- and two socket
numbers that reach the same RAM are found by a signature written to each and read
back (Elite compares the banks' bytes, which would call four blank banks one).  The
four lowest sockets of the best class win; the game's own DFS bank is fair game as
the last resort because nothing calls the MOS once the pieces are down (interrupts
stay off from the load on).  With fewer than four the loader says so, lists the
writable banks it saw and how it wrote them, and returns to the MOS.

Solidisk and Watford boards choose the bank a STORE reaches with a register of their
own -- Solidisk: user VIA port B bits 0-3 ($FE62 = $0F, then $FE60 = bank); Watford:
a store to $FF30 + bank -- and read through ROMSEL like everyone else.  The probe is
run three ways (through ROMSEL alone, the Watford way, the Solidisk way) and the way
that finds the most banks is the board: a board's latch rests on some bank, so the
plain test "finds" that one bank on a board machine too.  Then every bank switch that
a store into sideways RAM may follow carries a companion store, assembled as a second
`sta ROMSEL` (harmless: A holds the bank) and listed in the WRFIX segment (cpu.inc
`wrsel`, `wrselx`), which build.sh appends to BANKS after the bank-number list; the
loader rewrites each by board -- Watford `sta $FF3n` for a constant bank, `sta
$FF30,x` where the bank is in X, Solidisk `sta $FE60` -- and leaves them alone on a
plain machine.  Setting the write bank does not change what is readable, so the
companion need not sit beside the switch in low RAM, which is full to the byte: the
direct switch `callbank` has none, and the bank it enters sets its own -- `ds_entry`
in banks 4 and 6, the `bank5_entry` stub (bank 5's low corner) that BANKENTRY jumps
to before drawrect_clip; drawrect sets it after `jsr mapstrip` brings bank 5 back;
the tune's `music_tick`, disc-loaded and so unpatchable, reads PBOARD and does it by
hand, as ldprog.s does for the level loads.  Low RAM keeps the ones that cannot move:
pagelogic, farcall/fcret, the interrupt's exit, mapput.  The interrupt stub enters
bank 7 through pagelogic now (the write bank too), 23 cycles it and the vsync's T1
restart each pay, which VS2T_DEFAULT takes back (tools/bcrtc.mjs: R9 still lands at
char 41-53 of the section's first scanline).  Cost: about 135 switches a frame at 4
cycles each.  A machine with RAM of two kinds gets the kind with more; two boards at
once are not handled.  jsbeeb models neither board: `BBOARD=watford|solidisk` makes
the tools wrap the CPU's store (bopen.mjs `boardEmu`), and bdiff passes on both.

The code is assembled for banks 4..7.  Every byte of it that holds a bank number --
the immediates of the switches, the far table's bank bytes in all four copies -- is
recorded at assembly (cpu.inc `bankimm`/`setbank`/`BANKREF`, which take the bank the
code sits in; the low-RAM image's entries point into bank 6's copy of it) into the
BANKFIX segment, which build.sh appends to BANKS after the pieces and checks against
them.  Having copied the pieces, the loader walks the list and rewrites each byte's
low nibble to the socket found, so the hot paths cost nothing.  What comes off the
disc later -- LDPROG, the menu overlay -- cannot be patched that way and reads the
socket from PBANK (low BSS, four bytes indexed by bank - 4, filled by start7 from the
copy the loader leaves in bank 7 beside dsk_type); the level files' placement lists
name the packer's bank, 4 or 6, and LDPROG translates it.  Then BANKS' pieces (MODE
1 first, palette black: the load lands in screen memory and would show), which drive
DFS has current (OSGBPB 6: a Gotek on drive 1 works after `*DRIVE 1`), the
controller from the DFS ROM's version (0.x/1.x are Acorn's 8271 DFSs; 2.x the 1770
one; hold W or I at boot to say so instead), and the jump into bank 7.  The 8271 keeps
the step rate DFS specified, but not its motor: after an idle spell (the title) the
head has unloaded, a read finds "not ready" -- which the 8271 latches -- so each run
first loads the head (special register $23) and reads the drive status, as DFS does;
the 1770 board is reset and its head restored once.

The disc (`build.sh`, 28 files):

    !BOOT, LOADER, BANKS   the boot
    LDPROG                 the load-time program, by the boot files: read first at
                           every load
    MENU, BAR              the menu overlay; the bar template
    SPR, SPRAND, BOX       the Master's sprite files (convert.py, MODE 1)
    TILES0, TILES1, TILES2 the tile set: outdoor, shared, indoor (convert.py)
    TITLE                  the title pack
    L0..L15                per level (tools/assets.py): a table of section offsets,
                           the header, the objects, attr and altcls by tile id, the
                           tile list (set-file index per stored tile id), the sprite
                           placement list (item, bank, address, mask address), the
                           RLE map (c < 128: c+1 literals; c >= 128: a byte c-126
                           times), the flat tiles' pairs, the half tiles' list (set
                           index and stored row) and their pairs

Sector numbers are baked in by `mkdfs.py table` (files.inc); the build runs twice
so they settle, and a third time to check that they have.

A level load, palette black, interrupts off (`load_level_b`):

1. bank 7 copies the NMI stubs to $0D00 and reads LDPROG to $0E00
2. LDPROG reads the level file to $5C00; the header, attr and altcls go to bank 7,
   the objects to $7C00; the shape (mapshr, MAPSTRIDE, sprtab) is set; the map is
   RLE-decoded straight into bank 6
3. the tile set's files the level needs are staged at $1C00 in turn and its tiles
   copied into bank 5 by the tile list
4. SPR, SPRAND and BOX are staged in turn; every image and mask the placement list
   names is copied to its bank and address (an image's mask may live in another
   file: SPRAND images keep their masks in SPR)
5. the directory goes to bank 6 and SPRMASK (bank 7, the ids below the boxes) as
   the packer finished them: the Master's entries with each image's placed address
   and bank-6 flag (no table is built at load: every one is assembled or packed)
6. the half tiles' rows and pairs go above the full tiles (the fill's operands
   patched to the table), the flat tiles' pairs to FLATTAB; the bar template is
   read to $0300
7. back in bank 7, the game's `load_level` goes on from the header as on the Master

The title's load (`load_title_b`) is the same machinery: the overlay to bank 5 at
MENU_BASE, the title pack to bank 6 at $8900.  `title_res` (low RAM) says whether
they are still there; a level load clears it, and `ensure_menu` (game.s) puts them
back before the title or the win/lose screen is entered -- the Master does this from
inside `title_menu`, which cannot work when the menu code is the overlay.

On a real 8271 with DFS's default 24 ms step rate a level takes about 8 s to load;
most of it is seeks, which the disc order keeps short.

## The packer

`tools/assets.py` packs all sixteen levels and prints a fit report.  Per level it
picks the tiles the map (and the animations) can show -- the Master's own set, no
level folds a tile the Master shows -- merges the byte-identical ones (attribute
and altitude class included: the logic reads those by id), classes them as full,
half or flat and numbers them, writes attr/altcls by that numbering,
and places the level's sprites in banks 4 and 6 largest first: mirrored images to
bank 4 (SWAPTAB is there), box stars and trampolines to bank 6 (the copy blitter
is there), the rest wherever they fit, a mask always in its image's bank.  MAXSPR
and BINMAX are the maxima over every level (24, 18); OBJN is the Master's 149.

## Menus on this target

menu.s is assembled under MODELB into the overlay: `clear_ring` clears main RAM from
the bar up (the bar, both mirrors and both rings), `clear_items` stops at the ring's
23 slots, the font
comes from the overlay itself, and the screens are laid out for 80 px of window (the
Master's 108): the help lines 10 px apart, the level list centred on the window, the
scores under big Cleo.  What the menus call in bank 7 (the palette, the flip, the disc, the
sections, `div10_16`) crosses through the far table (`FARSUB` in engine.s); what
they call in bank 5 (the ring work, the prologue) is a plain name.  The tune's
player lives in the overlay with its data and is stepped from the interrupt stub in
low RAM while MUSON is set; MUSON is cleared by `music_stop` in bank 7, which the
level load calls, so the stub never enters bank 5 during a level.

There is no pause on either target (removed 26 Sep 2026).

## What the define changes, and only that

- `PLACE "CODE", "TILCODE"`: the segment a routine goes in, Master name first.
- `ringup p` folds `p` 16 bits wide against the buffer's end; `select_backbuf` sets
  `ringbhi/ringehi/ringe3/ringneg` and rebuilds RINGLO/HI from the buffer's base.
- `drawrect` is whole in bank 5 (erase_old reaches its clip through `F_DRAWRECT`);
  the map fetch is `maprow5` + `mapstrip`; the gather is arithmetic.
- `drawsprite`: no bank switching in the prologue; the directory entry via `dirfetch`
  from `sprtab`; the dispatch index goes in `sp_disp` and the loop copy patches its
  own jump; the hand-over to the row loop is a far call chosen by `sp_dbank`.
- the mirror's bookkeeping: three MODELB blocks (drawrect, drawsprite, copy_partial)
  call `mirdirty` with the window columns written to the row the mirror follows;
  `mirror_copy` copies only those.
- `render_frame`'s ring work is `render_core`, bank 7's: one far call into bank 5
  (`render5` = scroll_validate + draw_dirty), the rest main RAM's or its own; the chain and the mirror are built here; `bar_bg` only resets the
  digit cache.
- `init_maprows`, `music_init` are nothing; the `t_`/`m_` bridges are names or
  `FARSUB`s.
- tables: MAXSPR/MAXREC and BINMAX are the packer's bounds over every level; the
  level's tables are BSS in bank 7 the loader fills, the objects main RAM's.

## The 6502 spellings

`src/cpu.inc` documents the contracts.  `tools/flagscan.py` (in `../tools`) audits
every site: `stz` needs A dead (the two with A live are `stza`), `inca`/`deca` keep
the carry (through `mtmp`) because the sprite prologue counts on it, `ldaz` destroys
Y (the one site with Y live is `ldazy`), `bitimm` keeps A.

## Verification

- `tools/bdiff.mjs N seed level`: the 20-row Master (`../build/ref_mode1_20`, the
  Master built with `VISROWSDEF=20 ./build.sh`) and this build, same keys at every
  `frame_top`, all of the logic state compared each frame.  `BMODEL=B1770` runs the
  1770 machine.  The title is patched out and the level chosen the way the Master
  harness does it (`tools/bopen.mjs`, shared by the tools below).
- `tools/bcheck2.mjs keys frames [pre] level` + `tools/bring2.py cur`: the current
  buffer's ring against the map at `draw_sprites` (pure map, kept sprites excluded)
  and the mirror against the last slot row at `frame_top`; the tiles, halves, pairs
  and map are dumped from the banks, so this also proves what the loader put there.
- `tools/bwork2.mjs frames seed level`: frame cost.
- `tools/bshot2.mjs cycles out x0 x1 y0 y1 level`, `bboot.mjs model secs outdir`
  (the disc booted through the title into a game, both controllers), `bbrk.mjs`.

## Known differences from the Master

21 visible rows against 30 (84 game px: the world's in-range decisions follow
VISLINES, which is why the reference for the lock-step test is a 21-row Master).  The
picture starts 72 lines after vsync, 4 scanlines below where a standard frame's centre
would put it.  The tiles and their ids are the Master's; neither target folds any.
