# Cleo on a Model B with 64K of sideways RAM

A second target, not a second build of the first one: the machine has 32K of main
RAM against the Master's 128K, so the memory map is the design and everything else
follows from it.  MODE 1, four colours, one indoor level, no menus.

## Main RAM: 30K of screen, 2K of everything else

```
$0000-$00EF  zero page          every variable two banks share lives here; it stops
                                short of $F4, the MOS's copy of ROMSEL, which the
                                bank switching reads and writes
$0100-$013F  stack              64 bytes; measured high-water is checked in the harness
$0140-$02FF  workspace          448 bytes: the ISR, SECTAB, the thunks, the map buffer
$0300-$07FF  status bar         2 char rows, 1280 bytes, single buffered, scanned in place
$0800-$0A7F  mirror A           a copy of ring A's last row (see "the straddling row")
$0A80-$43FF  ring A             23 slots x 640 = 14720 bytes
$4400-$467F  mirror B
$4680-$7FFF  ring B             23 slots x 640
```

Two rings of 24 rows of memory each, 30720 bytes, exactly the 30K the machine can
spare.  Each ring shows 21 rows; the other three are the composed fine-scroll row,
the bottom straddle row, and the mirror.  Both ring *ends* are page aligned ($4400
and $8000), which is what the fold test needs; the ring length (14720) is not a whole
number of pages, so the fold body is two bytes wide while the test stays one.

21 rows is 168 scanlines, 84 game pixels: the window is 160 x 84 against the Master's
160 x 120 and the phone's 176 x 108.

## The display: five sections, wrapped by hand

The Model B's CRTC can scan any of the 32K (`byte = ma*8 + ra`, and MA12 -- the
hardware wrap -- never sets below $8000), but it cannot wrap a *row*: the row pitch
is R1 and a section's rows are consecutive.  So the ring is wrapped by rupture:

```
T   bar          2 rows at $0300
A   composed row 8-f lines, the fine scroll                (only when f > 0)
P1  playfield    from the window's slot to the ring's end
M   playfield    the rest, from the mirror
P2  bottom       f lines                                   (only when f > 0)
Q   blanking     16 rows, vsync at row 8
```

Because the window start carries the horizontal scroll (`ringS = slot*80 + wcx`), one
displayed row straddles the ring end whenever wcx > 0.  A copy of the ring's last row
sits immediately *below* the ring base, so that row can be read as one run at
`MIRROR + wcx*8` -- and the row after it continues into the ring base on its own, which
is exactly where the next displayed row lives.  One mirror row buys the whole wrap.

## The four banks: code next to the data it reads

Nothing but the interrupt handler and the thunks is in main RAM, so all of the engine
lives in the banks, each with the data its inner loop touches:

| Bank | Contents |
|---|---|
| 4 | sprite images, masks, MASKTAB0-3, SWAPTAB, the sprite blitter, the drawn-sprite records |
| 5 | this level's tiles and the tile blitter: drawrow, drawrect, scroll_validate, the bar |
| 6 | the map, the object table, the tile attributes, and the routines that read them |
| 7 | the game logic, the frame loop, the chain builder, and the low-RAM image |

Each bank also has a `*_copy`, the one way anything outside it can read its data:
given an address in the bank and a length it copies into `MAPBUF`, the 48-byte buffer
in zero page.  Only the map's is used in anger -- the tile and sprite data is read by
the blitters that live beside it -- but the mechanism is uniform.

A bank-resident routine calls another bank through `farcall` in main RAM, which saves
the caller's bank, switches, calls and switches back: about 63 cycles.  That is far too
slow per tile, so the traffic is arranged to be per *frame* or per *rectangle*: the tile
blitter fetches the map strip it needs in one call into a 32-byte buffer at $0140 and
then reads it locally, which is the only thing the map bank is asked for during a draw.
The logic reads single map bytes through `mapbyte`, 31 cycles, which is cheap because
the routine itself is in main RAM and only the data is elsewhere.

## Loading

`!BOOT` runs LOADER, which OSFILEs each bank image into main RAM at $2000 and copies
it into its bank with `$F4` and `$FE30` both set (so an interrupt that pages a ROM in
puts ours back).  DFS cannot load into a sideways bank directly, which is why the
staging copy is there.  After the last bank it sets MODE 1 and jumps into bank 7; the
game copies its low-RAM image to $0140, takes the machine over and never calls the OS
again.

SHIFT+BREAK boots it.  The controls are the cursor keys or Z and X to walk, and the
up cursor or : to jump; the keyboard is read straight from the matrix (the MOS is
gone by then), which is `scan_keys` in bank 7.

## Rectangles are in chars, both ways

Everything that repairs the ring -- the scroll strips, the erase of a sprite's old
place -- is a rectangle of map, and it is given in **chars across by char rows down**,
never in tiles.  Two things force that:

- The ring is 23 rows of 80 chars and the window is 22 of them, so the window's chars
  own every slot but one row's worth.  A char written past the window's right edge
  lands on the ring slot of the window's LEFTMOST chars one row down -- which is still
  on screen.  Rounding a rectangle out to whole tiles corrupts the row below it.
- The window moves one char at a time in either axis.  A rectangle rounded to tiles
  redraws two char rows to repair one, which is twice the work in the one place the
  frame can least afford it.

So `clip_rect` clips to the char in both axes (window first, then the map's edges),
and the blitter draws a *run* of a tile's four chars: `draw_tile_full` for the whole
tile, `draw_tile` for the two at the ends of the rectangle.  `scroll_validate` tracks
each buffer's window origin in chars for the same reason -- a tile origin cannot see
a one-char move.

Two cheap things pay for themselves several times a frame:

- **Blank tiles are filled, not copied.**  Over half of a level's map is a tile with
  nothing in it (tile 3 alone is a third of this one), so `tools/assets.py` emits a
  byte per tile and the blitter fills those 32 bytes from A instead of reading them:
  8 cycles a byte against 13.
- **The row walks.**  The ring address of the row below is the row above plus 640,
  folded at the ring end, so it is computed once per rectangle and stepped, not
  rebuilt per row from the slot table and a shift loop.

## The mirror is made only when its row has been written

`mirror_copy` is up to 640 bytes, and the row it copies -- the ring's last -- is
written on maybe a third of frames.  `calc_ring` works out `mrow`, the one map char
row that lives in that slot row, and every writer (the tile rectangles, the sprite
blitter, the composed row) raises a per-buffer flag when it writes it; `mirror_copy`
returns at once when the flag is down.  A move LEFT also raises it, because the copy
only ever covers chars `wcx..79`.

## What it costs, and why the frame is pegged at four vsyncs

The flip happens at a vsync, so a frame's period is a whole number of them.  With the
whole game running -- a dozen objects on screen, two logic steps a frame -- the work
between `frame_top` and the flip is:

| | cycles |
|---|---|
| median | 128000 |
| 90th percentile | 143000 |
| worst | 150000 |

Three vsyncs is 120000 cycles, so `VSPEG` is 4: a steady 12.5 frames a second, with
the world stepping 25 times a second against the Master's 33.  Where it goes:

| Phase | Cycles |
|---|---|
| draw the sprites | 40000 |
| erase their old places | 27000 |
| the scroll strips | 19000 |
| the two logic steps | 16000 |
| the composed row | 9000 |
| the mirror | 3000 |

The Master fits the same game in three vsyncs because its MODE 2 sprites carry
transparency in the senior bit of each byte: its inner loop is a load, a branch and a
store.  Masking in MODE 1 costs about twice that a byte, and with a dozen objects on
screen that is the whole gap.  Everything cheap has been taken: blank tiles are
filled rather than copied, a tile row is drawn in one pass for both its char rows, a
rectangle's map comes across in one far call, the mirror copies only the chars that
were written, box stars are opaque (no mask, and no erase when the logic says nothing
can disturb them), and a sprite whose record matches what the logic queued again is
not erased at all.

## How it is checked

The ring is not something to eyeball.  `tools/bcheck.mjs` plays N frames and stops at
a named point in bank 7 (the bank matters: every bank has code at the same addresses),
then `tools/bring.py` renders what every char of the window should hold from the map
and the tiles and compares all 22 rows of both rings, plus the mirror against the
ring's last row.  Two stop points matter:

- `pre_spr`, after the scroll and the erase and before a single sprite has gone down:
  there the ring is pure map, so any difference is a renderer bug.
- `wait_flip`, after `mirror_copy`: the only point where the mirror is up to date.

`tools/bsoak.mjs` runs both checks every ten frames over a long run with the keys
changing, and `tools/bsample.mjs` is a sampling profiler that buckets the PC by the
label owning it in the bank that was paged in.
