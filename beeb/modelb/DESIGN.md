# Cleo on a Model B with 64K of sideways RAM

A second target, not a second build of the first one: the machine has 32K of main
RAM against the Master's 128K, so the memory map is the design and everything else
follows from it.  MODE 1, four colours, one indoor level, no menus.

## Main RAM: 30K of screen, 2K of everything else

```
$0000-$00FF  zero page          every variable two banks share lives here
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
