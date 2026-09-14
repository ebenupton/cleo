# Plan: hardware-wrapped playfield, single-buffered status bar below $3000

Status: plan only, no code. 14 Sep 2026, after a conversation with Bitshifters
(kieran, tom_seddon, RichTW) that corrected a premise this port has carried from the
start.

## The premise that was wrong

Everything in `docs/` and the "Ring, Bar, Rupture" memo assumes the CRTC can only scan
out of `$3000-$7FFF`. It cannot see anything else *through the wrap* -- the fold is still
hard-wired from the top of screen RAM to its base -- but the start address is simply RAM
address / 8, twelve bits, and **anything below `$8000` is fair game**. The bar and the
partial row never needed to be inside the wrapped range. Put them below `$3000` and the
whole of `$3000-$7FFF` becomes one hardware-wrapped ring, which is what the Beeb wants to
do anyway.

One Master-specific catch, from tom_seddon: with shadow RAM selected for display (ACCCON
D = 1), addresses below `$3000` scan out of **HAZEL and ANDY**, not main RAM. So a bar in
main RAM at `$2B00` is only visible while D = 0. D can be switched at any point, including
mid-scanline, so the bar section simply runs with D = 0 and the playfield with D = the
buffer being shown.

## What changes

| now | proposed |
|---|---|
| ring `$3500-$7AFF`, 28 rows, software fold at the ring end | ring `$3000-$7FFF`, **32 rows**, hardware fold |
| MIRROR row at `$3280` so a straddling row reads as one run | gone: the hardware folds mid-row |
| PART row at `$3000`, fixed | partial row composed **into a spare ring row** (per buffer, free) |
| bar at `$7B00`, one per buffer, BARCACHE/BARDIRTY/BARBG per buffer | bar at **`$2B00-$2FFF` in main RAM, one copy**, drawn once |
| sections T, A, P, P2, Q -- up to 5, one IRQ each | T, A, P, Q -- up to 4 |
| `mirror_seek` per frame, `mirror_run` gating every drawrect near the ring end | gone |
| 27 visible rows (108 px) | **30 visible rows (120 px)**; 32 - 30 = 1 partial-compose row + 1 spare |

Row budget for 30 visible: bar 2 + playfield 30 = 32 displayed rows, Q 7 rows -- exactly a
standard MODE 2 frame (R6 = 32, R4 = 38). Vsync at Q row 1 keeps the existing 48-line
vsync-to-T constant. 31 visible is possible (Q = 6, vsync at Q row 0) with zero slack; not
first.

`maxwy = maph - VISLINES/2` and the rest of the camera derive from `VISLINES`, and
`ringmod` already collapses to `and #31` when `RINGROWS` is a power of two. Verify 120 px
against the J2ME reference before assuming it is the original height.

## Memory: the one real constraint

The bar needs 1280 bytes below `$3000`, and that pool is nearly full:

| region | size | used | free |
|---|---:|---:|---:|
| LOW2 `$0206` | 506 | 481 | 25 |
| TABLES `$0400` | 2304 | 2265 | 39 |
| LOW `$0D03` | 237 | 184 | 53 |
| CODE `$0E00` | 8704 | 8181 | 523 |

640 free; 1280 needed; **short by ~640**. Where it comes from, in order:

1. Deleting the mirror: `mirror_run`, `mirror_seek`, the `@rowdone` gate in `drawrect`,
   the w16/w16b borrowing in `scroll_validate`, `MIRR_R`/`MIRR_LO`. Estimate 250-300.
2. Simplifying `build_sections`: no `@addr` fold, no `@nfull` straddle arithmetic, no P2,
   SECTAB 96 -> 64. Estimate 150.
3. Single bar: `BARCACHE` 32 -> 16, `BARDIRTY`/`BARBG`/`BUF_BARQ` halve, `bar_bg`'s
   per-buffer invalidation goes. Estimate 50-80.
4. If still short: move cold CODE routines to the LOGIC bank through the existing
   bridges. Candidates in `engine.s`: `init_tables`, `init_ident`, `music_init`,
   `set_voice`, `build_tileaddr`. Not the disc loader -- it writes bank 7.
   LOGIC has 1565 bytes free.

Measure with `build/map.txt` after each step; do not guess.

## The one new race

`select_backbuf` does `lda ACCCON / ora / sta ACCCON` to set the X bit. If the section-1
IRQ fires between that load and store and writes D, the store puts the stale D back and
the playfield displays from the wrong buffer for one frame. Either bracket
`select_backbuf` with `sei`/`cli`, or keep a shadow copy of ACCCON that both writers
update and store from. Same for the flip in the vsync handler (already in an IRQ, so
only the main-code writer needs guarding).

## Bar tearing, and the answer

A single-buffered bar is drawn where it is displayed. Its 16 lines are scanned starting
48 lines after vsync, ~3 ms in. HUD draws total ~250 cycles a frame, so: **flush bar
updates at `frame_top`**, immediately after `wait_flip` returns, inside that 48-line
window. Logic sets a dirty flag; nothing in the logic phase touches the bar directly.
`BARCACHE` is then unnecessary (it existed so each buffer's copy could be brought up to
date independently).

## Staging, with the oracle at each step

The object state must be identical to `build/base` throughout stages 1-5 (nothing in the
logic changes until the height does), and `pixdiff`'s DISPLAY comparison is the oracle for
the picture once buffer addresses no longer line up.

0. **Spike, before anything else.** A throwaway program: display from `$2B00` with D=0;
   switch D mid-frame from a T1 IRQ; hardware-wrap a 20K ring from a start address in the
   last row. jsbeeb for the first and third; the D-toggle and HAZEL/ANDY behaviour need
   b2 or a real Master -- this is tom_seddon's claim about his own emulator's subject, and
   the one thing in this plan that cannot be verified from this desk.
1. Ring to 32 rows, `RINGBASE=$3000`, `RINGEND=$8000`; delete the mirror; keep
   `VISROWS=27`, keep the bar where it is (it still fits inside the ring's spare rows for
   now). DISPLAY-identical to the current build.
2. Partial row into a spare ring row; sections T/A/P/Q. DISPLAY-identical.
3. Bar to `$2B00`, single copy, D toggle, `frame_top` flush, memory moves. DISPLAY-identical
   except that the bar never tears differently.
4. `VISROWS` 27 -> 30. Audit every `VISROWS`/`VISLINES`/`RINGROWS`-derived constant,
   including sprite clip bounds and off-screen culling. Compare against the reference.
5. Follow-ons: `ringup` with `RINGEND=$8000` is a sign test (`bpl` for `cmp #$80/bcc`,
   2 cycles off every `spnext`); drop the second buffer's `PART_*` if the compose row
   makes them redundant.

## What it costs

Horizontal-scroll frames draw a column of 30 chars instead of 27 (+11% on that path);
everything else is cheaper: one fewer IRQ, no mirror upkeep (~0.6% of frame work), no
bar double-draw, no P2 arithmetic. Expect a small net win on L6 and roughly neutral
elsewhere, plus 12 more pixels of playfield.

## What happened when it was built (14 Sep 2026)

Built on branch `hwwrap` as four commits: sprite directory to bank 7; bar to `$2B00`;
hardware-wrapped 32-row ring with the mirror deleted; 29 visible rows -- then 30, once
the composed row was placed properly (below).

**29 rows, not 30 -- as first built.** The ring is char granular, so a ring *slot* is not window aligned.
The window occupies ring chars `[ringS, ringS + BUFROWS*80)`; the slot chosen for the
composed top row, `barq+31`, starts at `ringS - r + 2480` where `r = ringS mod 80`. With
30 held rows the free run is 160 chars and the slot always fits. With 31 it fits only
when `r = 0`; otherwise the composed row's first `r` chars land on the window's last
row, and when that row scrolls up into view they show as sky-coloured fragments
`8-wfine` lines tall and one dirty-column range wide. Found by stepping the first bad
frame through render_frame's phases and seeing the cells were already wrong before the
frame began -- they had scrolled in from rows a 27-row build never draws. 30 rows would
need the composed row at ring char `ringS + 2480` exactly, and a copy that folds at
`$8000` in the middle of its run (or splits into two).

**The first chain step must not touch D.** The T1 ISR re-applied `D = dispD` on every
step, and the first step fires at the *start* of the bar section. On shadow frames that
switched the CRTC to HAZEL as the bar began scanning. It showed earlier as "the bar band
differs on 104 of 200 frames", which was misread as single-buffer HUD timing; the tell was
that it was half the frames. Fixed with `cpx DISPSECT / beq` before the write.

**The original view is 108 px.** `CleoCanvas` creates a 120x128 image and reserves 20
lines of it for the HUD. So 27 rows was faithful, and 29 shows 8 px more than the phone
did. `maxwy` and the in-range distance both derive from `VISLINES`, so the world changes
with the view and object state no longer matches the pre-change builds; that is by
design, and one-line reversible (pin the two `VISLINES/2` uses to 216).

**Measured, same world, against the bar-move build:**

| | hardware ring at 27 rows | 27 -> 29 rows | net |
|---|---:|---:|---:|
| L0 jump / run | -3169 / -3793 | +2565 / +2284 | -604 / -1509 |
| L3 jump / run | -850 / -547 | +2719 / +3110 | +1869 / +2563 |
| L6 jump / run | -1190 / -2688 | +74 / +682 | -1116 / -2006 |

The ring change is a clear win everywhere. The two extra rows cost 7% more column
drawing, which is most of a frame's work on a level that scrolls sideways (L3) and
almost nothing on one that does not (L6).

**Tools that came out of it:** `tools/ringdiff.mjs` (compare what the window shows
across builds whose ring geometry differs; valid only for hardware-wrapped builds -- the
mirror build's ring tail is not what it displays), `tools/shot.mjs` (a PNG from the
harness at a frame boundary, so what is looked at is what was measured), and the
`PIXDIFF_MASK` env for retiring a region of screen RAM.

**And then 30.** The user's count was right: 30 visible + 1 straddle + 1 composed = 32,
exactly the ring, no slack needed because the composed row is rebuilt every frame. What
did not fit was my placement of it on a row-aligned *slot* while the window start is
char granular. The one free 80-char run at `BUFROWS = 31` is `[ringS + 2480, ringS +
2560)` -- the row above the window -- and that is where the composed row now lives:
column `c` at ring char `(ringS + c + 2480) mod 2560`, i.e. source + 2480, a constant
offset. Consequences, all good: it is a ring row like any other, so a horizontal scroll
leaves it valid and `copy_partial` only recomposes the dirty columns (it used to
re-source all 80 on every horizontal-scroll frame with `wfine != 0`); section A's
address is `ringS - 80`; `partq`, `PARTROW` and the `PART_CX` cache are gone. Costs:
the copy's dest can straddle `$8000`, so it folds on the page crossing like the source
-- which needed the *source* pointer to carry the `wfine` offset instead of the dest
(an offset under 8 on an 8-aligned pointer keeps page crossings on the real char
boundaries; a negative one does not), and the unrolled copy runs its line pairs in
descending order so the entry point still selects by `wfine`. `QROWS = 7`, `QVSYNC = 2`:
40 lines vsync-to-bar as before, 16 below -- the standard MODE 2 frame, 256 lines.

Verified with the logic pinned to the 29-row world: object state identical on all 8
levels, window contents identical over 30 rows (L0/L3/L6, `ringdiff`), borders dark,
bar stable, composed row correct. Cost in the same world, 29 -> 30 rows: L0 +200 jump /
+2 run, L6 +11 / +562 (L3's bench scenes no longer match). Far less than the 27 -> 29
step because the composed-row recomposition it removes was ~2000 cycles on every
horizontal-scroll frame that had a fine offset.

**Two more, found after the first 29-row build was up.**

*The first playfield scanline tore on jumps -- and the fix that was wrong.* A rupture
step is a CRTC restart: the next section's address is armed during the previous one and
latched at the boundary, and R4/R6/R7 are compared at row ends and R9 at line ends, so
nothing the CRTC needs for a section's first pixels depends on when the step ISR writes
them, provided they land after the restart. ACCCON D is the exception: it is the memory
map, sampled by every fetch, so it has to be in place *before* the restart. The ISR was
writing it ~60 cycles after, and the first third of the playfield's first line came from
the other buffer. The first "fix" was a blank row between bar and playfield so the late
switch fell in a line nobody saw -- a hack, and one that broke the title screen (a
late step painted the playfield 8:1 through the blank section's registers). The real
fix: the bar's T1 fires BARLEAD early, the ISR writes D first -- landing in the
horizontal blanking of the bar's last line -- then holds so the register writes stay on
the far side of the boundary, and the following section's duration is lengthened by
BARLEAD to end where it should. (The numbers in that sentence changed once the timing
was actually measured: next paragraph.)

*Register order, and where the step fires -- measured, this time.* The first
version of the paragraph that stood here said R4 was "compared at row ends, a whole row
away" and could go last. jsbeeb's 6845 (and the Hitachi it models) latches end-of-frame
at C0 = 1 of the scanline where row = R4 AND line = R9 -- the *start of the section's
last scanline*. For a 2-line partial (R9 = 1) that is 129 cycles after the restart, the
same deadline as Q's R6 = 0. Logged with a CRTC-write tracer (`tools`-style probe over
`session._video.crtc.write`), the chain steps were firing ~10 cycles *after* the restart
(the old "T1 lands ~5 us into T" phase), IRQ entry through the MOS added 20-36 more, and
the ISR's own preamble put the first data write at ~105 cycles in: R9 at 105, R6 at 123
(five cycles to spare -- the flicker that was chased earlier), R4 at 141. So a 2-line P2
never ended: the Q step then wrote R6 = 0 with the CRTC already on row 1, the R6 hit
never came, and the display stayed on through all of Q -- cyan in both borders on every
frame with vertical scroll ("failing to turn off the display at the end of the frame",
as the user put it, exactly).

Three changes: order R9, R4, R6, R7, R12, R13 (the three with a deadline first);
`VS2T_DEFAULT` a further 36 us earlier so every step fires ~60 cycles before its
restart; the hold after the D block lengthened to ~26 cycles so the first CRTC write
still follows the restart. Measured after: R9 lands 28-54 cycles into the first
scanline, R4 46-72, R6 64-90, with the first index write never earlier than +14. BARLEAD
drops to 10 us: it is now only the extra lead the bar's step needs over the others, so D
still lands in the bar's last-line blanking (h80-h127, t = -48..-1; measured ~ -31).
The bar's R6 stays pre-armed in the vsync handler, which costs nothing.

One thing this does not fix, and never did: a 6845 with R6 = 0 still displays the first
scanline of the frame, so Q's first line (scanline 288) shows raster 0 of whatever
Q's address points at -- the P2 row. It is one line at the bottom edge, present in every
build since the fixed bar. Blanking it would need something armed *before* the P2 -> Q
restart (R8 display-off in P2's last-line blanking), and for a 2-line P2 the previous
step's ISR is still running then; or an address whose raster-0 bytes are all zero, which
the layout does not have.

*Recentred.* `QVSYNC = 3` of Q's 8 rows: five rows between the vsync and the bar instead of
six, so the whole picture is one row higher and the bar-drawing window is 40 lines (2560
cycles).
`titlediff` reports most samples differing after this, because the painted frame moved;
`titlephase` still finds the frames identical to zero pixels at a phase offset only for
the samples taken before the game's chain is running. Check the title by eye.
