# The Model B target, and what it taught the shared code

`beeb/modelb` builds the whole game for a Model B with 64K of sideways RAM from the
same `src/engine.s`, `src/logic.s`, `src/game.s` and `src/menu.s` as the Master,
assembled with `MODELB=1` (and `MODE1=1`): every level is gathered from the disc by
the game's own loader, the menus live in an overlay over the tiles.  The Master's
behaviour is unchanged by every conditional in them (the one-level demo's build was
byte-identical to `build/ref_mode1`; the full game's shared edits -- a branch made a
jump in menu.s, the sound write as a macro -- move bytes but not behaviour, and the
lock-step test is against the logic, not the bytes).  `modelb/DESIGN.md` describes
the target; `docs/PLAN_MODELB_FULL.md` the plan it was built to; this file is what
the exercise found about the common code and about porting it.

## Lessons for the common code

**Macro side effects are the whole risk of a 6502 build.**  Every 65C02 spelling the
Master uses is a macro (`src/cpu.inc`), and each 6502 expansion has an effect the
real instruction does not: `stz` goes through A, `inca`/`deca` through the carry
(`clc/adc #1`), `ldaz` through Y, `bit #` does not exist.  The previous port found
four of these the hard way (every object's type landing on object 0; sprite records
a row short).  `tools/flagscan.py` finds them by reading: for every site it walks
forward through the source, following branches, until the affected register or
flag is redefined, and reports a consumer reached first.  It found the two `stz`
sites with A live (`logic.s` @full's `stz dpx+1` under `sbc dpx`), the two `deca`/
`inca` sites in the sprite prologue whose carry feeds an `adc`/`sbc`, and the one
`ldaz` with Y live.  The contracts in cpu.inc are now: `stz` = A dead, `stza` = A
kept, `inca`/`deca` keep the carry (through a zero-page byte), `ldaz` destroys Y,
`ldazy` keeps it, `bitimm` keeps A.  Run flagscan after any change that adds one.

**Zero-index indirects were spelled three ways.**  `cmp (rp)`, `lda (w16)`,
`lda (SFXPTR)` sat in the source as raw 65C02 instructions beside the `ldaz`
macro.  All are macros now (`cmpz`, `ldaz`); the assembler with `--cpu 6502`
rejects any that come back.

**ca65 scopes do not see globals in `.if`.**  A macro expanded inside a `.scope`
(the sprite row loop, assembled once per sprite bank) cannot test `MODE1`: the
symbol is taken as a not-yet-defined scope local and the `.if` fails as
non-constant.  Inside such macros the globals are written `::MODE1`, `::MODELB`.
Zero-page symbols resolve correctly inside scopes (the addressing mode stays zp).

**A bank cannot page itself out and carry on.**  The instruction after `sta $FE30`
is read from the new bank.  Every switch on the B runs from main RAM: the far-call
thunk, the interrupt stub, `pagelogic`, the two start-up stubs (which copy themselves
to the stack page first), and the load-time program, which lives in display RAM
while the palette is black.  The Master never hits this because its engine is in
main RAM.

**A routine the logic calls keeps X.**  The Master's `maprow` is a table lookup
through Y; the B's is arithmetic, and its first version counted the shift in X.
The logic has object indices live across it, so a level started with the wrong
objects awake.  Lock step found it in a frame; nothing else would have.

**A loop's flags are the loop's.**  The RLE decoder tested the control byte's sign
after a `jsr` that stepped the pointer with `inc`, which sets N from the pointer.
Literal runs came out as repeats; the outdoor maps, which are mostly runs, looked
right.  The ring check cannot see this (it compares the ring against the same
decoded map); the byte-for-byte check of the banks against the packer's data
(`tools/bcheck2.mjs` dumps them) can, and lock step did.

**Anonymous labels count.**  Adding a `:` inside an `.if MODELB` block shifts every
`:+`/`:-` that spans it on that target only; the byte-identity check on the Master
does not see it.  The MODELB blocks use cheap locals (`@nomir`, `@loop6`).

**`ringup` names its pointer.**  The Master's fold touches only the high byte
because its ring is whole pages; a 23-row ring is not, so the macro takes the
pointer and folds both bytes on the B.  The Master's expansion is unchanged.

**Where the Master's tables live was the design decision.**  With 30K of the 32K as
display, the main-RAM tables the Master's engine reads from anywhere (records,
KEEP, the dirty lists, BUF_*, PART_*) had to become bank RAM owned by the code that
uses them most.  Bank 5 (the tile blitter) owns them all, so the only per-sprite
crossing is the prologue's far call into the bank that holds the image.  The
sprite list stays in low RAM because the logic fills it 24 times a step.

**The level's sprites do not fit one bank.**  L1B's 61 images with masks are 17.9K;
beside the row loop and its 1.25K of mask tables that is two banks' worth, which the
Master's own directory flag `$10` (bank 6) already provides for.  The packer puts
the box stars and every never-mirrored image in bank 6, so bank 6's copy of the row
loop has no mirrored blitter and no SWAPTAB (`SPRITE_LOOPS 0, 1`), and bank 4's has
no copy blitter (`SPRITE_LOOPS 1, 0`).

**The previous port's own blitter was slower than the Master's.**  Its frame was
136k cycles median; the Master's drawrect, gather, KEEP and copy_partial on the
same machine, with the map fetched a tile row at a time through main RAM, are 63-70k.
Far calls are ~4 a frame.  The lesson for the Master: none of its hot code needed
touching to run on a 6502 in a quarter of the RAM -- the structure (per-rect
invariants, the gather, char-granular rectangles, records) carried over unchanged.

**`music_tab` is a copy of the data.**  On the B the player lives beside the data,
so `MUSIC_TAB = MUSIC_ADDR` and `music_init` is an `rts`; the Master copies because
its player is in main RAM and the data in a bank.  Worth remembering if the
Master's music ever moves.

**The Master's file table is data in `game.s`** under `.if .not MODELB`, because
`load_level` and the game loop that the B shares sat either side of it and the
byte order had to stay.  The B's own sector table is in its load-time program
(`ldprog.s`), generated the same way (`mkdfs.py table`).

**Nothing the Master shows is folded away.**  The first full-game build folded a few
tiles on the big outdoor levels to fit a bank that also held the blitter and the
prologue.  Wrong trade: the tiles are the picture.  Bank 5 is nearly all tiles now
(L4B fills it to the byte), the code around them went to bank 7 and to main RAM,
and a display row paid for the main RAM -- 22 ring slots, 20 visible, which also
makes the rings whole pages and the fold a byte compare again.  (Bought back the
same day, below.)

**The row came back once the tiles shrank.**  Half and flat tiles freed 2.5K of bank
5 on L4B; the 1.1K of code and state that had sat in main RAM went above the tiles
with the row loop (bank 5, from $B620), the small of it bank 7 must read (the
records' matcher and eraser, sext, sprmul5, the row multiples, a second mirdirty)
into bank 7, and the five bytes of state both read into low BSS.  Three far calls a
frame plus one per erased rect, drawn sprite and changed tile: +4% on the frame.
Two ways it bit: a scan of who uses what counted a macro's text, not its
expansions, so bank 7's calc_ring lost its ring-modulus table (whole rows landed in
the wrong slot); and the boot loader's piece table still loaded bank 5's code at
its old address (the first jsr into it went to $0000).  The half tiles had to give
up their page alignment for L4B to fit: they follow the full tiles at once, and the
gather counts slots from the page they start in.  Grinding the crossings after --
bank 7's own arithmetic ringaddr, a direct-switch thunk with a common entry vector
at $BFFD in banks 4/5/6 for the sprite loop and the erased rect, mapstrip paging
bank 5 back outright -- took the far calls a frame from 19 to 3 and the frame from
99.5k to 98.7k cycles: the thunk was never the cost, the drawing is.  And a check that
reads its expectation from the thing it checks proves nothing: the loader still
copied FLATTAB into bank 7 after the table moved to bank 5, the sky was black, and
the ring check read the zeroed table from bank 5 and agreed with the zeroed ring.
The screenshot caught it; bring2 now asserts the two solid pairs.

**The 8271 latches "not ready".**  The title's idle let the controller unload the
head (DFS's specify says after a few index pulses), so the level's first read came
back $10 at once -- and every retry after it, for ever: the ready bits in the drive
input register are latched low and only a *read drive status* reloads them.  A read
on a stopped drive does not start it either.  DFS's cure is the driver's now: write
special register $23 (select + load head: the motor), read drive status (an
immediate command -- poll busy and read the result; it raises no interrupt), then
read.  The harness never saw it because it patches the title out and loads the level
while the drive is still spinning from the boot.

**The interrupt stub stepped the tune per interrupt, not per frame.**  Six T1 rupture
steps a frame come through the same stub as the vsync; the tune ran five times too
fast.  The vsync's sound_tick raises a flag the stub takes once.

**Nothing is a picture until the title.**  The boot loader selects MODE 1 and then
OSFILE-loads BANKS into what is now screen memory with the MOS palette live: the
whole load showed.  Black first, in the loader and again at the game's start.

**A merge is only lossless if the game agrees.**  Two tiles with identical bytes can
differ in the attribute and altitude class the logic reads by id; merging them on
pixels alone put a wall's altitude on a floor and lock step diverged in eight
frames.  The screen check cannot see this class of error; the lock-step test can.

**Half tiles.**  A stored tile with one char row that is a fill, or equal to the
other, keeps only the other row: 32 bytes and a pair.  26-34 tiles on every big
level, so L4B stores 12.4K for the Master's 14.9K, and the run path pays ~10 cycles
a run to tell them apart (L4B 92k -> 96k cycles a frame).  Two of the three bugs
it took were the loader's: a loop that stepped by two and counted by one, and a
header read after paging the bank it was to be written to.

**Flat tiles are two bytes.**  Commando's `drawfill`, read across from the other
port: a tile that is one colour's dither is, in MODE 1, the same two bytes down
every char, so it is an id and a pair in a table, and the row loop fills a run of
them instead of copying 64 bytes.  Cleo's art is textured, so it is only five to
seven tiles a level (~400 bytes of bank 5), but it is lossless and the check tools
(`bring2.py`) render from the pair table too.  The other Commando ideas were
measured and left: a flip bit per cell would flip the ordered dither's phase
against the neighbours (zero of Cleo's tiles are exact mirrors of another once
dithered, 11-17 are at the source-art level); its 4-bit palette-indexed sprites
would free ~8-10K of the sprite banks, which is not where the pressure is.

**A whole-span clear must know about holes.**  (Moot since the holes went.)  The menus' `clear_ring` swept the
display from the bar to the ring end; with the ring tables and the buffers' state
living in two holes inside that span, the title piece was drawn through a zeroed
row table straight into zero page ($F4 among the victims).  Anything that walks
the display as one run needs the layout, not the bounds.

**A staging area and a destination can overlap in time.**  The level file staged at
$6000 ran past $7800, where its own objects were copied while its map, at the end of
the file, was still to be decoded: the last two rows of L4B's map were garbage, and
lock step passed because the player never reached them.  The byte-for-byte compare
of the banks against the packer's data caught it; the file is staged lower now and
the packer asserts the bound.

**The menus assume the Master's window.**  `clear_items` cleared ring rows to 27
through RINGLO/HI, tables 23 entries long on the B: the stores landed on zero page,
one of them on the ROMSEL copy.  The screens' y positions assume 108 px of window;
the B has 84.  Both are `.if MODELB` in menu.s now; the lesson is that "the same
sources" includes the parts that were never assembled for the other target.

**The banks are wherever the RAM is.**  The first report from a real machine was
"no joy": its sideways RAM sat in even sockets, and the loader wrote banks 4..7
blind.  Now it probes (the sideways RAM Elite loader's test: flip a bit of $8006
and see if it stuck), classes the banks, drops aliases by signature, takes the lowest
four, and explains itself when it cannot.  The game's bank numbers are patched at
boot from a list the assembler makes (`bankimm`, `setbank`, `BANKREF` in cpu.inc,
which need the bank the code is in: get it wrong and build.sh's check against the
pieces catches most of it, and a run with `BSWRAM=8,9,10,11` catches the rest); what
loads later reads PBANK.  Two ca65 facts cost an hour: 2.18 has no `.bank()`, and
*any* symbol definition -- `.local`, `=`, `.set`, a generated name -- ends the
enclosing `@` label scope, so the only marker a macro can plant in someone else's
routine is a cheap label of its own, named to be unique (`@bf_lda_7`; a clash is
a duplicate-symbol error, never a silent miss).  jsbeeb's Model B has RAM in
sockets 0-7, so even the default emulator run now exercises the remap (the game
lands in 0-3); the tools take the code's bank numbers and map them.

**The write bank is not the read bank on every board.**  Solidisk and Watford
sideways RAM take the bank a store reaches from a register of their own (the user
port; $FF30 + bank), so the socket probe alone left them out.  Supporting them meant
a companion store after every switch a bank store may follow -- about 135 a frame,
found by tools/audit.mjs, in all four banks: the blitters' state, the logic's, the
sprite loops' patched operands -- and low RAM, where the hot switches live, had three
bytes.  Two wrong turns first: companions at every switch overflowed it by ten bytes;
parking pagelogic in the bottom of the stack page to make room put it under the
stack, which wrapped and wrote MUSON at $01FF, and the tune's player ran into an
overlay the test harness never loads.  The way through: the write-select register
changes nothing readable, so the companion can live in the bank the switch ENTERS --
the sprite loops' entry, a stub before drawrect_clip, the line after `jsr mapstrip`
-- and only what returns to a caller (pagelogic, fcret, the interrupt's exit) needs
low RAM.  Disc-loaded code (the overlay's music_tick, ldprog) cannot be patched and
reads the board byte instead.  The probe has to pick the board by how MANY banks each
way finds: a board's latch rests on bank 0, so writing through ROMSEL "works" for
that one bank.  Never put code in the stack page.

## Verification that stands

- B logic: `modelb/tools/bdiff.mjs frames seed level` -- a 20-row Master
  (`VISROWSDEF=20`, `build/ref_mode1_20`) and the B in lock step, all logic
  state compared after every frame; `BMODEL=B1770` for the 1770 machine.  600
  frames on L0B (8271), L1B (1770), L7B, L4B (1770) and 400 on L0A at the time
  of writing.
- B loading: `modelb/tools/bcheck2.mjs` dumps the level's tiles and map from the
  banks (compared against the packer's files), `bring2.py` the ring against them
  and the mirror against the ring; a scratch script compared every placed image,
  mask, directory entry and SPRMASK entry against the shared files: all exact.
- B cost: `modelb/tools/bwork2.mjs frames seed level`: L0B median 77k cycles a
  frame, p90 146k; L4B 92k / 154k (11-13 far calls a frame).
- Both controllers and both drives boot to the title under jsbeeb (`bboot.mjs`).
