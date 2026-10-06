# Brief: the dataflow grind

You are one of a farm of agents, each given a batch of four windows of about 32
instructions of 6502/65C02 assembly (ca65) from a BBC Micro game, Cleo, that runs on two
machines from one source.  Every instruction line carries what a whole-program static
analysis (beebgame/tools/dataflow: ranges.py and dataflow.py) proved about the state
before it.  Your job: find every change to your windows that makes the code **better** --
fewer bytes, or fewer cycles where it runs in play, or both -- **worse in neither**, with
**exactly the same behaviour** (the same game state, the same pixels, the same menus and
loads, frame by frame, on both machines), and report each one as a candidate.  Lean hard
on the annotations: they make visible what the code's earlier grinds (peephole, cycle,
byte; all instruction-level, none with this analysis) could not see.

**Do NOT edit any file, and do NOT run the build or any test** (other agents share the
tree; a serial applier builds and tests every candidate later). Read anything, grep
freely: the annotations answer many questions, and the source beyond your windows answers
the rest (who jumps here, who patches this operand, what a caller expects).

Working directory: `/Users/ebenupton/cleo/beeb`. The engine is `beebgame/src/` (a
submodule); the game is `src/`. Read first: `beebgame/src/cpu.inc` (the CPU macros:
what each "instruction" really is on each machine) and `beebgame/src/engine/macros.s`.
Many "instructions" in the code are macros whose size differs between the machines.

## Your windows and the annotations

Each line: `line | Model B cycles/frame execs/frame | Master cycles/frame execs/frame |
source ;| state`.  The costs are measured in play over eight levels (blank: never ran in
the profile -- menus, loads, level starts, rare paths -- not proof the line is dead).  The
state is the Model B build's, before the instruction; an `M:` line under it gives the
Master's where it differs (or the Master's own code, inside `.if .not BHW`).  A macro line
lists each instruction it expands to as `[insn] state`, separated by `‖` (very long
expansions are cut after 24).  The notation (beebgame/tools/dataflow/README.md, "The
annotations"):

- `A=$03` one value, `A=1..4` a range, `A={0,2}` a set, `A=%xx01xxxx` known bits, `?`
  nothing known.  `A=?≡t16+1`: A equals that memory byte right now.
- `C=1` / `Z=0` / `?`: flags known or not.
- `| name=range |`: the memory operand's value range.  `[expr]=range` for indexed and
  indirect operands.
- `never` / `always` on a branch: one way is infeasible on every path the analysis knows.
- `in:AXYC out:AY`: the registers and flags live into / out of the instruction (needed by
  it or later / needed after it).  Something absent from `out:` is dead after the line.
- Names in an annotation come from the debug info's symbol for the ADDRESS, and an
  equate with the same value can be shown instead of the variable (`sta MODE1_DOTS_R` for
  a store to `rp+1` at $33).  The source is the truth for what an operand is.
- The analysis is a sound over-approximation (its assumptions: build/annotated
  summary.md's kind -- indexes taken to stay inside their `.res`, self-modified operands
  analysed as written, the interrupt's writes never tracked).  `never` and the liveness are
  reliable; `?` proves nothing.  The analysis assumes JSR targets return normally and
  callers are those it found: code entered by a computed jump, a patched operand, or the
  boot loader's patching may have callers it did not see -- check.
- **Object types** (logic.s): the analysis models the objects (OBJ_MAX records, one
  array a field, O_STAMP..O_EH, the current one indexed by Y = obj) and resolves
  process_object's dispatch by type, so a handler's lines say `ty=bat` (the object types
  that can be there) and a field read gives the range for those types only.  A value can
  be per type: `{bat:0..3 mask:$05}`.  The per-type table of every field over the whole
  game is in the record summary named in your prompt (O_TYPE's 0 there is level_init's
  clear before the record is built).  So inside a handler, facts that hold for that
  type's records (a field that is one constant for this type, a test of the type that
  cannot fail) are provable -- but a routine shared by several types (ty= lists them) must
  stay right for all of them, and a field written by level_init or another type's code
  through a different index is covered by the table, not by the line's state.
- The analysis knows nothing about TIMING: cycle-exact code is still cycle-exact (below).

What the annotations make visible, and what to hunt: branches marked `never` (dead code,
or a branch that is always taken -> fall-through rearrangement); reloads of a value a
register already holds (`≡`); a value held a few instructions earlier that a dead register
(absent from `out:`) could have carried instead of a reload or a staging store; tests the
ranges decide (a `cmp` whose outcome is fixed, an `and` that cannot change the value, a
16-bit carry that cannot happen because the low byte's range forbids it -- careful,
see below); flags already known (`clc` with C=0, `cmp #0` after a load); constants
(`lda var` where var is one known value on every path); stores of a value the byte
already holds; then the classics (shared tails, jsr/rts -> jmp, a `bra` macro (3-byte
`jmp` on the Model B) replaced by a branch on a flag known at that point).
Liveness also licenses REORDERING: an instruction moved so a flag already set serves a
later branch, a load hoisted out of a loop when its operand is not written in it.

## What counts

A candidate must be better on at least one of these and worse on none:
- **Bytes**: assembled bytes on each machine (shared code counts on both).  The Model B
  is the tight one: bank 7's game image (GAMECODE, GAMEDATA, ENGCODE) has 138 bytes
  spare, the resident kernel (KRNCODE) none, low RAM (LOWCODE) little.  A byte saved
  anywhere counts.
- **Cycles in play**: the measured columns.  A rewrite of a line that runs in play must
  take no more cycles on any path on either machine, counting page crossings (a taken
  branch +1, +1 more into another page; abs,X / abs,Y / (zp),Y +1 across a page).  Saving
  cycles on hot lines (big numbers in the cost columns) is worth as much as bytes; say how
  many cycles a frame you expect to save (cycles saved per execution x executions/frame).
  On code that never runs in play (blank columns: menus, loader, level start, disc) a
  few extra cycles are acceptable where they buy bytes, EXCEPT in timing-critical code.
The applier keeps a batch of edits only if both machines' builds are no larger, the frame
totals rise by at most 4 cycles, and one of them is better.

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
4. **No anonymous labels in code.** No `:` label and no `:+` / `:-` reference outside a
   macro's body (macros keep theirs: never add or remove one there without counting every
   reference past it).  Name every new label in code: a cheap one
   (`@name`, unique in its scope) in code.  A label you add must not end a cheap scope
   (a normal label or an equate does).
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
11. **Byte-identical layout elsewhere.** Bank 4 and 5's code must end exactly where their
   sprites start (the applier re-derives that), and data must sit at the same address on
   both machines (the build checks): a rewrite that changes size inside shared data or
   moves a `.align`ed table is rejected by the build.
12. **Ranges from the annotation are about THIS build.** A fact that holds only because of
   today's level data or a link-time address (a table page-aligned by luck, a constant
   that happens to be 0) is fragile: say so in `assumption`, and prefer facts the code
   itself guarantees (a value masked, a counter bounded by its own loop).
13. **Convergence.** The two machines run one algorithm: a new `.if BHW` is allowed only
   to spell the same thing in each CPU's instructions (cpu.inc's macros in shared code;
   native 65C02 inside a Master-only guard).  No per-machine path for speed.

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

Return the structured result: your batch id (as `region`) and a list of candidates. One candidate
per independent change; each a single contiguous line range of one file:
- `file` (as in your region header), `lo`, `hi` -- the exact source lines replaced
  (inclusive). Keep ranges tight: small, non-overlapping candidates apply independently.
- `original` -- those lines VERBATIM, exactly as in the file (no line numbers or
  annotation columns)
- `proposal` -- the replacement lines, verbatim assembly (short comments in the file's
  style: the code's comments explain why, in plain sentences)
- `bytes_modelb`, `bytes_master` -- bytes SAVED on each machine (positive = smaller;
  0 if none; negative only if it grows, which disqualifies it)
- `cycles_modelb`, `cycles_master` -- cycles a frame SAVED in play on each machine, your
  estimate from the cost columns (0 for cold code; never negative)
- `segment` -- the segment(s) affected on the Model B
- `cycles` -- the per-path comparison on both machines, e.g. "taken 7->7, fall
  through 9->8; Model B same"; for cold code say "cold: +2 on the level start"
- `assumption` -- every fact outside the range the rewrite depends on, and where you
  verified it ("A dead: both callers at frame.s:1180,1204 reload A"); cite the
  annotation (line and fact: "2210: X dead, out:AY") for every fact taken from it
- `argument` -- why the behaviour is identical, path by path
- `confidence` -- high / medium / low

**Aggressive but honest.** Find everything; report only what you believe is correct.
A wrong candidate costs a build and a bisection; a missed one costs a byte. An empty
list is a fine answer for a region with nothing in it.
