# The Model B target, and what it taught the shared code

`beeb/modelb` builds the game for a Model B with 64K of sideways RAM from the same
`src/engine.s`, `src/logic.s` and `src/game.s` as the Master, assembled with
`MODELB=1` (and `MODE1=1`).  The Master's binaries are unchanged by every conditional
in them: `build/ref_mode1` is the MODE 1 build from before the work and the build is
byte-identical to it.  `modelb/DESIGN.md` describes the target; this file is what the
exercise found about the common code and about porting it.

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
thunk, the interrupt stub, `pagelogic`, `to7`, and the entry stub, which copies
itself to the stack page first.  The Master never hits this because its engine is
in main RAM.

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
byte order had to stay.

## Verification that stands

- Master: `build/CLEO` and `build/LOGIC` byte-identical to `build/ref_mode1`.
- B logic: `modelb/tools/bdiff.mjs` -- a 21-row Master (`-D VISROWSDEF=21`,
  `build/ref_mode1_21`) and the B in lock step, all logic state compared after
  every frame.
- B rendering: `modelb/tools/bcheck2.mjs` + `bring2.py` -- ring against the map,
  mirror against the ring.
- B cost: `modelb/tools/bwork2.mjs`.
