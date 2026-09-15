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

## What it costs

Measured with `tools/bprof.mjs` on the first level, walking right and jumping, in
cycles a frame:

| Phase | Cycles |
|---|---|
| erase the sprites' old places | 29300 |
| draw the sprites | 29300 |
| the scroll strips | 15500 |
| mirror | 6000 |
| the composed row | 5000 |
| queue the sprites | 3500 |
| the player and the camera | 3400 |
| build the chain | 900 |

That is about 93000 cycles of work, so the frame lands on the third vsync after it
started: 16.7 frames a second, with about 20000 cycles of slack before the flip.  Two
vsyncs (25 fps) needs the work under about 78000, which would take fusing the erase
into the sprite blitter -- and that cannot be done while the tiles are in bank 5 and
the sprite blitter is in bank 4, because the fused loop would need a bank switch per
char.

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
