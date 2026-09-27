# Cleo: the design

Cleo is one game on one disc for two machines: a BBC Model B with 64K of sideways RAM
and a BBC Master 128.  This document is the detail behind the README.  Addresses are
from the linker maps (`build/modelb/map.txt`, `build/master/map.txt`) and the sources
they come from; where the two machines differ, both are given.

## One structure, two machines

The sources in `src/` (`main.s` includes the rest) are assembled twice by `build.sh`:
`BHW=1` for the Model B's hardware (6502, `cfg/modelb.cfg`, output in `build/modelb/`)
and `BHW=0` for the Master's (65C02, `cfg/master.cfg`, `build/master/`).  `BHW` is only
the hardware.  The structure is the same on both: the code lives in four 16K sideways
RAM banks, each beside the data its inner loop reads, and the game's own loader gathers
every level from the disc into those banks.

| Bank | Code | Data |
|---|---|---|
| 4 | the sprite row loop, with the mirrored blitter | most sprite images and masks; SWAPTAB; the mask tables |
| 5 | the sprite row loop with the copy blitter; the tile row's gather | the rest of the sprites; the level's map; the mask tables |
| 6 | the tile blitter and the ring work that calls it | the level's tiles (or the menu overlay) |
| 7 | everything else: the logic, the game loop, the sprite prologue, the display chain's builder, the HUD, the disc driver | the level's tables, the object state, the sprite directory and records |

What `BHW` changes is the hardware underneath:

- **The Model B**: a 6502; 32K of main RAM that is almost all display, holding two
  software rings of 23 character rows, each with a mirror row; the rupture chain's
  interrupt work in bank 7 behind a stub in low RAM; an 8271 or an Acorn 1770 disc
  controller; Watford and Solidisk write-select boards; the tile gather computed.
- **The Master**: a 65C02; one hardware-wrapped ring of 32 rows at $3000, in main RAM
  for buffer 0 and shadow RAM for buffer 1; the status bar at $2B00; its interrupt
  handler and chain step in main RAM ($0600); its own 1770; the tile gather through a
  per-level table in main RAM (LV_PAGE0).

The level files, the sprites, the tile set, the title pack and the bar template are on
the disc once and read by both.  Each machine has its own bank images (BANKSB,
BANKSM), load-time program (LDPROGB, LDPROGM) and menu overlay (MENUB, MENUM).  Because
the level files carry the sprites' placed addresses, the level layout is the Model B's
on both machines: `engine.s` asserts that each sprite bank's code ends exactly at
`B4_CODE_END`/`B5_CODE_END` on the Model B and at most there on the Master, whose
shorter code leaves a gap.  `build.sh` checks that the two builds' shared files are
byte-identical.

`TILEMIRROR=1 sh build.sh` also builds mirrored tiles into the tile blitter (below).
It is off by default: no level needs it.

## Main RAM

### Zero page (both machines)

| Range | Use |
|---|---|
| $00-$A2 | the ZEROPAGE segment (engine and logic scalars; the linker caps it at $A2): ends $A1 on the Model B, $9A on the Master |
| $A3-$A7 | fixed (defs.inc): NSPR, BARDIRTY, BINI, SFXREQ, fcA (xcall's A) |
| $A8-$DE | the logic's temporaries (logic.s); LDPROG reuses $A8-$B8 during a load |
| $DF-$EF | fixed (defs.inc): mtmp (cpu.inc's scratch), the Model B's ring and mirror state (ringbhi, ringehi, ringe3, ringneg, mrow, wcxm, rstar), the sprite prologue's hand-over (sp_disp, sp_mpg0, sp_mh, sp_mrp, sp_mbase), curR7, SECIDX |
| $F0-$FF | the MOS's zero page, but $F4 and $FC: the hottest scalars |

Once the game has the machine only two of the MOS's zero-page bytes are still touched:
$F4, the MOS's copy of ROMSEL, which the interrupt restores from, and $FC, where the
MOS's interrupt entry keeps A (every handler returns with `lda $FC / rti`).  The rest,
in segments ZPF0 ($F0-$F3), ZPF5 ($F5-$FB) and ZPFD ($FD-$FF), holds scalars that were
absolute and are among the most accessed (`test/hotvars.mjs` counts them): MAPSTRIDE,
mapshr, MUSTICK, rowbit, dpass, spclip, NSTARL, NOTHL, spbank, halfhi, MUSON, and on
the Model B crtcb.  `boot` zeroes them.  On the Model B the arithmetic gather's shape
(half0-2, halfhi5, halfsub) and `jv`, the vector the 6502's `jmp (abs,x)` goes
through, are in the ZEROPAGE segment.

### Low RAM (both machines)

| Range | Model B | Master | Use |
|---|---|---|---|
| $0100-$013F | | | the stack, 64 bytes |
| LOWBSS | $0140-$01F8 | $0140-$01F0 | what more than one bank reads: the sprite list (SPRLIST), the buffers' state (BUF_CX, BUF_BOTOK, DIRTYCNT), PBANK/PBOARD, BARCACHE, DISPSECT/NEXTSECT, ctgt, GATHERH (= MAPBUF), the mirror's notes (Model B), sprc_ok, sprx_ok, title_res |
| $0204-$0205 | | | IRQ1V, which the game points at its handler |
| LOWCODE | $0206-$02E4 | $0206-$02A4 | the crossings, the map helpers, pagelogic; the Model B's interrupt stub |
| LOWBSS2 | $02E5-$02F9 | $02A5-$02B9 | GATHERL |

LOWCODE is linked to run here and loaded behind the start-up code; `boot` copies it
down byte by byte (it is asserted under 256 bytes).

### The Model B

| Range | Use |
|---|---|
| $0300-$07FF | the status bar, 2 rows |
| $0800-$0A7F | mirror A: a copy of ring A's last slot row |
| $0A80-$43FF | ring A: 23 slots of 640 bytes |
| $4400-$467F | mirror B |
| $4680-$7FFF | ring B |

Everything from $0300 up is display; nothing else lives in main RAM during play.  23 x
640 is not a whole number of pages, so a pointer's fold at the ring end is 16 bits
wide, but both ring ends are page aligned (asserted: RINGEND_B = $8000, RINGEND_A a
page boundary), so `ringup`'s test is a byte compare against the buffer's `ringehi`,
and both bases are at xx80 (asserted), so the low byte folds by a constant.

During a load the display is black and is the loader's: the NMI routine at $0D00
(NMIPAGE), the load-time program at $0E00 (LDPROG, at most $0E00 bytes), a shared file
staged at $1C00-$5BFF (STAGE, 16K), the level's own file at $5C00-$7BFF (STAGE_LVL, 8K;
`tools/assets.py` asserts every level file fits), and the level's objects at $7C00
(LV_OBJS: 6 bytes each, read once by `level_init` before the first render).  The file
is staged below the objects because they are copied out while it is still being read.

### The Master

| Range | Use |
|---|---|
| $0400-$05FF | LV_PAGE0: the level's tile gather table, 256 low bytes and 256 high |
| $0600-$08CA | CODE: the interrupt handler and chain step, the keyboard, the sound effects |
| $0C00-$0C6D | TABLES: the handler's state (BUF_SEC0, BUF_SEC0T1, SECTAB, SFXDUR, LOADREQ, dispD, OLDIRQ, NEXTBUF); `boot` zeroes it |
| $1C00- | LV_OBJS, the level's objects (below the display; LDPROG ends by $1BFF) |
| $2B00-$2FFF | the status bar, 2 rows, main RAM, single-buffered |
| $3000-$7FFF | the ring: buffer 0 in main RAM, buffer 1 in shadow RAM at the same addresses |

The ring is the whole region the hardware wraps: an address that runs past $8000 comes
back to $3000, so a displayed row may straddle the end and needs no mirror.  That is
why RINGROWS is 32: it is the size of the wrap, not a choice.  The bar is below $3000
and there is only one of it; with shadow selected for display (ACCCON D = 1) the CRTC
does not see main RAM there, so the bar's section is scanned with D = 0 and the
playfield's with D = the buffer shown.

After its first read SPRX (12K) is kept in HAZEL ($C000-$DFFF, 8K) and ANDY
($8000-$8FFF, 4K), and later loads rebuild the stage from there instead of the disc.
During a load the shared files are staged in shadow RAM at $3000 (ACCCON X set around
every read and every copy out) and the level's file in main RAM at $3000; the load
ends by clearing both screens, because a ring row the window has not reached yet must
not show what was staged there.  Every load starts by putting the CPU on main RAM
(ACCCON X and Y clear): the game leaves X on the buffer it drew last.

### Start-up (both machines)

The BOOT piece is loaded at $7000, display RAM that nothing has drawn in yet, with the
low-RAM image behind it.  Its header is the boot loader's findings at fixed addresses
on both machines: `dsk_type` $7000 (the controller), `dsk_drv` $7001, `dsk_banks`
$7002-$7005 (the socket of each of banks 4-7), `dsk_board` $7006; `boot` is at $7007
(all asserted in `init.s` and checked equal across the builds by `build.sh`).  `boot`
sets a 64-byte stack, zeroes zero page and low RAM (the MOS's zero page but $F4 and
$FC), copies the low code down, pages bank 7, copies the banks and the board to PBANK
and PBOARD and the controller and drive to the disc driver, blanks the palette, sets
up the CRTC and both buffers' chains, zeroes bank 6's variables, takes over the
interrupt and starts the game.  The screen overwrites it once play starts.

## The banks

The code for banks 4, 5 and 6 starts at $8000 and the data runs from the code's end
upward, so the data can be any size.  Each of these banks is entered at BANKENTRY =
$8000.

### Bank 4: sprites

| Range | Model B | Master |
|---|---|---|
| the row loop (SPR4CODE: `ds_entry`, the masked and mirrored-masked blitters) | $8000-$83AE | $8000-$8391 |
| SPRC's bank-4 part (the resident sprites, 9,148 bytes) | $83AF-$A76A | same |
| the level's sprites, images and masks | $A76B-$BAFF | same |
| SWAPTAB (four-dot reversal) | $BB00-$BBFF | same |
| MASKTAB0-3 | $BC00-$BFFF | same |

### Bank 5: sprites and the map

| Range | Model B | Master |
|---|---|---|
| the row loop (SPR5CODE: the masked and copy blitters, no mirror) | $8000-$8251 | $8000-$822A |
| MAP5CODE: `gather5`, `fetch8` | $8252-$82BF | $822B-$8252 |
| SPRC's bank-5 part (1,765 bytes, the trampoline's boxes included) | $82C0-$89A4 | same |
| the level's sprites | $89A5-$9BFF | same |
| the map (MAP5 = LV_MAP), a fixed 8K | $9C00-$BBFF | same |
| MASKTAB0-3 | $BC00-$BFFF | same |

During the menus the title pack (11,574 bytes) sits from TITLE_ADDR = $8900, over the
sprites and the map.  It reaches SPRC's bank-5 part, so returning to the title clears
`sprc_ok` and the next level reloads the resident block.

### Bank 6: tiles

| Range | Model B | Master |
|---|---|---|
| TIL6ENT: `bank6_entry`, `drawrect_clip` | $8000-$806F | $8000-$806C |
| TILCODE: `drawrect` and its row loop, `ringaddr` and its row tables, `select_backbuf`, `scroll_validate`, `mirdirty6` and the ring modulus table (Model B) | $8070-$85E6 | $806D-$8586 |
| TILBSS: BUF_CY, FLATTAB | $85E7-$85F4 | $8587-$8594 |
| the level's tiles (TILES), 64 bytes each | $8600-$BFFF | same |
| or, during the menus, the menu overlay (MNUCODE, MNUDATA, MNUBSS) | $8600-$95EB | $8600-$95AC |

### Bank 7: logic

| Range | Model B | Master |
|---|---|---|
| LGCLVL: LV_ATTR0, LV_ALTCLS (256 each), LV_HDR (32), loaded | $8000-$821F | same |
| LGCDATA: the row multiples, LV_ALTTAB, the HUD digits | $8220-$8355 | $8220-$8367 |
| LGCCODE | $8356-$A99F | $8368-$A4FD |
| the NMI stubs' image | $A9A0-$A9F8 | $A4FE-$A556 |
| LGCBSS | $A9F9-$BD3B | $A557-$B82D |
| free | $BD3C-$BFFF | $B82E-$BFFF |

LGCCODE is the logic, the game loop, `render_frame` and `render_core`, the sprite
prologue (`drawsprite`), `draw_sprites`, `match_sprites`, `erase_old`, `calc_ring`,
`copy_partial`, `blank_below`, `mark_dirty`, `draw_dirty`, `build_sections`, the HUD,
the palette, the disc driver, and on the Model B the interrupt's work (`isr_body`,
`vsync_tick`, `scan_keys`, `sound_tick`) and `mirror_copy`.  LGCBSS is the object state
(16 arrays of OBJN = 149, the collision grid, its chains and the bin walk lists),
SPRMASK and SPR_TABLE (the level's sprite directory, 118 entries of 8 bytes), the
sprite records (SPRREC, RECCNT, KEEP), the dirty lists, the disc driver's variables,
and on the Model B the chain's tables (SECTAB, BUF_SEC0, BUF_SEC0T1, LOADREQ).

The small tables are assembled, not built at start-up, each in the bank of the code
that indexes it: the row multiples (`mulrowlo/hi`) in bank 7 for the prologue, the
records and the chain; the ring modulus (`ringmodtab`, RINGROWS x 5 entries, which
`ringmod` reaches with two subtractions) in bank 6 for `ringaddr` on the Model B, where
the Master's ring needs only `and #31`.  Bank 7 has its own `ringaddr7` (the modulus by
subtraction, the base from `ringbhi`) so a sprite's screen address never crosses a bank.

## The crossings

A bank cannot page another in over itself, so every crossing is a fixed thunk in low
RAM (`low.s`).  There is no table and no dispatch in any bank.

- `callbank` (A = the bank): pages it, calls BANKENTRY, pages bank 7 back through
  `pagelogic`.  Once a sprite (the row loop in bank 4 or 5) and once a tile rectangle
  (`drawrect_clip` in bank 6, from `erase_old` and `draw_dirty`).
- `selbb` and `validate`: bank 7's two other calls a frame into bank 6,
  `select_backbuf` (which patches `ringaddr`'s row-table operand on the Model B) and
  `scroll_validate` (which draws the newly exposed strips with `drawrect`).
- `mapstrip`: from bank 6's `drawrect`, once a tile row: pages bank 5, runs `gather5`
  over the map in place, pages bank 6 back through `page6`.
- `dirfetch`: for the title pack's directory entries and mask addresses, which live in
  bank 5 with the pack: `fetch8` copies eight bytes into MAPBUF.
- `maprow`, `mapbyte`, `mapput`: the logic's reads and writes of the map in bank 5.
- `xcall` (the menus only): X = the bank, `ctgt` = the target.  It pushes the
  caller's bank, so it nests (a menu calls the title load, which reads the disc); A goes
  in and comes back (through fcA), Y survives, X does not.  Its stubs are made by the
  XCALL macro (`engine.s`): bank 7's four into the overlay (title, help, level select,
  win/lose) and the overlay's into bank 7 (the palette, the loads, the sections, the
  prologue, `div10_16`, `calc_ring`, `music_stop`).

Every switch writes ROMSEL_CPY ($F4) before ROMSEL, so an interrupt landing between the
two restores the bank being entered.  A switch that a store into sideways RAM may
follow also sets the write bank (below); `pagelogic` does, so everything that returns to
bank 7 has it right.

The tile gather runs in bank 5 beside the map because reading the map from bank 6
would take a bank switch per read; `gather5` reads a tile row's ids once into
GATHERL/GATHERH in low RAM, and the row loop draws both char rows of the tile row from
them without touching the map again.  The game's own sprite directory is in bank 7
beside the prologue, which reads it in place: in bank 5 it cost about 1,250 cycles a
frame.

## Bank numbers, sockets and write-select boards

The code is assembled for banks 4-7, but the four banks are whichever sockets the boot
loader finds RAM in (it runs the same probe on both machines).  Every byte of code that
holds a bank number is recorded at assembly (`cpu.inc`: `bankimm`, `setbank`, `BANKREF`) into the BANKFIX
segment, which `build.sh` appends to BANKS and checks against the pieces (each entry
must land on a byte whose low nibble is 4-7).  The boot loader rewrites each byte's low
nibble to the socket found and keeps the high nibble.  So the hot paths pay nothing.
What comes off the disc after boot -- LDPROG, the menu overlay -- cannot be patched and
reads the socket from PBANK (four bytes, indexed by bank - 4; the `ldpbank` macro).

Solidisk and Watford boards read through ROMSEL like any machine but choose the bank a
store reaches with a register of their own: Solidisk, user VIA port B bits 0-3
($FE62 = $0F, then $FE60 = the bank); Watford, a store to $FF30 + the bank.  Every
switch that a store into sideways RAM may follow carries a companion store, assembled
as a second `sta ROMSEL` (harmless: A holds the bank) and recorded in the WRFIX segment
(`cpu.inc` `wrsel` for a constant bank, `wrselx` where the bank is in X as well).
`build.sh` appends the list after BANKFIX and asserts that every entry sits on
`sta $FE30`.  The boot loader rewrites each by board -- Watford `sta $FF3n` or
`sta $FF30,x`, Solidisk `sta $FE60` -- and leaves them alone on a plain machine.  A
switch that only reads (`mapbyte`, `mapstrip`'s way in) needs none.  Setting the write
bank does not change what is readable, so the companion need not sit beside the switch:
low RAM is nearly full, so `callbank` has none, and the bank it enters sets its own --
`ds_entry` in banks 4 and 5, `bank6_entry` in bank 6 (BANKENTRY, falling into
`drawrect_clip`).  `drawrect` sets it again
after `mapstrip`.  Disc-loaded code reads PBOARD and does it by hand: `music_tick` in
the overlay, and `ldprog.s`.  On the Master the macros are empty.

The boot loader (`loader.s`) finds the RAM with the test Stuart McConnachie's sideways
RAM Elite loader used: page each of the 16 banks through $F4 and ROMSEL, flip bit 0 of
the ROM type byte at $8006, see whether it stuck, put it back.  A floating bus fails
it, and so does write-protected RAM.  The test runs three ways -- through ROMSEL alone,
the Watford way, the Solidisk way -- and the way that finds the most banks is the board
(a board's write latch rests on some bank, so the plain test finds that one bank on a
board machine too; plain wins a tie).  Each RAM bank is then classed: empty; holding a
ROM image the MOS is not running (no entry in its table at $02A1); holding a ROM the MOS
recognised.  Two socket numbers that reach the same RAM are found by a signature written
to each and read back (comparing the banks' bytes would call four blank banks one).
The four lowest sockets of the best class win; a bank holding a live ROM is fair game
as a last resort because nothing calls the MOS once the pieces are down and interrupts
stay off until the game's own handler is in.  With fewer than four the loader says
what it found, and how it wrote, and returns to the MOS.  A machine with RAM of two
kinds gets the kind with more; two boards at once are not handled.

## The display

MODE 1, 80 characters (160 game pixels) wide, each square game pixel a 2x2 block of
MODE 1 dots.  The palette is logical 0-3 = black, cyan, magenta, yellow; the colours
come from a dither per game pixel (`tools/convert.py`): for each pixel the four-dot
combination of C, M, Y and K nearest its colour, laid in kernel order (top left,
bottom right, top right, bottom left) so that two inks of two make a checker.  The
dither has no position term, so a tile or sprite reversed left to right with each
byte's two pixels swapped is exact.

Horizontal scrolling is by whole characters (two game pixels) through the CRTC start
address.  Vertical scrolling is by a game pixel, two scanlines (`wfine` = 0, 2, 4 or 6
lines into the character row), through a *rupture*: the frame is several CRTC frames, each
section reprogrammed from a chain of VIA T1 interrupts and the whole re-phased at every
vsync.  The window is `wx`, `wy` in map pixels; `wcx` = wx/2 and `wcy` = wy/4 in
characters and character rows; the ring offset of the window's top-left character is
`ringS` and its slot `barq` (`calc_ring`).

Both buffers are rings of characters, 80 to a row, and the playfield is drawn in map
space: map character (cx, cy) lives at ring character ((cy mod RINGROWS) x 80 + cx) mod
RINGCHARS (`ringaddr`).  So a scroll only draws the newly exposed strips
(`scroll_validate`), a displayed row may start anywhere in a slot and straddle the
ring's end, the bar has a fixed home outside the ring, and only the playfield's
sections walk the ring.

### The sections

| Section | Model B | Master |
|---|---|---|
| T, the bar | 2 rows at $0300 | 2 rows at $2B00, D = 0 |
| A, the composed row (when `wfine` > 0) | 8 - f lines | 8 - f lines |
| P, the playfield | P1 to the ring's end, then M from the mirror | one section: the CRTC folds it |
| P2, the bottom partial (when `wfine` > 0) | f lines | f lines |
| Q, blanking | 16 rows, vsync at row 8 | 7 rows, vsync at row 3 |
| visible rows | 21 (84 game px) | 30 (120 game px) |

All sections total 39 rows, 312 lines.  The bar is scanned (QROWS - QVSYNC) x 8 lines
after the vsync starts: 32 on the Master, where the Master MOS's own MODE 1 frame puts
the picture; 64 on the Model B, 4 lines below where a MODE 1 screen sits.

The **composed row** A shows lines f..7 of the window's top row at the top of the
picture.  It is the ring row just above the window, ring characters [ringS - 80,
ringS): a row at a constant offset from its source, so a horizontal scroll leaves it
valid.  `copy_partial` recomposes all 80 columns every frame that `wfine` is not 0
(tracking the columns drawn since the last copy saved under 0.3% of a frame; the
unrolled copy is about 1% of a frame faster than a loop).  On the Master the ring holds
the 31 rows of the window and its bottom partial plus this one, which is why VISROWS is
30.  On the Model B the 23 slots are the 21 visible rows, the composed row and the
bottom straddle.

The **mirror** (Model B): a displayed row that starts within the ring's last 80
characters straddles the ring end.  The CRTC cannot fold a 23-row ring, so a copy of
the ring's last slot row sits immediately below the ring base, where the address
`c - RINGCHARS` names the straddling row, and every row after it follows on
contiguously: the chain reads P1 up to the ring's end and M from the mirror
(`build_sections`, `display.s`).  Only the characters that row takes from the mirror --
`wcxm`..79, where `wcxm` is ringS mod 80 -- need to be right, and when the window is
slot aligned no row straddles at all.  The blitters note the columns they write to the
row the mirror follows (`mirdirty`, `mirdirty6`, from `drawrect`, the sprite prologue
and `copy_partial`), and `mirror_copy`, the last step of `render_core`, copies only
those; a move left uncovers characters the last copy never reached, so it redoes the
whole row.

`blank_below`: a 6845 always displays the first scanline of a frame whatever R6 says,
so Q's row 0 line 0 -- the ring slot below the playfield -- is one more line under the
picture.  Everywhere it is the next map line; parked on the map's bottom row it is
whatever that never-drawn slot last held, so there the slot is blanked once per buffer
per arrival.

### The chain

`build_sections` fills SECTAB (8 bytes an entry: R12, R13, R4, R9, R6, R7, T1 low, T1
high; 48 bytes a buffer) from `ringS` and `wfine`.  An entry holds section i's shape
and section i+1's address and duration, because R12/R13 latch at the next restart and
a T1 latch takes effect one interrupt later.  Section 0, the bar, takes its address and
length from BUF_SEC0/BUF_SEC0T1 of the buffer about to be shown.

Each T1 interrupt is a CRTC restart.  R12/R13 were armed during the section before.
R9 and R4 together decide where the new section ends: the CRTC latches end-of-frame at
the start of the scanline where row = R4 and line = R9, so for a two-line section both
must be in place before scanline 1, 128 cycles after the restart; R6 is compared from
scanline 1 on, so Q's R6 = 0 has the same deadline.  The chain is phased (VS2T) so the
step fires before the restart -- the Master's handler holds about 26 cycles, the Model
B's bank switch in the stub serves the same purpose -- and then writes R9, R4, R6, R7
in that order (with R4 third it landed at about 140 cycles for a two-line P2, the
section never ended, and both borders lit on every scroll frame).  R12/R13 go last,
after the T1 reload and the index bookkeeping, so they land on scanline 1: written
straight after R7 they fell across the end of scanline 0, and some 6845s -- the VL6845
among them (Tom Seddon's r4-3 test) -- end a partial (R4 = 0 on row 0) at once and
reload the start address as that scanline ends.  A Master with such a chip lost the
R12 write and showed the playfield 256 characters adrift, a 16-character tear down
every row whenever the fine scroll was not 0.

The chain stops at Q, the only section whose R7 is the vsync row, so a late vsync
cannot walk it off the end of SECTAB.  The vsync interrupt (CA1, at the end of the
2-line pulse) restarts T1 first, for a constant latency, then re-phases: R9 = 7 and
R4 = curR7 + QROWS - 1 - QVSYNC, so this frame ends a fixed number of rows after the
vsync whatever the row counter did (a counter that has run past its vertical total
otherwise never recovers).  It pre-arms the bar's R6 there, in Q, where a new R6
cannot show.  A pending flip is taken only at a vsync at least two after the last
one; the vsync then programs section 0 from the buffer about to be shown, scans the
keyboard and runs the sound.

`crtc_init` writes R8 = 0 on both machines: the MOS's MODE 1 leaves interlace sync on,
which puts every other field's vsync half a scanline later (on BeebEm's Model B it
showed as a band across the picture).

The VS2T constants (defs.inc for the Model B, `engine.s` for the Master) are the
vsync-to-bar time less the pulse, less the lead that puts each step ahead of its
restart (-35 -36), less the step's own entry costs: on the Model B -23 for the stub
entering bank 7 through `pagelogic` (which also sets the write bank) and -12 for the
LOADREQ test and the IER-masked entry; on the Master -8 for the LOADREQ test.  +2 ticks
on both: the vsync loads it as an immediate.

**The Master's ACCCON D.**  D is the memory map the CRTC fetches from, sampled on every
fetch, so it must change before a section's boundary, not after.  The bar's T1 fires
BARLEAD = 10 us earlier than every other step's lead, so D can be switched in the
horizontal blanking of the bar's last line; the section after the bar runs BARLEAD
longer to end where it should.  The handler sets D from `dispD` for every section but
the bar (which starts with D = 0, cleared at the vsync); the flip moves `dispD` to the
new buffer with the section chain.  `select_backbuf`'s read-modify-write of ACCCON's X
bit runs with interrupts off, since the handler writes D.

### Load mode

A disc load stops the chain (interrupts are off while the disc is read).  Stopped
mid-chain the CRTC would repeat whatever section it was in with no vsync, and monitors
and capture cards take seconds to regain sync.  So `load_begin` asks the chain to stop
at a frame boundary (LOADREQ: 0 running, 1 stop asked, 2 stopped, 3 resume asked): the
next bar step programs a standard 39-row frame instead (R4 = LDR4 = 38, R7 = LDR7 = the
row the chain's vsync is on) and turns T1's interrupt off, so the sync never moves.
The switch is made in the interrupt handler's bar step, so it happens at the frame
boundary however long the handler's other work runs (a version that waited for a
vsync and polled for the bar's T1 switched one section late when the vsync's work ran
past that T1, and made a short frame).  While stopped the vsync still counts, scans
the keys and plays the sound.  `load_end` sets 3; the next vsync turns T1's interrupt
on again and its re-phase, with curR7 = LDR7, is exactly the standard frame's total,
so the bar step at that frame's end takes the display back as if it had never stopped.
The palette is black throughout.

### Double buffering and the flip

`curbuf` is the buffer being drawn.  `render_frame` waits for the previous flip, draws
the HUD digits if BARDIRTY (the bar is single-buffered and drawn where it is shown, so
this comes first, before the CRTC reaches it), derives the character window, runs
`render_core`, builds the chain for this buffer and requests the flip.  `render_core`:
`selbb`, `calc_ring`, `match_sprites`, `erase_old`, `validate`, `draw_dirty`,
`blank_below`, `draw_sprites`, `copy_partial`, and on the Model B `mirror_copy`.

The bar's template (the BAR file, 1,280 bytes) is read into place by each title load
and never redrawn; only the digits change (`bar_digit`, with a one-bar digit cache,
BARCACHE, that `bar_bg` resets).  A digit is packed in 16 bytes, a nibble per byte
column and two game rows; DIGTOP and DIGBOT give each nibble's two scanline bytes.  The
bar lives outside the ring because in the ring it moved with every vertical scroll and
re-copying its 1,280 bytes cost 13,310 cycles a frame.  The menus never show or touch
it: `menu_sections` points section 0 at two black ring rows below the window instead.

## The tiles

A map tile is 8x8 game pixels: 4 characters by 2 character rows, 64 bytes.  A map byte
is a level tile id:

| Ids | Kind |
|---|---|
| 0 | the level's solid: the colour it uses more (cyan outdoors, black indoors), one byte down every line |
| 1 .. half0-1 | full tiles, stored at TILES + 64 x id (slot 0 is unused) |
| half0 .. half1-1 | half tiles whose top row is a fill |
| half1 .. half2-1 | half tiles whose bottom row is a fill |
| half2 .. mir0-1 | half tiles whose two rows are the same |
| mir0 .. (TILEMIRROR only) | full tiles drawn mirrored from another's slot |
| FLAT0 = 250 .. 253 | flat tiles: one colour's dither, two bytes alternating down every character |
| 254, 255 | the solids, cyan and black: a level's other solid, where it has both |

Tiles identical in bytes, attribute and altitude class share an id (the logic reads
attribute and altitude class by id).  A flat tile is not stored: its two bytes are in
FLATTAB (bank 6), the solids last.  A half tile stores its one distinct character row,
32 bytes, from HALFPAGE + HALFOFF x 32 (the page after the full tiles), with its fill's
pair in a table after the halves; the row loop's two loads of that pair are patched by
the loader (HPAIR0, HPAIR1).  The solid's fill byte is the header's +31; the loader
patches it into the row loop's `lda #` (SOLIDF: a cheap label, which `build.sh` reads
from `cleo.dbg`, because any symbol defined there would end the loop's `@` scope).  The ids and the lists that gather a level's tiles come
from one packer (`convert.py pack_tiles`) laid out for the Model B's bank, the smaller:
the tiles from $8600 to the end of bank 6 on both machines.

`gather5` turns a tile row's ids into (GATHERL, GATHERH) pairs, which `drawrect`'s row
loop reads:

- a full tile: GATHERH = its page, GATHERL = (id & 3) << 6 (bits 0-5 clear);
- a half tile: GATHERH = its stored row's page, GATHERL = its offset | bit 2 | which
  row fills (bit 0 the top, bit 1 the bottom, neither: both rows are the stored one);
  the row loop tests against `rowbit` (1 for the top character row, 2 for the bottom);
- a fill: GATHERH bit 7 clear, so the row loop's one `bpl` after the load finds every
  fill and a tile run pays nothing more.  GATHERH = 0 is the level's solid (id 0): on
  the Master the store-only cascade with the patched byte, on the Model B the patched
  byte as a pair into its one fill cascade.  Otherwise, on the Model B GATHERH = $40
  and GATHERL indexes the pair in FLATTAB; on the Master LV_PAGE0 splits them: $40 with
  GATHERL the byte itself (the other solid, or a flat whose two bytes are equal), $60
  with GATHERL indexing the pair.

On the Model B `gather5` computes the pair from the id with the level's shape (half0,
half1, half2, halfhi5, halfsub, in zero page), since main RAM has no room for a table.
On the Master it is two indexed loads from LV_PAGE0 in main RAM, a table the packer
builds per level; unused ids in it are a black fill ($40, 0), because the rows past a
map's end are read too.  The Model B's gather tests for id 0 first (`beq`, 2 cycles a
tile): a solid costs it one store.

`drawrect` (bank 6) draws a rectangle of map characters into the back buffer: per-rect
invariants once, one `ringaddr` for the first row, then per tile row one `mapstrip` and
one or two character rows.  A row spans at most 640 bytes, so it can cross the ring's
end only if it starts in the last three pages (`ringe3`); only then is each run
checked, and a crossing run goes a character at a time through `spnext`'s fold.
Otherwise the copy is unrolled, entered by the run's length.  A fill of a pair stores
each byte four times a character, every store setting its own Y (70 cycles a character;
alternating loads down a `dey` chain was 88).

**Mirrored tiles** (TILEMIRROR=1): another stored tile reversed left to right, drawn a
character at a time right to left with `((b & $33) << 2) | ((b & $CC) >> 2)`.  The
packer mirrors only what the bank cannot hold, the least used first; on the Model B
MIRTAB (each mirrored id's source slot) is in bank 5 beside the gather, on the Master
LV_PAGE0 names the source's slot.  With the tiles at $8600 no level needs it,
and the code and tables it takes are that room: building it moves TILES to $8700.

**The tile set.**  One set, every distinct tile any level uses, in three files cut by
who uses a tile: TILES0 the outdoor levels' alone (223 tiles), TILES1 both kinds'
(61), TILES2 the indoor levels' (106).  A file holds at most 256 tiles (16K, STAGE's
size), the tiles most levels use first.  A level stages its side's file and the shared
one in turn, and its tile list says which files and how many of its tiles each gives.

**Dirty tiles.**  A tile the logic changes is queued for both buffers (`mark_dirty`,
DIRTYMAX = 20 each: a switch marks twice its height, 18 for the tallest).  Past that the
buffer is marked invalid (BUF_CX high byte $80) and redrawn whole.

## The sprites

The sprite list (SPRLIST in low RAM: one array per field -- id, x and y in map pixels)
is built by the logic, at most MAXSPR = 24.  Each buffer keeps a record per sprite
drawn (10 bytes: id, position, the screen rectangle, whether it was clipped).
`match_sprites` marks a sprite KEEP 2 when it is the same id in the same place as the
buffer's record, 1 when it is another frame of a box star in the same place (the new
frame covers the old exactly); `erase_old` redraws the tiles under every record not
kept; `draw_sprites` draws in two passes, the box ids first (an opaque rectangle with
its background baked in would otherwise paint over what stands there), and skips a box
star the logic says nothing can disturb when it is kept identical and was not clipped
at a window edge.

`drawsprite` (bank 7) reads the directory entry (8 bytes: image address, width in
bytes, height, reference x and y, flags, lines; flags: bit 0 mirrored, bit 3 the copy
blitter, bit 4 in bank 5) and SPRMASK (the mask plane's address by id; the box ids from
BOXID0 = 103 have none), clips the sprite to the window, writes the record, notes the
mirror's columns (Model B), computes the source, mask and screen pointers and the
blitter index, and hands over through `callbank` to the row loop in the bank the image
is in.  The row loop (`SPRITE_LOOPS`) is assembled into both sprite banks, since it
reads the image bytes; `ds_entry` sets the write bank and patches its own dispatch.
Ids from BOXID0 + BOXN (118) are "nothing can disturb it" aliases of the ids BOXN
below them.

The masked blitter: a byte is two game pixels and every bit is a pixel, so there is no
room for a transparency tag and the mask is a plane of its own, one bit a game pixel,
four columns to a byte, column-group major so the mask pointer walks like the image
pointer.  MASKTAB0-3 turn a mask byte into the AND mask for the column of that phase
($FF, $CC, $33, $00) with no shifting; they are 1K aligned so the phase is the page's
low two bits, and at the same address in both sprite banks.  The two scanlines of a
pixel row share a mask, so lines go in pairs.  Mirrored images use SWAPTAB (four-dot
reversal) on both the data and the mask, and only bank 4 has it, so the packer puts
every mirrored image there.  The box stars and trampolines are opaque boxes drawn by
the copy blitter, which only bank 5 has.

The **resident block** SPRC holds what every level draws: Cleo, the boomerang, the
stars (ids 0-42, through the star's collect animation) and the trampoline.  It goes to
fixed places once (`sprc_ok`): the mirrored images and whatever bank 4 can spare beside
the largest level's mirrored enemies to bank 4 from $83AF, the rest and the
trampoline's boxes to bank 5 from $82C0.  Everything else is SPRX, one file of 12,105
bytes, from which each level takes its subset by its placement list.

## The disc

One single-sided 80-track disc, `build/cleo.ssd`, with 31 files, the DFS catalogue's
limit, in this order:

| File | What |
|---|---|
| !BOOT | `*RUN LOADER` |
| LOADER | the boot loader, both machines, at $1900 |
| BANKSB, BANKSM | each machine's fixed pieces, bank-number patch list and write-bank store list |
| LDPROGB, LDPROGM | each machine's load-time program |
| MENUB, MENUM | each machine's menu overlay |
| BAR | the bar template |
| SPRX, SPRC | the sprites: the level-placed ones, the resident block |
| TILES0, TILES1 | the tile set's outdoor and shared files |
| TITLE | the title pack |
| L0-L15 | the levels |
| TILES2 | the tile set's indoor file |

Sector numbers are baked into the game and LDPROG from `files.inc`, which `mkdfs.py
table` writes from the files' sizes; `build.sh` assembles twice so they settle and a
third time to check they have.

### Boot

LOADER runs under the MOS.  It asks the MOS its version (OSBYTE 0: 3 and up is a
Master) and chooses BANKSB or BANKSM, finds the RAM, finds the drive DFS has current
(OSGBPB 6), and the controller from the DFS ROM's version string (0.x and 1.x are
Acorn's 8271 DFSs, 2.x the 1770 one; holding W or I at boot says so instead).  It
selects MODE 1 and blacks out the palette (the ULA and the screen-size latch stay as
the MOS set them; the game reprograms only the CRTC), loads BANKS whole to $2000 with
OSFILE (through OSGBPB a byte at a time took the 1770 DFS twenty seconds), turns
interrupts off, copies the pieces to their banks and main RAM, applies the bank patches
and the write-bank stores, writes its findings to $7000-$7006 and jumps to `boot` at
$7007.  `build.sh` asserts BANKS ends below $7000.

### The game's own disc driver

After boot the MOS is abandoned: `disc.s` (bank 7) drives the 8271 or the 1770
directly.  Both raise NMI for every byte, so the transfer stubs are copied to $0D00,
where the NMI lands, for each load; each writes through a self-modified address and
keeps its state in that page, so it works whatever bank is paged.  `read_sectors`
reads a run of 256-byte sectors (10 a track) into main RAM.

- **8271**: DFS's step rate is kept, but not its motor: after an idle spell (the title)
  the head has unloaded, and a read on a stopped drive reports "not ready" at once,
  which the 8271 latches until a read-drive-status.  So each run loads the head
  (special register $23: select + load head) and reads the drive status first, as DFS
  does, and retries a run that fails.
- **1770** (the Acorn board on the Model B at $FE80/$FE84, the Master's at
  $FE24/$FE28): reset and restored to track 0 once at start-up; a seek when the head
  is elsewhere, then read-multiple, which the stub ends with a force-interrupt after
  the run's last sector.

### A level load

`level_loop` blanks the palette and calls `load_level`: `music_stop`, `load_begin`,
interrupts off, the NMI stubs to $0D00, LDPROG read to $0E00 and run (`lv_load`, X =
the level).  LDPROG runs in main RAM, where it can page any bank; it reads the socket
of every bank from PBANK and sets the write bank by PBOARD by hand.

1. The level file to STAGE_LVL.  It ends with the Master's LV_PAGE0 in two whole
   sectors; the Model B's file table reads it short of them (`LFILE`, PAGE0_SECS).
2. The header, attr and altcls to bank 7; the objects to LV_OBJS; `mapshr` = 8 - lw
   and MAPSTRIDE = 1 << lw from the header.
3. The map, run-length coded, unpacked into bank 5 at $9C00: exactly 1 << (lw + lh)
   bytes (the stream is not terminated).
4. Each of the level's tile-set files staged in turn, its full tiles copied to
   consecutive slots from TILES and its half tiles' stored rows to their slots; then
   the halves' fill pairs after them, HPAIR0/HPAIR1 patched, `halfhi` set, and on the
   Model B the gather's shape.
5. The sprites: SPRC to its fixed places if it is not resident; then SPRX staged (the
   Master: from the disc the first time, then kept in HAZEL and ANDY and restored from
   there), and every image and mask the placement list names copied to its bank and
   address.
6. The directory to SPR_TABLE and SPRMASK, both bank 7, as the packer finished them:
   no table is built at load.
7. FLATTAB to bank 6.  On the Master, LV_PAGE0 to $0400 and both screens cleared.

Back in bank 7, `load_end`, interrupts on, and `load_level` goes on from the header
(the map's size, the window's limits, the records reset).

The title's load (`title_load`, LDPROG+3) is the same machinery: the machine's menu
overlay to bank 6 at MENU_BASE ($8600), the title pack to bank 5 at $8900, the bar
template to its place.  `title_res` says whether they are still there; starting a level
clears it, and `ensure_menu` puts them back before the title or the win/lose screen.

## The level files and the packer

`tools/assets.py` (which imports `tools/convert.py` for the art and the tile packing)
packs all sixteen levels and prints a fit report.  A level file starts with a table of
14 section offsets:

| # | Section |
|---|---|
| 0 | header, 32 bytes: lw, lh, start, exit, nobj, the special tiles' ids (vanish, flower), then the tile shape (+22 mapshr, +23 the half count, +24-26 half0-2, +27 the halves' page, +28 HALFOFF, +29 mir0, +30 the mirror count) |
| 1 | the objects, 6 bytes each (at most 149) |
| 2, 3 | attr and altcls by tile id, 256 each |
| 4 | the tile list: the files, each with its full-tile count, then each full tile's index in its file |
| 5 | the sprite placement list: item, bank (4 or 5), image address, mask address; $FF |
| 6 | the map, RLE: c < 128, c+1 literals; c >= 128, the next byte c-126 times |
| 7 | FLATTAB's pairs |
| 8 | the half tiles: index in file, row, file |
| 9 | the halves' fill pairs |
| 10 | MIRTAB (TILEMIRROR) |
| 11 | the sprite directory, 118 x 8 |
| 12 | SPRMASK, 103 x 2 |
| 13 | LV_PAGE0, 512 bytes, sector aligned at the end |

It asserts the file fits the Model B's STAGE_LVL (8K, without LV_PAGE0) and the
Master's stage (20K).

The packer picks the tiles the map (and the animations) can show, merges the identical
ones, classes them full, half or flat and numbers them, and places the level's sprites
not in SPRC: box stars and trampolines in bank 5 (the copy blitter), mirrored images in
bank 4 (SWAPTAB), the rest wherever they fit, largest first, a mask always in its
image's bank; when that greedy order leaves a hole too small, it tries other orders,
deterministically.  A box star's art is chosen by its star's class (on sky, the first
six boxes; on black, the second six), not by the level's set.  MAXSPR and BINMAX are
the maxima over every level of what the walk rectangle can cover from any camera
position (24 and 18).

The sprite banks' code ends are set by hand in `assets.py` (B4_CODE_END = $83AF,
B5_CODE_END = $82C0), because the packer runs before the assembler; `engine.s` asserts
them, so the build stops if the code moves.

## The menus

`menu.s` is the overlay in bank 6: the title, help, level select and win/lose screens,
the font, and the title tune with its player.  It draws into buffer 0 with the window
at the origin, the palette black until a page is finished and flipped in.  On the
Model B the screens are laid out for its 84-pixel window.  The title pack's pieces are
drawn by `drawsprite` with `spbank` naming bank 5's socket (from PBANK: the overlay is
not patched): their directory and mask addresses come across through `dirfetch`.

The tune is stepped once a frame from the interrupt: the vsync's `sound_tick` raises
MUSTICK while MUSON is set, and the stub (the Model B's) or the handler (the Master's)
pages bank 6 and calls `music_tick`.  `music_stop` (bank 7, called by every load)
clears MUSON, so the interrupt never enters bank 6 during a level, when the overlay is
gone.

## Timing

A standard 312-line frame is 39,936 cycles at 2 MHz.  The game loop is pegged at
VSPEG = 3 vsyncs a rendered frame (16.7 Hz) on both machines, with two logic steps per
rendered frame; time lost to a long frame is dropped, not caught up, so the window never
moves more in a frame than two steps ask for.  `frame_top` is reached exactly once per
rendered frame, before the two steps read the keys: the test harness breaks there.

Per frame, bank 7 crosses once a sprite and once a tile rectangle through `callbank`,
twice into bank 6 (`selbb`, `validate`), and `drawrect` once a tile row through
`mapstrip`.

## The 6502 spellings

The engine and the logic are written once, with 65C02 idioms spelt as macros
(`cpu.inc`) that expand for the 6502.  Their contracts:

- `stz`: A is dead at the site (the 6502 form is `lda #0 / sta`); where A must
  survive, `stza`.
- `inca`/`deca`: the carry is preserved (through `mtmp`), because the sprite prologue
  relies on it.
- `ldaz`/`staz`/`andz`/`cmpz`, (zp) with no index: Y is destroyed; the site with Y
  live spells `ldazy`.
- `bitimm`: Z from A & v, A and X kept, through `mtmp`.
- `jmpx`: `jmp (abs,x)` through the zero-page vector `jv`.
- Nothing the interrupt runs may use `inca`, `deca`, `bitimm` or `ldazy` (they share
  `mtmp`).

**Anonymous labels.**  The sources use ca65's `:`/`:+`/`:-` labels heavily, and several
bare `:` lines are kept, unreferenced, only to hold the count: deleting a line that
starts with `:` retargets every `:+`/`:++` that jumps across it, and on a cold path no
test will notice.

## Testing

The tests drive jsbeeb through `test/harness.mjs`, which breaks exactly at
`frame_top` (never polling cycles, which let key timing drift with code size), and
compare a build with a reference kept by `test/snapshot.sh`.  `sh test/sweep.sh REF`
runs, in parallel:

- every level on the Master: the displayable window and the scene, 400 frames, and 200
  more after the level ends and loads again (`wincmp.mjs`);
- every level on the Model B: both buffers' 21 rows at their own windows and the bar,
  300 frames (`bwincmp.mjs`), and a level on emulated Watford and Solidisk boards
  (`BBOARD`; jsbeeb models neither, so `bopen.mjs` wraps the CPU's stores);
- the menus on both machines, frame-synchronised at `menu_keys` (`menusync.mjs`);
- the frame period through a real load from the title (`loadsync2.mjs`): every CRTC
  frame must be 312 lines, on the Master, the 8271 and the 1770.

Other tools: `bench.mjs` (the Master's render work at fixed positions, with scene
fingerprints so that only like scenes are compared; a few tens of cycles of spread is
page-crossing noise) and `benchcmp.mjs`; `bwork2.mjs` (the Model B's frame cost);
`hotvars.mjs` (every variable's accesses a frame: what zero page is worth);
`loadtime.mjs`; `tilecheck.mjs` and `btilecheck.mjs` (the drawn window against the
map's tiles, independent of the packer); `audit.mjs` (every store into sideways RAM, by
PC and bank: the sites whose write bank matters); `bboot.mjs` (the disc booted through
the title into a game, with sockets chosen by `BSWRAM`); and `test/hbeebem/`, a
headless BeebEm core that runs the Model B in lock step with jsbeeb (`bdump.mjs`) and
compares the state, the display RAM and the picture frame by frame.
