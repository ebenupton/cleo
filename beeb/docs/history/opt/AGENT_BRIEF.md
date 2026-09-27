# Brief: cheaper encodings for 65C02 windows

Work from files only. Do NOT edit any source file.

Read `build/windows/macros.txt` first: it defines add16, bge16, spnext, ringup and the
rest, which appear inside the windows. You must expand them mentally to judge cost.

## Target
65C02 on a BBC Master, not NMOS 6502. Available: `bra`, `stz`, `inc a`/`dec a`, `(zp)`
indirect with no index, `bit #imm`, `bit zp,x`, `bit abs,x`, `phx/phy/plx/ply`,
`trb/tsb`, `jmp (abs,x)`. No 65816 instructions.

## Metric
Cycles first, bytes second. Taken branch 3 (4 across a page); `(zp),y` load 5 (+1 page
cross); `sta (zp),y` 6; `abs,y` load 4 (+1); `sta abs,y` 5; zero page 3.

## Correctness rules
These are where nearly every proposed optimisation in this codebase has actually gone
wrong. Treat them as hard constraints.

1. **Flags.** If an instruction's flags are consumed after the window, the rewrite must
   leave the same flags. `bit` sets Z from (A AND operand) and N,V from the operand's
   bits 7 and 6 — *not* from A. `ldx #n` / `lda #n` set N,Z from the loaded value and
   will destroy a Z you meant to keep. `inc`/`dec` on memory set N,Z from the result.
   `sta` affects no flags.
2. **Registers.** Do not assume A, X or Y is dead at the end of a window, or free as
   scratch inside it. If your rewrite needs one, say so as an explicit assumption.
3. **Anonymous labels.** ca65 counts them: `:` as a label, referenced as `:+`, `:++`,
   `:-`. Adding or removing a `:` line silently retargets every branch counting past it.
   If your rewrite changes how many there are, flag it loudly.
4. **Signed vs unsigned.** `cmp`/`bcc` is unsigned. They are not interchangeable with
   signed comparisons.

## Scope
Local re-encodings of the instructions shown. No algorithmic redesigns. Nothing whose
correctness depends on facts not visible in the window.

## Output
A JSON array, one object per window examined:
`id`, `verdict` ("none" or "improve"), `saving_cycles` (per execution), `saving_bytes`,
`confidence` ("high"/"medium"/"low"), `assumption` (what must hold; "" if none),
`original`, `proposal`, `argument` (instruction-by-instruction, covering both
correctness and the cycle count).

**Be conservative.** Most windows have no improvement and "none" is the right answer; a
wrong suggestion costs far more than a missed one. The cost figure in each heading is a
ranking only — it double-counts macro expansions and is not a measurement.
