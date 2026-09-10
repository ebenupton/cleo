# Proposal: skip scroll-strip chars whose slot already holds the right pixels

Plan only; no code. Written against `1b5a08a`. Numbers below come from the level maps
and the converted tiles (script in §6), not from guesses.

## 1. What the original does

The GX build's `Engine.validateRect(x, y, w, h, off)` walks the tiles of a rectangle
of its torus image and, before drawing each one, compares `map[i]` with `map[i + off]`,
where `off` is the map offset between the tile now wanted in that torus cell and the
tile the cell held before it was recycled (`±width` for a column strip, `±mapwidth·height`
for a row strip). Equal tile ids mean equal pixels, so the draw is skipped. On a scrolling
sky or a repeated ground band that is most of the cells, which is where the "less per-tile
work" came from. The torus holds pure background (sprites go onto the screen after
`copyArea`), so the comparison is always valid.

## 2. How the recycling works on the Beeb ring

The ring is one 2560-char loop, not a 2-D torus: char `(cx, cy)` lives in slot
`(cy·80 + cx) mod 2560` (`ringaddr`: `RINGLO[cy & 31] + cx·8`, wrapped at 20480).
Two consequences:

- A horizontal scroll of one char to the right draws column `cx+80` on every held row
  `cy`. Its slot is `((cy+1)·80 + cx) mod 2560`: the slot that held **`(cx, cy+1)`**,
  the old leftmost column *one char row down*. The recycled neighbour is diagonal, not
  lateral.
- Tiles are two char rows tall. Row `cy` and row `cy+1` have opposite parity, so the
  comparison is always between the **top half of one tile and the bottom half of
  another**. Tile-id equality is useless (it never holds); what has to match is the
  8×2-pixel char cell. That is what makes this different from the original.

A vertical scroll's new bottom row `wcy+27` recycles the slot of row `wcy−5`, which is
not held: its content is whatever was drawn there some time ago at some other `wcx`,
possibly partly overwritten. Without per-slot bookkeeping (2560 bytes per buffer) it
cannot be trusted, so this proposal covers **horizontal strips only**. Vertical motion is
jumps, which are short.

## 3. Hit rates

For every char position in every level and every held row, is the incoming cell
`(tile at (c>>2, cy>>1), half cy&1, sub-column c&3)` pixel-identical to the recycled cell
`(tile at ((c−80)>>2, (cy+1)>>1), half (cy+1)&1, same sub-column)`? Averaged over all
columns and rows of each map:

| level | exact cell match | of which both cells one flat colour (cyan / black) |
|---|---|---|
| L0B City Gates | 46.5% | 37.3% (cyan) |
| L2B | 32.0% | 17.4% |
| L4B | 39.9% | 28.2% |
| L6B | 46.0% | 39.2% |
| L1B tomb | 12.6% | 6.9% (black) |
| L3B | 10.1% | 1.6% |
| L5B | 13.7% | 0.9% |
| L7B | 20.7% | 4.8% |
| all main levels | 28.0% | 17.4% |

With the tomb backgrounds made solid black (the `preview_dark` rules, not yet in the
game): tombs rise to 35–45% exact, 35–45% flat black; all levels 40.7% exact, 34.7% flat.

So the flat-colour case is almost the whole win: 17% of strip chars today, 35% once the
tombs go black. General cell equality adds only 6 points on top of that.

## 4. Two implementations

### 4a. Flat-colour skip (no new tables) — recommended

The page-table entries the strip already gathers carry "solid" (hi bit 6) and its
colour (lo bit 4). Gather the **recycled** tiles too: for a strip at `wcx_old+80+k`,
`k < dx`, the recycled tile of row `cy` is the map tile at `((wcx_old+k)>>2, (cy+1)>>1)`;
that is the old leftmost tile column, one tile row down for odd `cy` and the same tile
row for even `cy`. Per tile run in `@drawrow`, when the new entry is solid: read the old
entry for that row; if it is solid with the same colour, skip the fill (advance `sp` and
`cnt` only). Cost ~15 cycles per run; saving ~80 cycles per skipped char (the solid path
is ~35 setup + 48 fill). Strip rows are two chars per tile row, so gather once per tile
row pair as now.

### 4b. Half-tile classes (general equality)

There are 757 distinct half-tile images (686 with black tombs) — more than a byte's
worth — and 1541 distinct char cells. A per-tile pair of class bytes (top half, bottom
half; class 0 = "unique, never equal", the 255 commonest halves numbered) costs 934
bytes in bank 7 and lets the run test be `CLASSTOP[new] == CLASSBOT[old]` (or the
reverse by row parity). Skips a whole run only when the whole half matches, which is
close to the per-cell figure. Worth +6 points; not worth doing first.

## 5. The guard: the slot must be pure background

Sprites are drawn into the ring itself, so the recycled slot `(wcx_old+k, cy+1)` is only
background if nothing else is there:

- Row `cy+1` must be a held row: `cy < wcy+27`. The bottom row never skips.
- No sprite of this buffer that survives this frame may cover the slot. After
  `erase_old`, the buffer's records with `KEEP ≠ 0` (unchanged sprites, and the box
  stars which are never erased) still have pixels in place. Before the strip, walk the
  buffer's records once: for each kept record whose column range meets
  `[wcx_old, wcx_old+dx)`, mark its rows (shifted up by one, because the recycled slot
  is one row down) in a 28-entry row mask. ~20 cycles a record, ~200 a frame. A marked
  row draws as now.
- `copy_partial` and `copy_bar` write rows `wcy−1`, `wcy−3`, `wcy−2`; their slots are the
  diagonals of rows outside the window, so they never alias a strip cell. `draw_dirty`
  writes tiles, which are background. Nothing else writes the ring.

Miss the guard and a box star leaves a ghost when it scrolls off; the pixel-exact
`tools/fbdiff.mjs` comparison against the previous build catches exactly that, so it is
the acceptance test.

## 6. Expected gain, honestly

Running outdoors the strip is about 3 chars × 28 rows = 84 chars per render, roughly
10K cycles. A 37% skip at ~80 cycles saves about 2.5K a frame on City Gates, ~1.5K on
L2; in the tombs today under 1K, rising to ~3K once the backgrounds are black. It is
in the same band as the last two changes: real, worth having, not a frame-rate changer
on its own. The reason it paid more on the phone is that its per-tile draw was
expensive and its torus had row strips too; here a tile copy is already 13 cycles a
byte.

The smoothing dividend of the original comes from the other half of `scrollTo` —
validating a slice of the incoming column per pixel of scroll, which needs the lead
column the 80-char hardware row does not give us — and is a separate proposal.

Measurement script: `python3 - <<EOF` over `tools/convert.py`'s `levels`,
`tile_preview`, `orig2compact`, comparing cells as in §3 (kept in the session log; easy
to re-create in ten lines).
