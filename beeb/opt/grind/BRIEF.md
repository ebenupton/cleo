# Brief: the byte grind

You are one of a farm of agents each given a region of 6502/65C02 assembly (ca65) from
a BBC Micro game that runs on two machines from one source. Your job: find every
place where **a 32-instruction contiguous block can be implemented in fewer bytes
without costing cycles**, and report each one as a candidate. Do NOT edit any source
file. You may read any file in the repository and grep freely: most correctness
questions (is this flag used afterwards? is this register live? who jumps here?) are
answered by reading past the window, and you are expected to do that.

Working directory: `/Users/ebenupton/cleo/beeb`. Read first:
- `build/grind/macros.txt` -- `src/cpu.inc` in full, then every macro in the sources.
  Many "instructions" in the code are macros whose size differs between the targets.
- `build/grind/SPACE.md` -- how full each segment is. Model B bank 7 (segment LGCCODE and
  friends, memory area B7) is FULL: it is the reason for this grind.

## The two targets

| | Master | Model B |
|---|---|---|
| CPU | 65C02 (`ca65 --cpu 65C02`) | NMOS 6502 (`--cpu 6502`, `-D MODELB=1`) |
| files | `src/*.s` (`src/main.s` includes them) | `modelb/src/main.s` includes `src/engine.s`, `logic.s`, `game.s`, `menu.s` AND its own `modelb/src/*.s` |
| stand-alone | -- | `modelb/src/ldprog.s` and `loader.s` are separate 6502 programs |

**Shared code (`src/*.s`) is assembled for both.** In it, 65C02-only instructions
(`stz`, `bra`, `inc a`/`dec a`, `phx/phy/plx/ply`, `trb/tsb`, `(zp)` without index,
`bit #imm`, `bit zp,x`/`abs,x`, `jmp (abs,x)`) may appear only because `cpu.inc` defines
macros of those names that expand to 6502 sequences under MODELB -- e.g. `bra` becomes a
3-byte `jmp`, `stz m` becomes `lda #0 / sta m` (A destroyed; flags set), `stza` saves A
round it, `inca` preserves carry through `mtmp`. So:
- A rewrite in shared code must be correct and no slower on BOTH, expanded through the
  macros. Count bytes on both targets separately.
- Code inside `.if MODELB` / `.if .not MODELB` / `.if ::MODELB` belongs to one target.
- `PLACE "A", "B"` puts the code in segment A on the Master and B on the Model B.
- A `bra` in shared code is 3 bytes on the Model B: replacing it with a conditional
  branch on a flag you can PROVE is known (2 bytes, 3 cycles taken) saves a byte there.
- `stz` (macro) on the Model B is 5 bytes when A is dead; if A already holds 0 at the
  site, `sta` alone is 3 (2 for zp). Such facts are target-specific wins.

## What counts

- **Bytes**: fewer assembled bytes on at least one target, more on neither. **The Model
  B matters most**, and within it the banks that are full (bank 7: LGCCODE, LGCLO,
  LGCDATA; bank 5's B5X: TILCODE; low RAM LOWCODE). Master-only savings count too.
- **Cycles**: on EVERY path through the window that can execute, the rewrite takes no
  more cycles than the original, on both targets, ignoring +1 page-crossing effects.
  Faster is fine -- EXCEPT in timing-critical code (below), where it must be exact.
- Code only. Do not change data tables, `.res` sizes, constants or layout.

## Hard constraints (where rewrites in this codebase have actually gone wrong)

1. **Flags.** Any flag consumed after your rewrite must be what it was. `bit` sets Z
   from A AND operand, N/V from the operand. Loads, `inx`, `inc m` set N,Z. The MODELB
   expansions of `stz`/`inca`/etc. set flags the 65C02 forms do not (see cpu.inc's
   contracts). Carry into an `adc`/`sbc` further on is the classic trap.
2. **Registers.** Never assume A, X or Y dead or free: prove it from the code (read the
   callers / what follows), and state it as the assumption.
3. **Anonymous labels.** `:` lines are referenced by counting (`:+`, `:++`, `:-`).
   Adding or removing one retargets every branch counting past it -- INCLUDING `:`
   emitted inside macros (`ringup`, `spnext`, `ringmod7`, others: check macros.txt).
   If your rewrite changes the count, say so in `anon_change`.
4. **Cheap labels** `@x` are scoped by the last normal label. Adding a normal label ends
   the scope. Bank-site macros (`bankimm`, `setbank`, `BANKREF`, `wrsel`, `wrselx`,
   `ldpbank`, `farjsr`) record the address of an instruction for the boot loader to
   patch: do not delete, reorder or change the size of the recorded instruction.
5. **Self-modifying and patched code.** Before touching an instruction that has a
   label, grep for `label+1` / `label+2` writes: operands are rewritten at runtime
   (`nmi_sta`, `ds_dispatch`, `jmp sprFN`, the NMI stubs in disc.s, operands the
   loader patches). Code that is copied elsewhere (segments LOW, LOW2, LOWCODE,
   NMISTUB, TILLOW, the ldprog/loader images) often has `.assert`ed sizes or offsets.
6. **Computed entry points and tables of code.** Unrolled loops entered at a computed
   offset (the tile row copy entered by `wfine`, the sprite row loops, SPRITE_LOOPS,
   jump tables, `jmpx`, far tables at fixed addresses) break if an instruction inside
   them changes size. Anything assembled at a fixed address (`.assert * =`, BANKENTRY,
   FARTAB, COMMON_TABLES) must stay put.
7. **Timing-critical code: cycle-exact, not "no slower".** The rupture chain step in
   `src/engine.s` irq_handler (`@t1arm` to its `rti`) and `modelb/src/display.s`
   `isr_body`'s `@t1` path, the vsync handler up to and including its T1 restart and
   CRTC writes, `ldstop5`, any hold/delay loop, the NMI/FDC handlers and the disc sector
   loops: do not propose anything there that changes a single cycle before the last
   hardware write. Comments with cycle counts mark such code.
8. **Signed vs unsigned** compares are not interchangeable. 16-bit carries that look
   redundant are often load-bearing (a value that reaches -1).
9. **Tail calls.** `jsr X / rts` -> `jmp X` saves a byte and cycles, but not if X (or
   anything it calls) inspects the stack (`farcall` does `tsx` / `$0106,x`), or if the
   `rts` is a branch target, or if the `jsr` is a recorded bank site.

## Useful families of saving (not exhaustive)

Shared tails and exits (a sequence duplicated before two `rts`), a branch over a
branch, `jmp` to a nearby target when a flag is provably known, redundant reloads of a
register that already holds the value, `lda #0/sta` where A or X or Y already holds 0,
`cmp #0` after a load, `clc/adc #1` -> `inc` when A's value and the carry are not
needed, loops rolled where they are not hot, a 16-bit op on a value whose high byte is
provably zero, a routine whose last `jsr` can fall through into its callee, macro uses
that expand large on the Model B where a smaller spelling is equally valid there.

## Coverage

Your region lists every instruction with an index `[iNNNN]`. The windows you own are
the 32-instruction blocks starting at each index in your header's range. Examine them
all; a saving that spans two windows is reported once, with the lowest start index.
Report `windows_examined` as the range you actually covered.

## Output

Return the structured result. Each candidate:
- `window` -- the start index (e.g. `i1283`) of the lowest window containing it
- `file`, `lo`, `hi` -- the exact source line range replaced (inclusive)
- `original` -- those lines VERBATIM from the file (without the line/index columns)
- `proposal` -- the replacement lines, verbatim assembly (keep comments short)
- `bytes_master`, `bytes_modelb` -- bytes saved on each target (0 if none, negative if
  it grows; neither may be negative in an accepted candidate)
- `cycles` -- per-path cycle comparison on both targets, e.g. "taken path 7->7, fall
  through 9->8; Model B same"
- `assumption` -- every fact outside the window the rewrite depends on, with where you
  verified it ("A dead: both callers at engine.s:1180,1204 reload A")
- `anon_change` -- "" or a description of the anonymous-label count change
- `argument` -- instruction-by-instruction equivalence
- `confidence` -- high / medium / low

Also Write the same JSON object to `build/grind/out/<region>.cand.json`.

**Aggressive but honest.** Find everything; report only what you believe is correct.
A wrong candidate costs a build and a bisection; a missed one costs a byte.
