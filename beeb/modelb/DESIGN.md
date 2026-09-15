# Cleo on a Model B with 64K of sideways RAM

The same game as the Master's MODE 1 build, from the same sources.  `../src/engine.s`,
`logic.s` and `game.s` are assembled with `MODELB=1`; what that define changes is
addresses (where each routine and table lives), the 65C02 spellings (`src/cpu.inc`),
and the handful of places where a bank has to be reached across a boundary.  Nothing
in the game logic or the blitters is written twice.  `tools/bdiff.mjs` runs a 21-row
Master build and this one in lock step and compares every byte of logic state after
every frame; `tools/bcheck2.mjs` + `bring2.py` compare both rings against a render of
the map.

## Main RAM: 30K of display, 768 bytes of everything else

```
$0000-$00EF  zero page      the Master's layout unchanged ($00-$A1 engine + logic,
                            $A8-$DE the logic's temps), the gaps taken by what the
                            Master keeps in main-RAM tables (defs.inc)
$0100-$013F  stack          64 bytes
$0140-$0203  low BSS        SPRLIST, the digit cache, the chain's state, the mirror's
$0206-$02FF  low code       farcall, the interrupt stub, maprow/mapbyte/mapput/pagelogic
                            (the Master's own), maprow5/mapstrip/dirfetch
$0300-$07FF  status bar     2 rows, loaded into place by the loader, never redrawn
$0800-$0A7F  mirror A       a copy of ring A's last slot row (below)
$0A80-$43FF  ring A         23 slots x 640
$4400-$467F  mirror B
$4680-$7FFF  ring B
```

The Master's ring is 32 rows because the hardware folds $8000 back to $3000.  Here
the ring is 23 slots (21 visible, the composed fine-scroll row, the bottom straddle)
and nothing folds it, so the display is a rupture chain (display.s) and the one
displayed row that straddles the ring end is read from a copy of the last slot row
sitting immediately below the ring base.  23 x 640 is not a whole number of pages,
so `ringup` folds 16 bits wide on this target; both ring ends are page aligned, so
its test stays a byte compare against the buffer's `ringehi`.

## The four banks: code beside the data its inner loop reads

| Bank | Contents |
|---|---|
| 4 | most sprite images and masks, SWAPTAB + MASKTAB0..3 at $8300, the sprite row loop (`SPRITE_LOOPS 1, 0`) |
| 5 | the tiles, the tile blitter and everything that walks the ring (`render_core`), the sprite prologue, the records, KEEP, the dirty lists, LV_PAGE0, SPRMASK |
| 6 | the map, the sprite directory, the box stars and every never-mirrored sprite with their own row loop (`SPRITE_LOOPS 0, 1`: no SWAPTAB, no mirrored blitter, the copy blitter) |
| 7 | the logic, the game loop, `render_frame`, the display driver and the interrupt's work, the sound and the music, the HUD, the level's tables |

Every bank starts with the same far table at $8000 (banks.s `COMMON_TABLES`), so the
thunk in low RAM reads it whatever bank is paged in; banks 5 and 7 also carry the
small tables their code indexes (sprmul5, the row multiples, the ring modulus),
assembled rather than built.  The mask tables are assembled too.

A far call (`farjsr`, low.s) pushes the caller's bank, a return into `fcret` and the
target, and rts's into it: ~90 cycles, nesting and interrupt safe.  The traffic is
per frame: `render_frame` (bank 7) makes one call into bank 5 for the ring work,
the prologue makes one per sprite into the bank that holds its image, and the rest
(mark_dirty, the level reset, start-up) is rare.  Two things the Master does inline
go through main RAM here because bank 5 cannot page bank 6 over itself: the tile
blitter's map row is fetched into MAPBUF a tile row at a time (`mapstrip`, the same
gather loop reading the copy), and the sprite prologue's directory entry comes into
MAPBUF too (`dirfetch`).

The loader stages each bank image at $2000 and copies it in; DFS cannot load into
sideways RAM.  It loads the bar the same way and copies it to $0300 after `MODE 1`,
then jumps to $8100 in bank 7.  A bank cannot page itself out and carry on -- the
next instruction is read from the new bank -- so every switch runs from main RAM
(the entry stub copies itself to the bottom of the stack page; `to7` is in low.s).

## What the define changes, and only that

- `PLACE "CODE", "TILCODE"`: the segment a routine goes in, Master name first.
- `ringup p` folds `p` 16 bits wide against the buffer's end; `select_backbuf` sets
  `ringbhi/ringehi/ringe3/ringneg` and rebuilds RINGLO/HI from the buffer's base.
- `drawrect`'s two bank switches become `maprow5` + `mapstrip`; `@nextrow` adds a
  constant stride (MAPSTRIDE = 128; the row tables are arithmetic, `maprow` too).
- `drawsprite`: no bank switching in the prologue; the directory entry via `dirfetch`;
  the dispatch index goes in `sp_disp` and the loop copy patches its own jump; the
  hand-over to the row loop is a far call chosen by `sp_dbank`.
- the mirror's bookkeeping: three MODELB blocks (drawrect, drawsprite, copy_partial)
  call `mirdirty` with the window columns written to the row the mirror follows
  (`mrow`, `wcxm`, `rstar` from calc_ring's tail); `mirror_copy` copies only those.
- `render_frame` splits: the ring work is `render_core` in bank 5; the chain and
  the mirror are built here; `bar_bg` only resets the digit cache.
- `init_maprows`, `music_init` are nothing; `MUSIC_TAB` is the data; `t_`/`m_`
  bridges are names, with stubs for the menus the one-level disc has no use for.
- tables: MAXSPR/MAXREC 24 (the Master's 32), OBJN 126 (149), the level's tables
  and the object arrays laid out as the Master's.

## The 6502 spellings

`src/cpu.inc` documents the contracts.  `tools/flagscan.py` (in `../tools`) audits
every site: `stz` needs A dead (44 sites; the two with A live are `stza`), `inca`/
`deca` keep the carry (through `mtmp`) because the sprite prologue counts on it,
`ldaz` destroys Y (the one site with Y live is `ldazy`), `bitimm` keeps A.

## Verification

- `tools/bdiff.mjs N seed`: the 21-row Master (`../build/ref_mode1_21`, the Master
  built with `-D VISROWSDEF=21`) and this build, same keys at every `frame_top`, all
  of the logic state compared each frame.  600 frames, two seeds: identical.
- `tools/bcheck2.mjs keys frames [pre]` + `tools/bring2.py cur`: the current
  buffer's ring against the map at `draw_sprites` (pure map: 0 chars differ, kept
  sprites excluded) and the mirror against the last slot row at `frame_top`.
- `tools/bwork2.mjs`: frame cost over 300 frames of random play, two seeds.  Median
  63-70k cycles, 90th percentile 111-119k, worst 149-183k (the interrupt excluded;
  4 far calls a frame), against the previous port's 136k/156k/162k -- the Master's
  blitters, gather and record matching are simply faster than what was written to
  replace them.  VSPEG is 3, the Master's: most frames make it, the heavy ones take
  four, as the Master's do on its heavy levels.
- `tools/bshot2.mjs`, `bstate3.mjs`, `bspr3.mjs`, `bbrk.mjs`: screenshots, state,
  the sprite list, and a trace to the first BRK.

## Other levels

`LEVEL="lv sub" sh build.sh` packs another level (the default is `1 0`, L1B).  The
packer folds near-duplicate tiles exactly as the Master's convert.py does for the
set, so a level's tiles are the Master's.  L0B (the first outdoor level, 256x32,
82 objects) builds and passes the same checks with 81 bytes to spare in bank 5 and
17 in bank 6; its frame cost is higher (median 76k, worst 268k: wide open scenes
scroll more of the ring), with 8 far calls a frame.  A 256-wide map's row address
is the row itself (`maprow`, `maprow5` take MAPLW 7 or 8).  The other outdoor main
levels need 13-14K of tiles and do not fit bank 5 as it stands.

## Known differences from the Master

21 visible rows against 30 (84 game px: the world's in-range decisions follow
VISLINES, which is why the reference for the lock-step test is a 21-row Master).  The
picture starts 64 lines after vsync, 4 scanlines above where a MODE 2 frame's centre
would put it; exact centring needs a half-row blanking section.  No menus: the level
restarts on completion or on the last life.
