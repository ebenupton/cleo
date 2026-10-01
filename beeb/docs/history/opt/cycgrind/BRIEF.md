# Brief: the cycle grind

You are one of a farm of agents, each given a hot region of 6502/65C02 assembly (ca65)
from a BBC Micro game, Cleo, that runs on two machines from one source. Your job: find
every change to your region that makes the frame **faster** -- fewer CPU cycles per
rendered frame -- with **exactly the same behaviour** (the same game state and the
same pixels on screen, frame by frame, on both machines), and report each one as a
candidate. **Do NOT edit any file, and do NOT run the build** (other agents share the
tree). Read anything, grep freely: most correctness questions (is this flag used
after? is this register live? who jumps here, who patches this operand?) are answered
by reading beyond the region, and you are expected to do that.

Working directory: `/Users/ebenupton/cleo/beeb`. The engine is `beebgame/src/` (a
submodule); the game is `src/`. Read first: `beebgame/src/cpu.inc` (the CPU macros: what
each "instruction" really is on each machine) and `beebgame/src/engine/macros.s`.

## Your region

Your region file lists every line of a contiguous source range with what it costs,
measured over five levels of play: `line | Model B cycles/frame, executions/frame |
Master cycles/frame, executions/frame | source`. A line inside a macro's body counts at
both its call and its definition. Spend your effort where the cycles are: a 1% gain
on a line that costs 20K a frame beats a clever rewrite of a line that costs 20.

## The two machines

| | Model B (`BHW=1`) | Master (`BHW=0`) |
|---|---|---|
| CPU | NMOS 6502 | 65C02 |
| shared code | assembled for both | assembled for both |

- Shared code is assembled for both: a rewrite must be correct and no slower on BOTH,
  with every macro expanded for each machine. 65C02 instructions (`stz`, `bra`,
  `inc a`, `phx`, `(zp)`, `trb`, `bit #`, `jmp (abs,x)`) appear in shared code only
  as cpu.inc macros that expand to longer 6502 sequences on the Model B (`stz` =
  `lda #0 / sta`: A clobbered; `bra` = `jmp`).
- Code inside `.if BHW` / `.if .not BHW` is one machine's. Inside a Master-only guard
  write native 65C02 (`lda (zp)`, `inc a`, `stz`), not the macros.
- The machines must stay converged: they differ only in CPU spelling and hardware. A
  candidate may add a `.if .not BHW` 65C02 variant of a hot sequence where that pays.
- **The Model B matters most** (it is the slower machine), but a saving on either one
  counts provided the other is not slower.

## What counts

- **Cycles.** On every path that executes, the rewrite takes no more cycles than the
  original on both machines, and fewer on at least one path that runs. Count page
  crossings: a taken branch +1 and +1 more into another page; an indexed or
  indirect-indexed read (abs,X / abs,Y / (zp),Y) +1 when it crosses a page. Your
  saving estimate is the sum over paths of (cycles saved x executions a frame), from
  the region's annotations.
- **Bytes do matter, as a constraint.** Model B bank 7 is FULL: the game image
  (segments GAMECODE, GAMEDATA, ENGCODE; memory area B7) has 0-1 bytes spare and the
  resident kernel (KRNCODE) none. A candidate that grows those segments on the Model B
  will not build unless it also saves the bytes it spends -- say so if it does.
  Banks 4, 5, 6 (SPR4CODE, SPR5CODE, MAP5CODE, TILCODE) and the Master have room;
  low RAM (LOWCODE, main memory) ~20 bytes. Report the byte change per machine and the
  segment.
- Code only. Do not change constants, `.res` sizes, table contents or layout (a table
  moved to save a page crossing is a candidate you may propose, but say exactly what
  moves where).

## Hard constraints (where rewrites in this codebase have gone wrong)

1. **Timing-critical code: do not touch.** The interrupt chain step in
   `beebgame/src/engine/kernel.s` (`isr_body` / `irq_handler` through `@xit`, `@kend`,
   `KILLPAL`), the vsync handler up to and including its CRTC, palette and VIA writes,
   the Model B's interrupt stub in `beebgame/src/low.s` (`irq_handler` .. `irq_ret`:
   `STUBLAT` depends on its cycles), the disc driver and NMI code. Their cycle counts
   are calibrated to the 6845's character clock; faster is as wrong as slower.
2. **Flags.** Every flag consumed after your rewrite must be what it was. Carry into a
   later `adc`/`sbc` is the classic trap. The Model B expansions set flags the 65C02
   forms do not (see cpu.inc).
3. **Registers.** Never assume A, X or Y dead: prove it from the code that follows and
   from every caller, and state it.
4. **Anonymous labels.** `:` lines are referenced by counting (`:+`, `:--`). Adding or
   removing one retargets every branch that counts past it -- including `:` emitted
   inside macros (`ringup`, `spnext`, `spcold`, `pagestep`, others in macros.s). If
   your rewrite changes the count, say so in `anon_change`.
5. **Cheap labels** (`@x`) are scoped by the last normal label: adding a normal label
   ends the scope. Bank-site macros (`bankimm`, `setbank`, `BANKREF`, `wrsel`,
   `wrback`, `wrselx`, `ldpbank`) record an instruction's address for the boot loader
   to patch: do not delete, reorder or resize it.
6. **Self-modifying and patched code.** Many operands are rewritten at run time:
   `sprrow_tab` patches the sprite row loop's column `jmp`; `select_backbuf` patches
   `RINGHIOP`; the half-tile fill's `HPAIR0`/`HPAIR1` loads; `copy_partial`'s `@back`
   branch; the tile dispatch; the sprite loops' entries. Before touching any
   instruction that has a label, grep for `label+1` / `label+2` / `label-` writes.
7. **Computed entries.** Unrolled code entered at a computed offset (the tile copy
   chains, the solid chain, `copy_partial`'s pairs, the sprite cell macros, jump
   tables, `jmp (abs,x)` dispatch) breaks if an instruction inside it changes size.
   `SAMEPAGE` asserts that a hot branch and its target share a page; `PAD` lines place
   code off page crossings (pads.inc) -- leave them; the applier re-tunes the pads
   after the grind.
8. **Signed vs unsigned** compares are not interchangeable; 16-bit carries that look
   redundant are often load-bearing.
9. **Tail calls** (`jsr X / rts` -> `jmp X`): not if the `rts` is a branch target, the
   `jsr` is a recorded bank site, or X inspects the stack.

## Families worth looking for (not exhaustive)

Work hoisted out of loops; a register kept instead of reloaded; a flag or a value the
code already has (carry known clear, A already 0); a branch turned round where taken
outnumbers not taken about 4:1 (or the rare path can end in its own rts/jmp); short
constant loops unrolled; `(zp),Y` replaced by a patched `abs,Y` where the base is
fixed for a run (one cycle a read, and no page-crossing penalty to dodge); a fast path
for the common case; strength reduction; redundant `clc`/`sec`; two passes merged;
tables in place of arithmetic (banks 4-6 and the Master have the room); a 65C02 variant
on the Master (`stz`, `bra`, `inc a`, `(zp)`, `phx`) in a `.if .not BHW` block.

## Output

Return the structured result. One candidate per independent change; each one a single
contiguous line range of one file:
- `file` (as in your region header), `lo`, `hi` -- the exact source lines replaced
  (inclusive). Keep ranges tight: small, non-overlapping candidates apply independently.
- `original` -- those lines VERBATIM, exactly as in the file (no line numbers)
- `proposal` -- the replacement lines, verbatim assembly (short comments in the file's
  style)
- `saving_modelb`, `saving_master` -- estimated cycles saved a frame on each machine
- `bytes_modelb`, `bytes_master`, `segment` -- bytes added (+) or saved (-) per machine
- `assumption` -- every fact outside the range the rewrite depends on, and where you
  verified it
- `anon_change` -- "" or how the anonymous-label count changes
- `argument` -- why the behaviour is identical, path by path
- `confidence` -- high / medium / low
Report nothing you are not confident is behaviour-identical: every candidate is built
and tested against the original, frame by frame, before it is kept, and a wrong one
costs a bisection.
