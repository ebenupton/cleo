# Memo: what the SAS audit means for Cleo

The SAS port shares Cleo's engine, macros and coding habits. Auditing SAS's logic
against its Java (by review and then by running a Python transcription of the Java in
lockstep with the 6502) turned up bugs that were invisible in play, and two of them are
present in Cleo's sources today. Paths below are in the Cleo repository.

## 1. Two defects Cleo has right now

### 1.1 Branch macros with an anonymous label: ten silent no-ops in `logic.s`

`bgt16`, `blt16`, `bge16`, `bgt16i`, `blt16i`, `bge16i`, `ble16i` (and `sx16`,
`submin0`, `spnext`, `SPRFULL/SPRHALF`) expand to code that contains an anonymous `:`
label:

```
.macro bgt16 aa, bb, label
        jsr cmp16_s
        .byte bb, aa
        bpl :+
        jmp label
:
.endmacro
```

Two consequences. First, a call whose *target* is written as `:+` — `bgt16 ox, px, :+`
— makes `jmp label` jump to the macro's own `:`, i.e. the branch is never taken and the
test is dead code. Second, any `bmi :+`/`bne :+` written before such a macro resolves to
the macro's internal label rather than the one the author meant. Cleo has no case of the
second kind, but ten of the first, all in the object handlers (`beeb/src/logic.s`):

| line | routine | what the dead test was for |
|---|---|---|
| 2174 | `@boom` | pick the death direction from `ox > px`: always takes the second |
| 2212 | `@fr` | flip the frame when the object faces the player: never flips |
| 2225 | `@knocked` | `fc > -256` gate: always jumps to `@done`, the block below never runs |
| 2236 | `@knocked` | sprite 54/55 by facing: always 54 |
| 2293 | `ob_bat` | `fc < fa` → `inc fc`: the bat's x drift only ever decrements |
| 2307 | `ob_bat` | `fd < fb` → `inc fd`: same for y |
| 2374 | bat sprite | facing flip: never |
| 2426 | `@dead` | `fd < fb+256` gate: always `@done`, the `add16i fa, 120` path never runs |
| 2442 | `@dead` | sprite 65/66 by facing: always 65 |
| 2505 | `@boom` | `fb < fa` → `stz fc`: never clears |

The fix that worked in SAS: give the macros no label at all, branching over the 3-byte
`jmp` with `*+5`:

```
.macro bgt16 aa, bb, label
        jsr cmp16_s
        .byte bb, aa
        bpl *+5
        jmp label
.endmacro
```

(`.local` labels inside the macro do *not* work: a non-cheap label ends the caller's
`@label` scope and every `@done` after a macro call becomes undefined.) After the change
the ten sites do what they say, which will change behaviour — retest bats, knockback
and the death animations rather than assuming the old behaviour was right.

Check with:
```
python3 - <<'EOF'
import re,glob
m=set()
for f in glob.glob('beeb/src/*.s'):
    for x in re.finditer(r'^\.macro (\w+)(.*?)^\.endmacro', open(f).read(), re.M|re.S):
        if re.search(r'^\s*:', x.group(2), re.M): m.add(x.group(1))
for f in glob.glob('beeb/src/*.s'):
    for i,l in enumerate(open(f)):
        w=l.split(';')[0].split()
        if w and w[0] in m and re.search(r',\s*:[+-]\s*$', l.split(';')[0]): print(f, i+1, l.strip())
EOF
```

### 1.2 Fixed-step catch-up runaway in `main.s`

```
        lda vsyncs
        sec
        sbc logicvs
        lsr
        beq @wait
        cmp #3
        bcc :+
        lda #3
:       sta lsteps
        asl
        clc
        adc logicvs
        sta logicvs
```

When a render takes longer than six vsyncs the loop runs the maximum three steps but
adds only six to `logicvs`, so the deficit is carried forward for ever: every later
frame also runs three steps and the game runs at 3 steps per render — up to 60% faster
than 25 Hz during any busy stretch, and it never recovers. SAS measured 40 steps/s
against a 25 Hz design before the fix. Drop the lost time when capping:

```
        cmp #3
        bcc :+
        lda #3
        sta lsteps
        lda vsyncs
        sta logicvs
        bra @steps
:       sta lsteps
        asl
        clc
        adc logicvs
        sta logicvs
```

## 2. Patterns worth a targeted audit (found in SAS, not yet checked in Cleo)

Each of these was a silent bug in SAS with the same coding conventions; Cleo's
`engine.s` alone has 19 `sta t16`/`sta ptr` scratch uses.

- **Inline `mov16` leaves the high byte in A.** Any helper that receives a value in A
  and does `mov16` before storing A loses it (`ratio_lt` and the `mulsign_*` helpers in
  SAS: every 24-direction aim was wrong). Grep for `mov16` followed within a few lines
  by `sta`/`cmp`/`bpl`/`bmi` that still expects the entry A.
- **Pointer helpers that use t16/t16b as scratch while the caller passes a value in
  them.** SAS's `bullet_ptr` did `sta t16` for the slot index, and the bullet's x
  velocity (passed in t16) got its low byte replaced by the slot number — every bullet
  in the game. Check Cleo's record-pointer helpers (object/boomerang) against what their
  callers keep in t16/t16b/ptr.
- **Accumulators clobbered by a callee.** `getheight` summed into t16 while `colquad`
  used t16 as scratch, so bullets never hit roofs. Any loop that accumulates across a
  `jsr` to a helper should own its variable.
- **Loop pointers reused by a callee.** `boxtest` used t16b, the pointer of the object
  loop in `issolid` that called it; after the first box test the scan walked garbage
  and found a phantom object. Check `getinfo`/`getaltitude`-style helpers against the
  loops that call them.
- **Loop state kept in q1..q6 across handler calls.** `update_objects` kept its bucket
  window in q1..q4; the first handler that touched a q variable corrupted the test for
  every later object. Keep loop state in dedicated variables; treat q1..q6 as dead after
  any `jsr` into a handler.
- **8-bit clamps on unsigned tile coordinates.** `bpl`-based negative tests on tile
  coordinates treat 128..255 as negative; SAS's 256-wide maps lost every object beyond
  x=127. Cleo's 256×32 worlds have the same exposure in any box/bucket arithmetic.
- **Overlay code must not page banks under itself.** Every call from an overlay into a
  routine that switches ROMSEL needs a `FARSTUB`; the loader only loads at page
  boundaries (a table at $B8D8 silently landed at $B800).

## 3. The method, if you want the same certainty for Cleo

Reading found some of the above; the lockstep found the rest in minutes each. Tools are
in `beeb/tools/` of the SAS repository and need only the label names and record layouts
changed:

1. `javasim.py` — a literal transcription of `run()` and its helpers (Java int
   semantics kept: helper functions for `/` and `%`, `(byte)` casts) using the 6502's
   16-bit LFSR as `rnd8()` in place of `java.util.Random`, one call per `nextInt()`.
   Cleo's decompiled `CleoApp.java` is the input; an agent produced SAS's 2400-line
   transcription in one pass and it was correct first time.
2. `lockstep.mjs` — headless jsbeeb; at every `game_frame` entry it pokes the frame's
   key mask (after patching `scan_keys` to `rts`), seeds `seed`, and dumps zero page
   and the object/bullet/effect records; optional forced-objective events.
3. `simrun.py` + `lockcmp.py` — run the transcription on the same script and report
   the first step at which each field differs (with normalisation of fields the Java
   lets go negative).
4. `pathfind.py`/`bot.py` — A* on the player's own movement lattice using the
   transcription's `isSolid`, and a bot that walks mission to mission, shoots what
   comes near, and forces objectives that don't complete by touch (map edits on
   completion are reproduced on both sides at the same frame).

The comparison is exact: after the fixes SAS's 6502 and the Java agree on every player,
object, rogue, bullet, effect and RNG field for thousands of frames. The window sizes
matter for parity — the phone's 176×192 screen decides object activation and
off-screen despawn, so the port pads its bucket window vertically and uses the
unrounded camera x (the display scrolls by 2 px) for those tests.

## 4. Performance: what the profiles said

Measured with `tools/phase.mjs` (inclusive cycles per routine over a 1-second window)
and `tools/profile.mjs` (self time per label, call counts, and `RANGE=a-b` for the hot
instructions of one routine) on the shared engine, 2 MHz, 25 Hz logic. One caveat that
cost an hour: with several overlays at $8000 the label lookup is ambiguous, so a profile
line for a $8xxx routine may belong to a different overlay — filter on ROMSEL when it
matters. The numbers, and what they imply for Cleo:

| item | cost | note |
|---|---|---|
| logic step | 30–35 k cycles | 40–45% of the CPU at 25 Hz before rendering anything |
| 16-bit helper macros (`add16i_s`, `cmp16_s`, `sx16_s`…) | ~100 cycles each, 7–8% of the CPU | inline operands after the `jsr` are elegant but each costs a return-address fetch; the six hottest are worth inlining if code space allows |
| `issolid` | 7 k → 5.4 k | resolving the map-row pointers once per row instead of per quad; the object-box loop is the rest |
| scroll strip, 1 char × 28 rows | ~18 k | `drawrect` spends ~600 cycles of setup per row (map row, flip row, gather, ring address) for an 8-byte copy; a narrow-strip special case that does the per-row work once per *tile* row would roughly halve walking cost — this is the same code in Cleo |
| erase of a 160×8 px sprite (text line) | ~25 k | 160 char cells through `drawrect_clip` |
| transparent text line draw | ~45 k | 80 columns × 2–3 chunks; the per-chunk pointer setup and `jsr/jmp/rts` are half of it |
| opaque band draw | ~30 k, no erase on horizontal scroll | see §5 |
| sprite decode (SAS only) | 35–45 k per soldier frame | the dither loop is ~150 cycles per packed pair; Cleo pre-dithers and avoids this entirely |
| cache compaction (SAS only) | 140 k, every 1–2 s while walking | 7% of the CPU: a bigger cache beats a cleverer allocator |
| page-flip wait at the end of `render_frame` | up to 20 ms of idle per frame | moving the wait to the start lets the logic overlap it (§5) |
| DFS loading | ~390 ms per track | rotational latency, not the CPU: one multi-sector read per track is already the right shape |

Two structural points that matter more than any single routine:

- **Keep/erase bookkeeping and the dirty box.** Standing still costs nothing because
  every unchanged sprite is kept; a single moving sprite dirties a box and every kept
  sprite overlapping that box is redrawn in full. Wide sprites (SAS's text bands) turned
  one rogue walking past into three full-width redraws per frame. The fix was to let
  `drawtextline` redraw only the columns the dirty box touched (`txtclip`, `sp_clo/chi`);
  the same idea applies to any wide sprite Cleo keeps on screen (the status bar is
  already outside the ring, which is why it is cheap).
- **The frame budget is quantised by the flip.** With the flip waiting for a vsync and
  `vsyncs − flipvs ≥ 2`, a render that takes 21 ms costs the same as one that takes 39
  ms. It is worth knowing which side of that edge a scene sits on before optimising the
  wrong thing: SAS went from 6 to 22 fps standing still by fixing the catch-up runaway
  (§1.2) without touching the renderer.

## 5. Engine-side changes that would carry over

- `render_frame` waits for the page flip at its *start*, not after requesting it, so
  the next frame's logic runs during the wait (+3–10 fps at 25 Hz logic).
- If Cleo ever draws text over the scrolling map, opaque bands with the partial-erase
  bookkeeping (`band_erase`, `txtclip`) are far cheaper than transparent lines.
- Sprite drop shadows and flat-colour ground dither into stipple; SAS drops the shadow
  colour and flood-fills the spawn tile's colour to black. Cleo's tile set may benefit
  from the same treatment where a flat colour is used as ground.
