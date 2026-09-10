# Proposal: "next 8 bytes are solid" in the sprite encoding

Plan only; no code. Written against engine.s at `b93c646`.

## 1. What the blitter does today

Sprite data is column-major, `lines` bytes per column. `drawsprite` walks screen char
cells: for each char row it points `ptr` at source line `8*row - lb0` of the column and
`SPRFULL` runs `SPRLINE 0..7` (a full cell) or the `partial` loop (top/bottom rows).
Per byte:

| byte | test | cost |
|---|---|---|
| `$00` both transparent | `beq` | 8 |
| `>= $C0` both opaque (bit 3 of both nibbles set by the converter) | `cmp #$C0 / bcs` then `sta (sp),y` | 18 (24 mirrored: `SWAPTAB`) |
| anything else, one pixel opaque | `MASKTAB` and, `IDENT` or | 34 (40 mirrored) |

Measured mix (profile of level 0): sprFN averages about 20 cycles a byte, so the
per-byte opaque path already carries most of the work. The room for a solid-cell path is
therefore bounded: 8 bytes at 18 = 144 cycles now against about 100 for a straight copy.

## 2. The catch: cells are not fixed 8-byte groups

The bytes of one screen cell are source lines `8r - lb0 .. 8r - lb0 + 7`, and
`lb0 = 2*sy + wfine` moves with the sprite's vertical position. A marker stored at data
offsets 0, 8, 16 … only lines up with a screen cell when `lb0 mod 8 == 0`. (Stars are the
exception: their `refy` snap makes them cell-aligned at rest, which is why the box stars
work as plain copies.) So a *per-cell* marker is useless; the flag has to be a
*per-byte* property, "this byte and the seven after it are all both-opaque", tested only
on the byte that happens to start a cell. That is what the senior bits can carry.

## 3. Encoding

Free a bit in the both-opaque range by moving the "both opaque" tag to bit 7 alone:

| byte class | bit 7 | bit 6 | rest | display |
|---|---|---|---|---|
| both transparent | 0 | 0 | `$00` | not written |
| one pixel opaque | 0 | x | any of the 16 codes below `$80` | via `MASKTAB` / `ORTAB` |
| both opaque | 1 | **RUN** | left colour in bits 5,3,1; right colour in bits 4,2,0; black = 0 | written as-is |

Display correctness: the left nibble is `1lll` (logical 8–15, which the palette shows as
0–7) and the right nibble is `Rrrr` — with RUN set it is 8–15, without it 0–7; both show
`rrr`. Black is colour 0 in both nibbles and shows as black. So the tag and RUN bits are
invisible, exactly as today's `$C0` tag is.

RUN = 1 means the following 7 bytes of this column are also both-opaque (converter:
`all(both[i:i+8])`, never set within 7 bytes of the column end).

The single-opaque codes: today's are all below `$80` except left-black-only (`$80`).
That one moves to a spare code (`$44`, say: it decodes under the old nibble rule to
"right colour 10", which nothing generates). `IDENT` becomes a real `ORTAB` (same 256
bytes, generated at init as now, with three patched entries: `MASKTAB[$44] = $55`,
`ORTAB[$44] = $00`, `SWAPTAB[$44] = $40` and `SWAPTAB[$40] = $44`). Right-only black stays
`$40`.

`SWAPTAB` for both-opaque bytes returns the nibble-swapped *display* byte; its RUN bit is
never re-tested (the swap result is only ever stored), so it can be anything.

Optional, same free space: `$10` = "transparent, and so are the next 7" (only on the
first byte of a run of 8+ zeros). Tested at cell start it skips the whole cell (saves
about 50 cycles a cell); read mid-cell it goes down the table path as an ordinary
transparent byte (`MASKTAB[$10] = $FF`, `ORTAB[$10] = 0`), 26 cycles dearer once per run.

## 4. The blitter

Lines 1–7 (`SPRLINE k`, k ≠ 0) lose the compare and become the `bmi` you originally
asked for:

```
        lda (ptr),y
        beq done
        bmi opaque          ; bit 7: both opaque -> sta (sp),y      (16 cycles, was 18)
        tax                 ; one-pixel code -> MASKTAB / ORTAB
        ...
```

Line 0 (cell start) adds one test, taken only on the both-opaque branch:

```
        lda (ptr),y
        beq done
        bpl masked          ; < $80: one-pixel code (or the $10 empty-cell marker)
        cmp #$C0
        bcs solidcell       ; RUN: this and the next 7 bytes -> straight copy
opaque: sta (sp),y          ; both opaque, no run (19 cycles, was 18)
```

`solidcell` (per `SPRFULL` instance; the mirrored one swaps through `SWAPTAB`):

```
solidcell:
        sta (sp),y          ; y = 0, A already holds the byte
        ldy #1 : lda (ptr),y : sta (sp),y      ; x7, unrolled
        ...
        jmp sprretP         ; column done, skip lines 1..7
```

About 100 cycles a cell, 140 mirrored. It is reached only from the `l0` entry with
`tmp2 = 7`, i.e. a whole cell; partial rows never see line 0 unless `tmp = 0`, and then
the byte goes down the table path where the tables make RUN-flagged bytes plain opaque
ones. The `partial` loop, `SPRLINE2` (half-res, title only) and the box-star copy blitter
`sprFC` need no change beyond the tables.

## 5. What has to change, in order

1. `convert.py`: `pack_mode2` output post-processed — both-opaque bytes re-tagged (bit 7,
   black as 0, RUN bit from the run test), `$80` → `$44`. Same routine for the title
   pack (`rect_image`) and the box stars, so one encoder feeds every blitter.
2. `engine.s` table init: `IDENT` → `ORTAB` contents plus the four patched entries.
3. `SPRLINE` macro: two variants as above (k = 0 gets the RUN test); `solidcell` block in
   `SPRFULL` (skip it for the `copy` instance); mirrored `solidcell` uses `SWAPTAB`.
4. Optional `$10` empty-cell marker: converter + a `bpl masked` split (`cmp #$10`) at
   line 0 only.
5. Space: about 70 bytes of CODE for two `solidcell` blocks and the line-0 variants.
   CODE has 26 free, HAZEL 55: move `drawrect_clip` (~80 bytes) to HAZEL first.
6. Verify: `tools/statelog.mjs` lockstep (logic untouched, should be identical) plus a
   pixel-exact framebuffer comparison of old vs new build at the same logic frames
   (a `partcheck.mjs`-style harness that diffs the displayed buffer per painted frame),
   because this changes what is written, not when.

## 6. Expected gain, honestly

- Solid cell: 131 → 100 cycles (mirrored 178 → 140). Cleo standing has roughly 10–12
  solid cells: ~400 cycles a frame. Spinning stars have few.
- Lines 1–7 opaque path: −1 cycle a byte across every sprite: ~500–800 a frame.
- Empty-cell marker: ~50 a cell on the sprites with blank corners: a few hundred.

Total on the order of 1–2K cycles a frame out of the current 72–90K render. It does not
move the frame rate on its own; the per-column glue (~35 cycles × 150 columns) and
`drawsprite`'s 16-bit setup (~500 a sprite) are each larger and would be the next
targets if the goal is 25 Hz at rest.
