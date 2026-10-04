# Brief: the byte grind (cycle-neutral)

You are one of a farm of agents, each given a region of 6502/65C02 assembly (ca65)
from a BBC Micro game, Cleo, that runs on two machines from one source. Your job: find
every change to your region that makes the assembled code **smaller** -- fewer bytes
-- **without costing cycles where cycles matter**, with **exactly the same behaviour**
(the same game state, the same pixels, the same menus and loads, frame by frame, on
both machines), and report each one as a candidate.

**Do NOT edit any file, and do NOT run the build or any test** (other agents share the
tree; a serial applier builds and tests every candidate later). Read anything, grep
freely: most correctness questions (is this flag used after? is this register live?
who jumps here, who patches this operand?) are answered by reading beyond the region,
and you are expected to do that.

Working directory: `/Users/ebenupton/cleo/beeb`. The engine is `beebgame/src/` (a
submodule); the game is `src/`. Read first: `beebgame/src/cpu.inc` (the CPU macros:
what each "instruction" really is on each machine) and `beebgame/src/engine/macros.s`.
Many "instructions" in the code are macros whose size differs between the machines.

## Your region

Your region file lists every line of a contiguous source range with what it costs in
play, measured over eight levels: `line | Model B cycles/frame, executions/frame |
Master cycles/frame, executions/frame | source`. A line inside a macro's body counts
at both its call and its definition. Blank columns: the line never ran during play
(menus, loads, level starts, rare paths) -- not proof that it is dead.

## The two machines

| | Model B (`BHW=1`) | Master (`BHW=0`) |
|---|---|---|
| CPU | NMOS 6502 | 65C02 |

- Shared code is assembled for both: a rewrite must be correct on BOTH, with every
  macro expanded for each machine; count bytes on each separately. 65C02 instructions
  (`stz`, `bra`, `inc a`, `phx`, `(zp)`, `trb`, `bit #`, `jmp (abs,x)`) appear in
  shared code only as cpu.inc macros that expand to longer 6502 sequences on the Model
  B (`stz m` = `lda #0 / sta m`: A clobbered, flags set; `bra` = 3-byte `jmp`).
  Replacing a `bra` with a conditional branch on a flag you can PROVE is known saves a
  byte on the Model B; `sta` alone where A is provably 0 beats `stz` there.
- Code inside `.if BHW` / `.if .not BHW` is one machine's. Inside a Master-only guard
  write native 65C02 (`lda (zp)`, `inc a`, `stz`), not the macros.
- The machines must stay converged: they differ only in CPU spelling and hardware.
- `ldprog.s` (the load-time program) and `loader.s` (the boot loader) are separate
  programs assembled per machine.

## What counts

- **Bytes**: fewer assembled bytes on at least one machine, more on neither. **The
  Model B matters most**, and within it the full places: bank 7's game image
  (segments GAMECODE, GAMEDATA, ENGCODE: 21 bytes spare) and the resident kernel
  (KRNCODE: none spare); low RAM (LOWCODE); LDPROG. The menus' image (MNUCODE,
  MUSCODE) and the Master have room, but a byte SAVED anywhere counts.
- **Cycles -- cycle-neutral**: on every line that runs in play (non-blank columns),
  the rewrite takes **no more cycles than the original on any path, on both
  machines**, counting page crossings (a taken branch +1, +1 more into another page;
  abs,X / abs,Y / (zp),Y +1 across a page). On code that never runs in play (menus,
  loader, level start, disc) a few extra cycles are acceptable where they buy bytes,
  EXCEPT in timing-critical code (below) and disc sector loops, where nothing may change.
  The applier rejects any batch whose frame totals rise on either machine.
- Code only. Do not change data tables, `.res` sizes, constants or layout. Removing
  truly dead code (provably never reached: no label referenced, no fall-through) is a
  candidate -- prove it.

## Hard constraints (where rewrites in this codebase have gone wrong)

1. **Timing-critical code: do not touch.** The interrupt chain step in
   `beebgame/src/engine/kernel.s` (`isr_body` / `irq_handler` through `@xit`, `@kend`,
   `killpal`), the vsync handler up to and including its CRTC, palette and VIA writes,
   the Model B's interrupt stub in `beebgame/src/low.s` (`irq_handler` .. `irq_ret`:
   `STUBLAT` depends on its cycles), the disc drivers, NMI code and sector loops in
   `disc.s`, any hold or delay loop. Comments with cycle counts mark such code.
2. **Flags.** Every flag consumed after your rewrite must be what it was. Carry into a
   later `adc`/`sbc` is the classic trap. `bit` sets Z from A AND operand, N/V from the
   operand. The Model B expansions set flags the 65C02 forms do not (cpu.inc).
3. **Registers.** Never assume A, X or Y dead: prove it from the code that follows and
   from EVERY caller, and state it. (An earlier grind's edit inlined an add through X
   "dead" and broke the boomerang 380 frames into a level.)
4. **Anonymous labels.** `:` lines are referenced by counting (`:+`, `:--`). Adding or
   removing one retargets every branch that counts past it -- including `:` emitted
   inside macros (`ringup`, `spnext`, `spcold`, `pagestep`, others in macros.s). If
   your rewrite changes the count, say so in `anon_change` (the applier refuses those
   unless you restructure so the count is unchanged -- prefer that).
5. **Cheap labels** (`@x`) are scoped by the last normal label: adding a normal label
   ends the scope. Bank-site macros (`bankimm`, `setbank`, `BANKREF`, `wrsel`,
   `wrback`, `wrselx`, `ldpbank`) record an instruction's address for the boot loader
   to patch: do not delete, reorder or resize the recorded instruction.
6. **Self-modifying and patched code.** Many operands are rewritten at run time
   (`sprrow_tab`, `RINGHIOP`, `HPAIR0`/`HPAIR1`, `copy_partial`'s branch, the tile
   dispatch, the sprite loops' entries, title_loop's call, operands in ldprog/loader,
   `@mt0+1` style self-patches in menu.s). Before touching any instruction that has a
   label, grep for `label+1` / `label+2` / `label-` writes, and for the harness's
   patches (test/harness.mjs, test/bopen.mjs patch title_loop and scan_keys).
7. **Computed entries and fixed addresses.** Unrolled code entered at a computed
   offset (tile copy chains, the solid chain, `copy_partial`'s pairs, sprite cell
   macros, jump tables) breaks if an instruction inside it changes size. Anything with
   `.assert * =`, `BANKENTRY`, `SAMEPAGE`, `PAD` lines (pads.inc), fixed-size copied
   segments: leave the layout alone.
8. **Signed vs unsigned** compares are not interchangeable; 16-bit carries that look
   redundant are often load-bearing (a value that reaches -1).
9. **Tail calls** (`jsr X / rts` -> `jmp X`): not if the `rts` is a branch target, the
   `jsr` is a recorded bank site, or X (or what it calls) inspects the stack.
10. **Conditional candidates**: every candidate must be correct on its own, against the
   file as it is now. Never "apply only if candidate N was not applied".

## Families worth looking for (not exhaustive)

Shared tails and exits (a sequence duplicated before two `rts`/`jmp`s); a branch over a
branch; `jmp`/`bra` replaced by a conditional branch on a provably known flag; redundant
reloads of a value a register already holds; `lda #0/sta` where a register already
holds 0; `cmp #0` after a load; `clc/adc #1` -> `inc` when the carry out is dead; cold
loops rolled up (unrolled code that never runs in play); a 16-bit op on a value whose
high byte is provably zero; a routine whose last `jsr` can fall through into its
callee (only if placement allows); a `jsr` to a two-instruction routine inlined at a
cold single call site; macro uses that expand large on the Model B where a smaller
spelling is equally valid there; tables of words where bytes suffice; duplicated cold
code merged into a subroutine (counting the jsr/rts both ways).

## Output

Return the structured result: your region id and a list of candidates. One candidate
per independent change; each a single contiguous line range of one file:
- `file` (as in your region header), `lo`, `hi` -- the exact source lines replaced
  (inclusive). Keep ranges tight: small, non-overlapping candidates apply independently.
- `original` -- those lines VERBATIM, exactly as in the file (no line numbers or
  annotation columns)
- `proposal` -- the replacement lines, verbatim assembly (short comments in the file's
  style: the code's comments explain why, in plain sentences)
- `bytes_modelb`, `bytes_master` -- bytes SAVED on each machine (positive = smaller;
  0 if none; negative only if it grows, which disqualifies it)
- `segment` -- the segment(s) affected on the Model B
- `cycles` -- the per-path comparison on both machines, e.g. "taken 7->7, fall
  through 9->8; Model B same"; for cold code say "cold: +2 on the level start"
- `assumption` -- every fact outside the range the rewrite depends on, and where you
  verified it ("A dead: both callers at frame.s:1180,1204 reload A")
- `anon_change` -- "" or how the anonymous-label count changes
- `argument` -- why the behaviour is identical, path by path
- `confidence` -- high / medium / low

**Aggressive but honest.** Find everything; report only what you believe is correct.
A wrong candidate costs a build and a bisection; a missed one costs a byte. An empty
list is a fine answer for a region with nothing in it.
