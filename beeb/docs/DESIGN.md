# Cleo: the design

Cleo is the 2004 J2ME platformer ported to the BBC Micro on beebgame, the engine (a
submodule in `beebgame/`; its `docs/DESIGN.md` is the machine side: memory, display,
blitters, loader, level file format).  This document is the game's side: its sources, the
game loop, the logic and its collision rule, the objects, the HUD, the menus, the asset
pipeline, the bake plans and the tests.  Every name is a symbol in `src/*.s`, `tools/*.py`
or the build's outputs (`build/modelb/assets.inc`, `labels.txt`); where a number appears it
is what today's build gives and the symbol is what to read.

## 1. The sources

| File | What |
|---|---|
| `src/main.s` | the root: `cpu.inc`, `defs.inc`, the engine's sources and the game's in order (`logic.s`, `game.s`, `menu.s`, then `low.s`, `disc.s`, `mirror.s` on the Model B, `banks.s`, `gamedata.s`, `init.s`), and the hooks the engine calls: `hook_title = game_main`, `hook_play = level_loop`, `hook_over = menu_over`, `hook_image = bar_bg`, `hook_hud = redraw_hud` |
| `src/logic.s` | the port of `CleoApp.run()`: the constants, the object arrays, the zero-page state (`ZPGAME`), the map queries, `level_init`, `game_frame`, the player, the boomerang, the thirteen object handlers, the collision tests, the HUD digits, `rnd`, the tables `RNGTAB`/`MROWL`/`MROWH`, `score`/`hi_score` |
| `src/game.s` | the game loop (`clamp_window`, `level_loop`, `frame_loop`, `frame_top`, `fl_over`, `game_over`) and the sound effects (`sfx_tab`, resident with the kernel's `sound_tick`) |
| `src/menu.s` | the menus' image of bank 7: `game_main`, `title_loop`, `new_game`, `menu_over`; the title, help, level select and win/lose screens; `draw_text`, the title pieces' `unpack`/`blit` |
| `src/gamedata.s` | the tables: `alt_tab` (`alt.bin`), the HUD digits (`digits.bin`, `digtab.bin`), `sprgeom.inc`; the object state (`GAMEOBJ`: `LV_OBJST`, `LV_GRID`, `LV_BOBJ`, `LV_BNEXT`, `LV_BINSTAR`, `LV_BINOTH`); the menus' `music_addr`, `font_art`, `title.inc` and `title_art` |
| `src/keymap.inc` | `key_tab`/`key_bits` (`KEYN` = 10), included by the kernel's `scan_keys` |
| `tools/convert.py` | the original's data (`assets/v500`, CleoV500.jar's contents) to MODE 1: the dither, the tiles and the tile set files `TILES0-2`, the maps, the objects, the sprites and `NIBTAB`, the boxes and bake kinds, the bar, the digits, the font, the title pieces, the previews |
| `tools/assets.py` | the packer: imports `convert.py`; writes `L0..L15`, `SPRC`, `SPRX`, `img_tab.bin`, `BAR`, `digits.bin`, `digtab.bin`, `font.bin`, `alt.bin`, `music.bin`, `title.bin`/`title.inc`, `nibtab.bin`, `bake_geom.bin`, `bake_kind.bin`, `bakes.json`, `assets.inc`, `sprgeom.inc` |
| `build.sh` | sets `GAME_MAIN`, `GAME_SRC`, `DISC_TITLE`, `DISC_OUT`, `GAME_NAME`, `GAME_MUSIC` (`midi2snd.py` over `thm.mid`) and `GAME_ASSETS` (`tools/assets.py`), runs `beebgame/tools/build.sh`, copies the disc to `../cleo.ssd` unless `ALLLEVELS` |

Where the game's code and data sit: `GAMECODE` and `GAMEDATA` are in bank 7's game image
(`__B7_START__`), `GAMEBSS`/`GAMEROWH`/`GAMEOBJ` are its variables (zeroed as the image
comes in), `GAMELVL` is the room below them (`__GAMELVL_RUN__`, $8220 today, after the
engine's `ENGLVL`), `GAMEHI` is the resident page at the top of the bank (`__GAMEHI_RUN__`),
`ZPGAME` follows the engine's zero page (`__ZPGAME_RUN__`), and `MNUCODE`/`MNUBSS` are the
menus' image.  The layout is `beebgame/cfg/banks.cfg`'s.

## 2. The game loop (`game.s`)

`level_loop` is `hook_play`: the game's image has come in (`disc.s go_game`) with `level`,
`score`, `lives` and `health` set by the menus.  It blanks the palette, loads the level
(`load_level_b` with X = `level`, 0..15, even main and odd bonus), derives `mapw`/`maph`
(`TILEPX << lw`, `TILEPX << lh` from `LV_HDR+HDR_LW/HDR_LH`, `maplw` kept for the tile tests) and the
camera limits `maxwx = mapw - WINPX`, `maxwy = maph - VISLINES/2`, calls the engine's
`lv_reset`, then `level_init`, sets `bar_dirty`, renders two frames (`game_frame` +
`render_frame`, both buffers) in the dark and turns the palette on.

`frame_loop` pegs a rendered frame at `VSPEG` = 3 vsyncs (16.7 Hz).  `fl_wait` waits for a
vsync, `frame_loop` tests `vsyncs - logicvs >= VSPEG` and then sets `logicvs = vsyncs`: time
lost to a long frame is dropped, not caught up, so the window never moves more in a frame
than one step asks.  One `game_frame` is one update composing two of the original's 25 Hz
steps (section 3).  `frame_top` is reached exactly once a rendered frame, before the logic
reads `keys`: the harness breaks there (`test/harness.mjs`), so every wait and every input it
applies is quantised to a frame.  `exiting` set after `game_frame` leaves to `fl_over`.

`fl_over`: no `lives` left is `game_over` with X = 0.  Otherwise, unless `ALLLEVELS` (a test
build that takes every bonus level), a star left (`stars` non-zero) sets `level |= 1`; then
`level` is incremented.  So a main level (even) with every star collected is followed by its
bonus level (odd), one with stars left by the next main level, and a bonus level by the next
main level.  `level = NLEVELS` (16) is `game_won` (X = 1).  `max_level` keeps the furthest
main level reached (`level >> 1`), which is what the level select offers.  `game_over`
compares `hi_score` with `score` as binary (both are BCD, ones first, three bytes: the order
is the same), copies a new record, blanks the palette and `go_menu`s with A = X (0 lost, 1
won) for `hook_over`.

`clamp_window` clamps `wx` to [0, `maxwx`] and even, `wy` to [0, `maxwy`].

The sound effects (`sfx_tab`: `sfx_jump`, `sfx_star`, `sfx_throw`, `sfx_hit`, `sfx_kill`,
`sfx_power`, `sfx_die`, ids `SFX_*` in `logic.s`) are steps of the `SFX` macro -- the chip's
tone latch with the period's low 4 bits, the period's high 6 bits, the volume latch with the
attenuation, and frames to hold -- ending in `SFX_END`.  Everything plays on tone channel
`SFX_CH` = 2 except the throw, on the noise channel (`SN_NOISE`).  They are `PLACEH
"MRAMCODE", "KRNCODE"` with the kernel's `sound_tick`, which plays `sfx_req` from the vsync.

## 3. The logic (`logic.s`)

### State

Zero page (`ZPGAME`, each variable's trailing comment is its meaning): the bin walk's `bin_i`,
`bin_nstar`, `bin_noth`; `frame` (16-bit, rendered frames); the player `px py vx vy anim
ev_frame facing running firing hurt control`; the boomerang `bx by bvx bvy bcnt bactive
bounce`; `startx starty exitx exity`; `level lives health max_level last_keys logicvs
cam_off`; `seed`; scratch `ox oy fa..fe rx ry qx qy alt q1..q6 obj star_clk bin_r gx gy gx0
gx1 gy1 bent otype t16 t16b dpx hx grow`; the map memo `mok mkxlo mkxhi mkylo mkyhi mt`; the
swept move `dxl dyl`; `span`'s `swd swa swlo swhi swy`.  Positions are game pixels,
velocities 1/256 px a frame.  What the menus set for the game (`level`, `lives`, `seed`,
`max_level`) must be in zero page or `GAMEHI`: the game's image zeroes `GAMEBSS` as it comes
in.  The hot scalars were chosen with `test/hotvars.mjs` (5-11 accesses a frame each).

The object arrays are sixteen of `OBJ_MAX` (149, `levelfmt.inc`) bytes from `LV_OBJST`
(`gamedata.s`, segment `GAMEOBJ`, page aligned): `O_STAMP O_TYPE O_XL O_XH O_YL O_YH O_AL
O_AH O_BL O_BH O_CL O_CH O_DL O_DH O_EL O_EH` -- the original's A..E words as byte pairs.
After them the collision grid `LV_GRID` (`GRIDN` = 128 cells of `BINPX` = 64 px, a cell 8
tiles: `BIN_TILESHIFT`), the chains `LV_BOBJ`/`LV_BNEXT` (`BINLINKS` = 256 entries, one per
object per cell it covers, `GRID_NONE` = $FF ends a chain) and the cached walk lists
`LV_BINSTAR`/`LV_BINOTH` (`BINMAX` = `BINMAXDEF`, the packer's bound: 18 today).

`GAMEBSS`: `BARCACHE` (16, the HUD's slots), the memo's `ma`/`mb`, the move's start
`pxs`/`pys`, the boomerang's move `bdx`/`bdy` and remainder `bmx`/`bmy`, `swe`, and the
level's `stars nobj exiting gridsh bin_ok rise`.  `GAMEROWH`: `MROWH` (`MAPROWS` = 128,
half-page aligned).  `GAMELVL`: `RNGTAB` (`RNGTAB_LEN` = 88, asserted `= LV_HDR + HDR_LEN`:
the level file's header tail lands there) and `MROWL`.  `GAMEDATA`: `alt_tab`,
`digits_art`, `digtop`/`digbot`, the sprite geometry and `rise_tab`.  `GAMEHI`: `score`,
`hi_score` (3 bytes BCD each, `hi_score = score + 3`), resident through both images.

### `level_init`

Reads the header's game fields (`HDR_STARTX..HDR_EXITY` x 8 into `startx..exity`, `HDR_NOBJ`
into `nobj`), sets `gridsh = maplw - BIN_TILESHIFT`, fills `MROWL`/`MROWH` with every map
row's address through the engine's `map_row`, starts the camera centred (`cam_off = WINPX/2`),
clears the memo, the move, the star clock, `stars`, `bent` and `bin_ok`, clears
`OBJCLR_PAGES` (10) pages from `O_STAMP` (asserted to cover `O_AL..O_EH`) and fills the grid
with `GRID_NONE`.  Then the objects, last to first, from `LV_OBJS` (6 bytes each: type, x,
y in tiles, e0..e2): the type, x*8 and y*8, the per-type set-up and bounding cells, and the
insertion into every grid cell of its box:

- star (`@t0`): a `rnd` draw (kept so the enemies' draws fall as they did), `O_AL` = e2 (its
  spin phase), `stars++`, box rows `(y-1)>>3 .. y>>3`, E = e0/e1;
- trampoline (`@t1`): stands at `8x + 4` (`O_XL |= TILEPX/2`), columns `(x-2)>>3 ..
  (x+1)>>3`, row `(y+1)>>3`, E = e0/e1;
- snake, mask, mummy (`@t256`): A = e0*8 (the patrol's far end), columns to `(x+e0)>>3`;
- red snake (`@t3`): rows from `(y-4)>>3`;
- bat (`@t4`): A = e0*16, B = e1*16, C = `rnd` mod (A+1), D = `rnd` mod (B+1) (`@rm`,
  `mod16`), the box its hover rectangle;
- flame (`@t9`): rows from `(y-2)>>3`; vanishing block (`@t11`): one row; switch (`@t12`):
  A, B, C = e0, e1, e2; spike and powerup (`@t10`): E = e0/e1.

`tools/assets.py cellbox` mirrors the cell boxes to size `MAXSPR`/`BINMAX`.  Last the player:
`px/py = startx/starty`, velocities and `anim` zero, `ev_frame = frame`, `frame` = 0, `hurt =
control = 1` (she spawns invulnerable).

### `game_frame`

One update a rendered frame, every rate two of the original's steps (`frame` counts rendered
frames, so the timers are halved).  In order:

1. `frame++`; the stars' clock `star_clk` steps 0..`STARCLK`-1 (12); `bounce` = 0.
2. The camera (alive only): `cam_off` eases by 2 a frame toward `CAM_AHEAD_R` (`WINPX/4`,
   facing right: Cleo a quarter in from the left) or `CAM_AHEAD_L` (`3*WINPX/4`); `wx = px -
   cam_off`, `wy = py - CAM_Y` (46, one for one), then `clamp_window`.
3. The bucket rectangle in cells: `gx0 = wx >> 6`, `gx1 = (wx + WINPX-1) >> 6`, `gy = wy >>
   6`, `gy1 = (wy + VISLINES/2 - 1) >> 6`.
4. The object list.  The grid is written only by `level_init`, so which objects the walk
   yields depends on the rectangle alone; it is walked only when the rectangle (`bin_r`, and
   `bin_ok` holding gx1 or 0 for none) changes, deduped by `O_STAMP = frame`, stars into
   `LV_BINSTAR`, the rest into `LV_BINOTH`, in walk order -- which is the draw order the box
   stars depend on.  A list overflowing `BINMAX` processes the object at once and rebuilds
   next frame.  Then the stars run through `po_star` (no type read, no table) and the others
   through `process_object`.
5. After the objects: `bounce` gives `vy = JUMP_VY` (a stomp); a kill tile at `(px, py +
   CLEO_KILLY)` (`get_tile_attr` bit 7) hits her (`player_hit`, knocked by `facing`), through
   the invulnerability; `health` 0 is `player_dead`, else `player_update`.

### The player

`player_hit`: `ev_frame = frame`, `hurt = 1`, `control = 0`, `health--`, knockback `vx = +-
KNOCK_VX` (768) away from `hx`'s sign and `vy = JUMP_VY` (-1280), `SFX_HIT`.  `player_dead`:
falls (`fall2`), respawns after `RESPAWN_F` (30) frames at the start with `HEALTH_MAX` (3),
`lives--`; none left sets `exiting`.

`player_update`: `alt = get_altitude(px, py + CLEO_FEET)` (16: her feet).  A throw starts on
`K_DOWN` when on the ground, not `firing`, with `control` and no boomerang out.  Vertical:
rising or in the air -> `fall2`; on the ground, `K_UP|K_FIRE` with `control` jumps (`vy =
JUMP_VY`, `SFX_JUMP`), else she stands (`control = 1`) and `move2` applies.  The vertical move
is then made against the map: moving up, `py += dpx` and she is pushed out of any solid
(`alt < 0`); moving down, `dy = min(dy, alt)` with the altitude looked at again from where a
partial move lands (`@dlp`), so a frame's fall of up to `MAXFALL` can reach ground a tile
ahead.  Falling past `maph - CLEO_H` (24) kills her (`SFX_DIE`).  The push attribute at her
feet (`get_tile_attr`, bits 0-2 less `PUSH_BIAS`: -2..2, `PUSH_NONE` = 3 is none) then
friction -- ground `vx = vx*58>>6 + push*48` (two steps of the original's `vx*61>>6 +
push*24`), air `vx*3>>3` (two of `vx*5>>3`) -- then `K_LEFT`/`K_RIGHT` set `facing` and add
`ACC_GROUND` (72) or `ACC_AIR` (480, in the air or with no push tile), the pairs chosen so her
top speed is exactly `KNOCK_VX`.  The horizontal move is `2 * ((vx + 128) >> 8)` single
pixels, each with `get_altitude`: a slope step (`alt` -1..1) moves `py`, a wall (`alt < -1`)
stops her (`vx = 0`).  `dxl/dyl = px - pxs, py - pys` record the frame's whole move for the
objects' sweeps (section 4).  Animation: `anim += 2`; a throw launches the boomerang at `anim
= THROW_T1` (4: `bx/by = px/py`, `bvx = +-BOOM_VX` 3584, `bactive = 1`, `SFX_THROW`) and ends
at `THROW_END` (12); the run wraps at `RUN_ANIM` (16), the stand at `IDLE_ANIM` (128) with the
blink at `BLINK0`/`BLINK1`.  `hurt` clears after `HURT_F` (32) frames and `control` returns
after `CTRL_F` (13), by unsigned deltas from `ev_frame` (a signed compare once stuck the
flash).  The frame is one of `SPR_CLEO_*` plus `facing`; while hurt she is drawn on even
frames only.

Physics (`fall2`, `move2`, `move2g`, `fstep2`, `step1`, `gravity`): a step's gravity is `vy =
(vy + GRAV) * 31 >> 5` (`GRAV` = 80) and its move `(vy + 128) >> 8`, at most `MAXDWY0` (8)
down; the two steps' moves are summed into `dpx`, at most `MAXFALL` (12) down.  `fall2`
applies gravity to both steps, `move2` (a jump's or a stand's) to the second only when
rising, as the original's second step did.  No position between the two steps is kept.

The boomerang (`@boom` in `player_update`): `brel` sets `rx/ry` = Cleo less the boomerang
(`ry` + `BOOM_REF_DY`, 8); `bstep` per axis does `bv -= bv/16 + bv/64 + bv/128` (two steps
of 61/64), `bv += 4*r` (the pull) and returns the move `2 * ((bv + 128) >> 8)`; `bmove` makes
it at most `BOOM_STEP` (8) px at a time (`clamp8`), with `get_altitude` between, stopping in
the first solid (`bcnt = BCNT_HIT`).  `bdx/bdy` record the frame's move for `bsweep`.  `bcnt`
counts by 2: in flight 0..6 and round (its spin, frames `SPR_BOOM0 + bcnt/2`), from
`BCNT_HIT` (8) to `BCNT_GONE` (14) hit or stopped, then inactive.  The catch is `bsweep`
against `RQ_BOOM_STAR`.  Last the exit test: `0 <= px - exitx < EXIT_W` (16) and `0 <= py -
exity < EXIT_H` (24) sets `exiting`.

### `process_object` and the handlers

Y = the object.  The prologue stores `otype`, `spx/spy` (where it draws) and `rx/ry` (the
object less the player), then tail-dispatches by type: `jmp (@tab,x)` on the Master, `@tlo`/
`@thi` through `jv` on the Model B.  The thirteen entries: `ob_star ob_tramp ob_snake
ob_rsnake ob_bat ob_walker ob_walker ob_spike ob_none ob_flame ob_powerup os_vanish
os_switch`.  Handlers work on the arrays in place (Y reloaded from `obj` after `add_score`,
`bar_touch`, `player_hit`); the bat stages its velocity into `fc`/`fd`; the vanishing block
and the switch have wrappers (`os_vanish`: `fe`, `ox`, `oy`; `os_switch`: `fa..fd`) copying
the fields they touch.  Each handler's header lists its fields and constants (`logic.s`: the
constants block at the top names every rate and limit).  Notable:

- `ob_star`: collected (`O_CL`) runs the sparkle `SPARKLE0..SPARKLE_END`; alive, `csweep`
  against `RQ_STAR` collects (`SCORE_STAR`, `stars--`, `SFX_STAR`), else the boomerang's
  `bsweep` against `RQ_BOOM_STAR`; the spin frame is `(O_AL + star_clk) mod STARCLK >> 1`,
  drawn as a masked frame (`SPR_STAR0 + f`) or, with a box id in `O_EL`, through `box_safe`.
  `po_star` first tests `rx` against `STARBAND_LO..STARBAND_HI` (the guard band's x limits)
  and skips both tests when Cleo is far (`q2`).
- `ob_tramp`: the spring count `O_AL` (2, 4 .. `TRAMP_TOP`); `csweep` against `RQ_TRAMP`
  while falling gives `vy = TRAMP_VY` (-2048) and sets her `TRAMP_SINK` (6) px into the band;
  at rest with a box id (`O_EL`) it draws through `box_safe`, else the bounce frames.
- `ob_snake`: states 0 right, 1 left, 2-3 still, 4-5 dying (`SNK_DEAD`), two `@adv` steps a
  frame; a stomp (she is above and falling) kills it for `SCORE_SNAKE` and sets `bounce`.
- `ob_rsnake`: a dormancy counter `-127..RSNAKE_UP`, shown from `RSNAKE_SHOW` with the rise
  from `rise_tab` (`(A*A >> 3) - 28`, baked); knocked by the boomerang it flies with its pot
  (`@knocked`).
- `ob_bat`: chases within its hover rectangle (`fc`, `fd` clamped to 0..A, 0..B), the
  `bat_off` wobble by `frame` and `obj`; a stomp (`RQ_BAT_STOMP`, she was above by more than
  `BAT_STOMP_Y` where her move began) or the boomerang drops it (`BATFALL_A0`, `BAT_GRAV`).
- `ob_walker` (mask and mummy): patrols 0..A by `WALK_STEP` (3) a frame; `RQ_WALKER` is, across,
  the widest band where every Cleo frame overlaps every walker frame by a pixel (-8..8), and,
  down, the original's full height (-24..20) (the quad's comment in `assets.py`).
- `ob_spike`: a dormancy counter `-127..SPIKE_UP`, out below `SPIKE_OUT`; it writes its own
  hit box's x limit into `RNGTAB+RQ_SPIKE+1` from its height each frame.
- `ob_flame`: a frame every other rendered frame.  `ob_powerup`: with health below
  `HEALTH_MAX`, `RQ_POWERUP` restores it (`SFX_POWER`), then the pickup frames; at rest it is
  always a baked box through `box_safe`.
- `ob_vanish`: `RQ_VANISH` with `vy` = 0 starts the count; every `VANISH_EVERY`th count
  writes the frame's two tile ids from `LV_HDR+HDR_SPECIAL` with `map_put` and `mark_pair`.
- `ob_switch`: `RQ_SWITCH` scores `SCORE_SWITCH` and copies map columns A-2, A-1 to A, A+1 for
  rows B..B+C-1 (`map_tile`, `map_byte`, `map_put`, `mark_pair`).

Scores are BCD (`add_score` in decimal mode).  `rnd` is a 16-bit LFSR with taps `RND_TAPS`
($B4), seeded `RND_SEED` ($1234) at `game_main`.

### The map queries

The map is in bank 5 and this code in bank 7, so every touch goes through low RAM's
`map_row`/`map_col`/`map_byte`/`map_put` (the engine's `lowram.s`).  `map_tile` takes a row
from `MROWL`/`MROWH`.  The `altof` macro turns a tile id into its altitude byte at column `qx
& 7`: `LV_ALTCLS[id]` is the class, `alt_tab[cls*8 + (qx & 7)]` the byte (`alt.bin`, 9 classes
x 8 today).  `tilexy` turns `(qx, qy)` into tile coordinates with C set off the map.
`get_info` is the plain read (`ALT_OUTSIDE` = 8 off the map).  `get_altitude` returns the
signed altitude at a pixel -- the surface's distance below it, from the byte's nibbles (the
high nibble the surface row, 8 none; the low nibble where the solid ends) and, when the
column is solid to its top or empty to its bottom, the tile above or below, which `map_col`
fetched in the same visit.  It memoises the last tile (`mok`, `mkxlo..mkyhi`, `mt`, `ma`,
`mb`): more than half of Cleo's queries land in the tile the one before them did (57% when
measured), and skip the arithmetic and the bank-5 visit.  The memo is cleared at a level's
start and wherever the map is written (`mark_pair`).  `get_tile_attr` reads `LV_ATTR0[id]`:
bits 0-2 the push plus `PUSH_BIAS`, bit 7 kill (`convert.py attr_of`); off the map,
`PUSH_BIAS`.

## 4. The collision rule

No intermediate positions.  A frame moves Cleo up to two steps' worth, so a test at the end
position alone could miss an 8-px trampoline band under a 12-px fall or the corner a diagonal
cuts, and a test at a midpoint would be a position she never occupied.  The rule (`csweep`):
`in_range` where she is -- the hits, and quick -- and otherwise, if she moved (`dxl|dyl`), the
box between where she was and where she is against the quad (`sweep`: `span` on x over
`dxl`, then on y over `dyl`).  The boomerang's tests (`bsweep`) sweep its last move
(`bdx`/`bdy`) the same way, so it cannot pass through an enemy between frames; its flight is
made 8 px at a time with the map read between, so it stops in the first solid.

`in_range`: X = a quad's offset in `RNGTAB`; a quad is `lo, hi, lo2, hi2`, each stored
`+ RQ_BIAS` (128), tested open at both ends (`rx > lo && rx < hi && ry > lo2 && ry < hi2`)
as unsigned byte compares on `r ^ $80` after checking `r` fits a signed byte (anything wider
fails every limit).  `rbias` clamps a 16-bit `r` to -128..127 before biasing, so a span's end
past the table's range stays past every limit.

The quads are `assets.py RNGTAB_QUADS`, written to `assets.inc` as `RQ_<name>` offsets and to
every level file as its header tail (`pack_level`: `header_tail=RNGTAB`), which the loader
puts at `LV_HDR + HDR_LEN` -- `RNGTAB` in `GAMELVL`, one page, where `in_range`'s hot reads
need it.  A quad may be added anywhere, since `logic.s` names them; the one order rule is that
a guard band's boomerang quad follows its Cleo one at `+ RQ_BOOMOFF` (asserted).  Today's 22
quads fill `RNGTAB_LEN` (88) exactly: a new quad means raising `RNGTAB_LEN`, which `GAMELVL`
has 8 bytes left for (`__GAMELVL_SIZE__` $D8 of $E0).  `ob_spike` writes one entry at run
time (its x limit by its height).

The guard bands (`RQ_GUARD_STAR`, `RQ_GUARD_TRAMP`, `RQ_GUARD_PW` and their `GUARD_B*`
partners) are not "close enough to collect" but "the drawn rectangles touch": each object's
box grown by what Cleo (6 across, 14 up or down) or the boomerang (30 each way) moves before
it is drawn.  `box_safe` draws a box-drawn object under its still alias (`id + BOXN`, which
the engine keeps without redrawing when identical and unclipped) only when nothing can draw
through it: no enemy's range covers it (e1 in `O_EH`), Cleo is outside the guard band, and
the boomerang -- including a throw launching this frame from her position -- is outside its
band.

## 5. Objects and their packer-written fields

The original's object record carries extras only for types 2, 5, 6 (one byte), 4 (two) and 12
(three) (`convert.py parse_level`).  `assets.py pack_level` fills e0..e2 for the rest:

- e0, the box id: a star's class (`convert.py star_class`: 0 none -- drawn masked; 1 on a
  uniform sky neighbourhood -> `BOXID0`, the six sky boxes; 2 on uniform black -> `BOXID0 +
  NSTARF`), or its own baked slot `BOXID0 + NBOXART + TRMAX + NSTARF*k`; a trampoline's rest
  box `BOXID0 + NBOXART + slot`, or 0 for none; a powerup's box `BOXID0 + NBOXART + TRMAX +
  NSTARF*NSTAR + slot` (every powerup has one).
- e1, disturbable: an enemy's reach (`enemy_reach`, each type's drawn rectangle `TYPE_BOX`
  from the art plus its travel) covers the object (`star_reachable`, `box_reachable`), or
  another static object's drawn area meets it over every frame either can show -- then it is
  redrawn every frame (still a copy, never erased) rather than kept.
- e2, a star's phase in the spin: greedy in map order, each star taking the phase that keeps
  the widest moment of it and the stars within a screen of it narrowest (the spin's frames
  run from 7 byte columns to 1).

The powerups are listed last by `parse_level` so the grid walk reaches them first in their
cell and draws them under anything that passes; `pack_level` asserts no object that can be
drawn over a powerup's box is listed before it.  The object types `OT_*` and the sprite ids
`SPR_*` (the original's `dim` order, each animation's first frame and count) are
`convert.py`'s and reach `logic.s` through `assets.inc`.

## 6. The HUD

The bar has a fixed home outside the ring (`BARADDR`), so it stays put however the window
scrolls; its template -- icons, labels, blank digit slots -- is the `BAR` file (1280 bytes:
two char rows of 80 chars), which the loader reads with the game's image.  `bar_bg`
(`hook_image`) fills `BARCACHE` with a value no digit has, so every slot redraws.
`redraw_hud` (`hook_hud`, when `bar_dirty`) draws the nine slots: `lives` at `HUD_X_LIVES`
(18, slot `HUD_SLOT_LIVES`), `health` at `HUD_X_HEALTH` (46), `stars` as two digits at
`HUD_X_STARS` and `+ DIGIT_W` (74, 82), and `draw_score`'s five digits from the BCD `score`
at `HUD_X_SCORE` + 8 per slot (108..140, slots 8 down to `HUD_SLOT_SCORE0`).  `bar_digit`
compares the value with `BARCACHE[slot]` and skips an unchanged digit (a score tick moves one
digit; the other eight were copies for no pixels, 3.2% of a frame when measured).  A digit's
`DIGIT_PACKED` (16) bytes of `digits_art` -- a nibble per byte column and two game rows --
expand through `digtop`/`digbot` into 64 bar bytes at `BARADDR + x*4` and the row below.
`bar_touch` sets `bar_dirty`.  The packing is `assets.py _digits` (`digits.bin` 160 bytes,
`digtab.bin` 32, asserted to decode back exactly); the art is `convert.py`'s from `bar.png`,
and the icons sit `HUD_ICON_DX` (15) left of their digits (`bar_icon`: Cleo's head, the heart
-- the powerup's sprite, hue-rotated with it -- and the star).

## 7. The menus (`menu.s`)

`game_main` (`hook_title`) seeds `rnd` and clears `hi_score` and `max_level` (`ALLLEVELS`
sets `max_level` to `NLEVELS/2-1`).  `title_loop`: `title_menu` returns 0 start or 1 help
(`help_screen`).  `new_game`: `score` 0, `lives = health = LIVES` (3), `level_select` when
`max_level > 0`, `level = chosen*2`, palette black, `go_game`.  `menu_over` (`hook_over`):
`win_lose` (A = 1 won, 0 lost), then the title.  Every way out is `go_game`, with the stack
reset.

The screens are laid out for the Model B's 84 game pixels of window (the constants at the top
of `menu.s`: `MENU_LOGO_X/Y`, `MENU_ITEMS_Y`, `MENU_STEP`, `HELP_Y0`/`HELP_PITCH`,
`LEVEL_STEP`/`LEVEL_STEP_TIGHT`, `WL_*`, `BIGCLEO_*`).  The picture a menu shows is the window
and, above it, the bar's section (`MENU_BAND_PX`, 8 px: `menu_sections` points it at cleared
ring rows below the window, so it is black).  Each screen is centred in that whole picture by
`TITLE_DY`/`HELP_DY`/`WL_DY` = `max(0, ((VISLINES/2 - MENU_BAND_PX - INK_BOT - INK_TOP) / 2 + 2)
& $FC)`: never above the window's top, so on the Model B, laid out for its own window, they are
0.  `level_select` lists the names (`level_names`: `l0..l7`) `LEVEL_STEP` apart, or
`LEVEL_STEP_TIGHT` when all eight would not fit the window, its first row centred the same way
at run time.

`menu_begin`: palette black, wait for a pending flip, window at the origin, buffer 0 as work
buffer (`selbb`, `calc_ring`), `clear_ring`.  `menu_show`: the kernel's `menu_sections`,
`flip_req` and the wait, `cur_buf` = 1, `set_palette`.  `menu_keys`: one vsync, the keys newly
down.  `menu_list` draws a table of strings centred (`text_centred`) with a cursor
(`cursor_str`) that `K_UP`/`K_DOWN` move by redrawing only the cursor rows, and `K_FIRE|
K_RIGHT` selects.  `draw_text` (ptr, A = x even, X = y) draws `font_art`'s 40 glyphs (A-Z,
`>`, `<`, `/`, `.`, digits: `glyph_index`), 8 x 8 game pixels in logical colour 3
(`pair_tab`), on any pixel row (`draw_glyph_rows` splits a glyph across char rows); `_`
erases.  `draw_number` prints the score or hi-score x100 (`NUM_DIGITS` + "00", leading zeros
blanked).

The title pieces are run-length streams of their screen bytes in the screen's own order
(`convert.py title_rle`; `RLE_RUN`, `RLE_RUNBIAS`, `RLE_END` in `assets.inc`): `unpack` puts
a piece in `TBUF` (`TBUF_LEN`, the largest piece) and `blit` copies it a char row at a time
through `ring_addr7`, `BLIT_CHUNK` bytes at a go.  The pieces (`tp_lo/tp_hi/tp_cols/tp_rows`,
`title.inc`): `TP_LOGO`, `TP_YOU`, `TP_WIN`, `TP_LOSE`, `TP_CLEO0` + 0..7.  Everything the
menus draw is on black, so a piece has no mask.  `win_lose` silences the tune
(`music_stop`), draws YOU WIN or YOU LOSE (the lose words a row lower), big Cleo's frames
(`cleo_frame`: `BIGCLEO_WIN0 + ((WIN_SEQ >> (msel & 30)) & 3)` winning, `(LOSE_SEQ >> n) &
3` losing) with the next frame unpacked a frame ahead (`mbuf`) so what follows the vsync is
the copy alone, and the score and hi-score.

The tune: `title_menu` calls `music_start` when `mus_on` is clear; its player `music_tick` is
the engine's (`beebgame/src/engine/menus.s`, segment `MUSCODE` in the menus' image), stepped
from the interrupt while `mus_on`; `music_stop` is the kernel's and every load calls it, so
the interrupt never calls into the menus' image while the game's is in.  The stream is
`music.bin` from `build/MUSIC` (`midi2snd.py` over `thm.mid`).

## 8. The packer pipeline

`build.sh` runs `tools/assets.py` once per machine (`TARGET`, `BD`); it imports
`tools/convert.py`, which runs at import and writes `build/TILES0-2` and the previews.  The
level files are shared, so both runs must write them identically (the build `cmp`s them).

### `convert.py`, in order

1. **Levels.**  `parse_level(lv, sub)` reads file `lv` (0..7): sub 1 (the bonus, 'A') at
   offset 0, sub 0 (the main level, 'B') at `LEVELSKIP[lv]`; `lw, lh`, a big-endian `s16` map,
   `sx sy ex ey`, `nobj` and the objects.  The powerups are moved last.  `LEVEL_SOURCE`
   plays the original's level 5 as level 1 and 1 as 5 (their bonus maps stay; `menu.s`'s
   names follow).  The used tile ids plus the vanish run (366..373) and the flower variants
   (426..429) are `compact` (467 today).
2. **The dither.**  A game pixel is a 2x2 block of MODE 1 dots, each C, M, Y or K: per pixel
   the ink counts nearest its colour (gamma `GAMMA` = 1.35) laid in kernel order.  Tile
   overrides: `TIL_SOLID` (the sky to solid cyan), `TIL_RECOLOR` (the dune shadow), `TIL_NOBLACK`
   (empty), `TILE_EDITS` from `beeb/tile_edits.json` (`tools/tile_editor.py`).
3. **Blackening.**  What counts as backdrop comes from `alt`: `alt[tile*8+col] >> 4` is the
   surface row (8 none), everything above it backdrop (`bg_mask`).  A tile's backdrop goes
   black when at least `DARK_BG` (0.8) of its backdrop pixels are wall-ish (`_wallish`: near
   black, or dark and desaturated; the speckle families 70, 71, 102 added) or the tile is in
   `WALL_TILES`; `PIXEL_TILES` (the EXIT letters, the flower, the brace tips) are cleaned pixel
   by pixel.  66 tiles today.
4. **Ramp feet.**  A cell that blackens to all black, is not solid, and sits in a patch of at
   most four such cells each bounded below, left and right by solid tiles (or the patch) is a
   ramp's foot: it takes a rock image -- a `RAMP_ROCK` tile beside it (left, right, above),
   else what the original puts where the same eight neighbours occur (`_same_place`), else an
   adjacent foot's -- in a twin compact tile with the foot's own collision (`twin_of`).  7
   twins for 10 cells today; a foot with no donor stops the build.
5. **Tile bytes and classes.**  64 bytes a tile (two char rows of four chars).  `tile_solid`:
   all cyan 1, all black 2; every solid tile reduces to `SOLID_CYAN`/`SOLID_BLACK` (254/255)
   in a level.  `star_class` of a star's 2x2 tile neighbourhood.  Data-first renumbering
   (solids last, the two animated runs kept contiguous; `NDATA <= 512`), `special`
   (`VANISH0`, `FLOWER0`), `push_tiles` and `kill_tiles` (`attr_of`), the altitude classes
   (`alt_class`, `altfile`: 9 classes).
6. **The maps.**  One stream of random sand for every map, `np.random.RandomState(1234)`,
   taken in the ORIGINAL's order of the maps (`LEVEL_SOURCE`), so a map's sand is its own
   whichever level it is played as: tile 427 becomes 426..429 (the original randomises it at
   level start; the port at pack time, and `level_init` draws no `rnd` for it).  Then the
   ramp feet are substituted.
7. **The tile set.**  `tileset_of = lv & 1` (odd levels indoor).  Every distinct tile once,
   cut by who uses it -- outdoor only, both, indoor only -- into `TILES0`, `TILES1`, `TILES2`
   of at most `TILE_CHUNK` (256) tiles, most-used first (223, 61, 105 today).
8. **`pack_tiles(lv, sub)`**: the level's ids.  0 is the solid it uses more (cyan on ties,
   the fill byte `solidfill` $0F or $00 in the shape); 1..NT the full tiles, slot `id + TOFF`
   in bank 6; the halves in three runs (top row a fill, bottom row a fill, both rows the one
   stored), their fills from a palette of at most 8 pairs and `hlow` bits; `FLAT0..253` the
   flats (`NFLAT`, a build knob, default 4; more than that demotes the least used to full
   tiles); 254/255 the solids.  Identical tiles share an id (bytes, attribute and class).
   `_layout` asserts the fit; `_tilelist` and `halflist` tell the loader which set file holds
   what; `page0` is the Master's `LV_PAGE0` table of the pairs the Model B's gather computes.
9. **Sprites.**  `dim`'s 103 records `(x, y, w, h, refx, refy)`; crops; `SKIP` {102} (the
   BONUS LEVEL banner); the reds of the powerup (97) and the red snake (54..59) turned
   `RED_HUE` toward magenta (the HUD's heart turns with them); mirrored duplicates folded
   (`entry`: image, mirror, refx, refy; 71 images today); the stars' `refy` snapped to a
   multiple of 4 where it saves a char row; odd widths padded on the side leaving fewer
   half-opaque bytes; then the 4-bit form: fifteen 2x2 patterns `NIB_PATTERNS`, nibble 0
   transparent, a colour not among them taking the nearest in Lab, `NIBTAB` (768 bytes:
   `L0TAB`, `L1TAB`, `NMASK`).
10. **Boxes.**  The box stars: each spin frame over cyan and over black in a box just wide
    enough to cover its own art and its predecessor's (`_boxgeom`; a frame moves at most one
    step per render because a render is exactly two steps), `BOX_H` 12, 12 boxes.  The
    trampoline's frames (`TRAMP_IDS`, `TRAMP_HOT`); `bake_box` composites a frame over the
    level's own tiles (None over an animated tile or off the map); `bake_overlay` and
    `BAKE_KINDS`: kind 0 the trampoline at rest, 1..6 the star's frames, `PW_KIND` the powerup
    (its box starts at the tile row's bottom char row: the `skip` field).
11. **Font, bar, digits, title.**  The font: 40 glyphs 8x8 from `tit.png` at y = 26, ten a
    row, a bit a pixel.  The bar: `bar16`, the icons by `bar_icon`, dithered per scanline,
    1280 bytes; the digits from `bar.png` at `(63 + n%5*8, n//5*8)`.  The title pieces
    (`pieces`: the logo 80x26, YOU 38x13, WIN 39x13, LOSE 45x13, eight Cleo frames 26x31) as
    screen-order bytes, then `title_rle` (10880 bytes as 5394 today).  Previews:
    `preview_tiles/sprites/title/bar/level0/level1.png`, `meta.json`.

### `assets.py`

- The banks' fixed shape: `B4_CODE_END`/`B5_CODE_END` by hand (the packer runs before the
  assembler), asserted `=` on the Model B and `<=` on the Master by `sprloops.s` and
  `gather.s`; `B4_DATA_END`, `MAP5`, `TILES_BASE`, `STAGE_LEN`.
- The id space: `BOXID0 = NSPRITE` (103) images, then `BOXN = NBOXART + TRMAX + NSTARF*NSTAR +
  PWMAX` boxes (12 + 13 + 6*8 + 2 = 75), then the still aliases (`BOXID0 + 2*BOXN <= 256`).
  `RESIDENT_IDS` 0..45 (Cleo, the boomerang, the stars and sparkle, the trampoline);
  `ALWAYS_IDS` 0..42.
- `SPRC`: the resident images -- the mirrored ones in bank 4 (`c4`), the rest in bank 4 as
  room allows beside the biggest level's mirrored enemies, else bank 5's bottom (`c6`; empty
  today: `SPRC5_LEN` 0); re-placed at the end with `sprpack` padding into the spare room.
  `SPRX`: every other image, the 12 box arts and the bake overlays; `img_tab.bin` 5 bytes an
  item (file, offset, length) up to `BAKEITEM0` (83 today); `bake_geom.bin` (`BG_*` fields) and
  `bake_kind.bin` by slot.
- The directory template `sprdir` with the engine's flags (`SPF_MIRROR`, `SPF_FULLRES`,
  `SPF_COPY`); the geometry by shape to `sprgeom.inc` (`sprg_ix` by id, `sprg_w sprg_rx
  sprg_ry sprg_ln sprg_fl` by shape; 178 ids, 90 shapes today).
- `weights` from `tools/drawfreq.json`; `chunk_items` and `sprpack.optimise` with the cache
  `build/sprpack.cache`.
- `level_bakes`: trampolines (`TRMAX` slots, identical boxes sharing one), every powerup
  (`PWMAX`), the stars `CHOSEN` by the plan (section 9) within `NSTAR` and of class 0.
- `place_sprites`: regions `r4` (after `SPRC`, to `B4_DATA_END`) and `r6` (bank 5 above the
  resident part, to `MAP5`); boxes and mirrored images first, then the rest largest first;
  when a greedy order leaves a hole too small, up to 400 deterministic orders
  (`random.Random(trial)`) alternating the preferred bank.  `settle_level` reorders and pads
  within each region for the loops.
- `pack_level`: the header's game fields (`ghdr`), the objects' e-fields (section 5), the
  attribute and class tables by level id, `MAXSPR`/`BINMAX` over every camera position of both
  windows (`VISLINES_ALL`), the placement list (a baked item's tile `x | y << 8` in its
  extra), the directory, `lf.encode` with `header_tail = RNGTAB`, a decode check, and the
  per-level print line.
- `assets.inc`: `FLAT0 NFLAT BOXID0 BOXN SPRGFL BAKEITEM0 SPRC_* SPRX_LEN TOFF TP_* TBUF_LEN
  MAXSPRDEF BINMAXDEF MAP5 B4_CODE_END B5_CODE_END B4_DATA_END TILES IMGTAB_LEN BG_* HDR_*
  RNGTAB_LEN RQ_* STARBAND_* OT_* SPR_* BINPX HUD_X_* DIGIT_* RLE_* GLYPH*`.

## 9. The bake plans

Nothing baked is on the disc: the loader (`beebgame/src/ldprog.s bake`) makes each item from
BAKEITEM0 on from the level's own tiles where the object stands and an overlay a kind in
`SPRX` -- (backdrop AND mask) OR pixels -- at load.  Which stars are worth it comes from a
measured plan: `test/starplan.mjs` plays each level with the seeded key script, finds the
frames whose work misses the peg (3 vsyncs less the interrupt) and charges every masked star
drawn in them its draw and erase cycles, writing `tools/starbake.json`.  `assets.py`'s
`STARPLAN` block then takes stars greedily by vsyncs saved per byte of bank -- a frame's
vsyncs are `max(3, ceil(work / V))`, a bonus level's (a map of at most 32x32) counting a
quarter -- within each level's `NSTAR` slots and only while the placement still fits
(441 vsyncs saved over the plan's frames today; 44 stars and 72 trampolines baked).
`test/drawfreq.mjs` writes `tools/drawfreq.json`, the draws a frame per sprite id per level
that weight the placement.  `test/bakecheck.mjs` checks every baked item in the banks after
a load against the packer's bytes (`build/*/bakes.json`), on either machine.

## 10. Testing

The tests drive jsbeeb through `test/harness.mjs` (beebgame's `test/lib/harness.mjs` with
Cleo's scene and its way into a level: `open()` patches `title_loop` to start a game, runs to
`game_in` and sets the level as the game's image comes in) and `test/bopen.mjs openB()` for
the Model B (`BMODEL`, `BBOARD`, `BSWRAM`).  Every wait is "run to the next `frame_top`",
never a cycle count, so nothing in the protocol can observe code size; `fingerprint()`
proves two builds measured the same scene.

`sh test/snapshot.sh REF` keeps a build (the disc, each machine's labels, `game.dbg`,
`defs_ld.inc`); `sh test/sweep.sh REF [jobs]` runs 89 checks in parallel against it and prints
only what fails: for each of the 16 levels, the Master's displayable window and scene for 400
frames (`wincmp.mjs`) and 200 more after the level ends and loads again (`RELOAD=1`), the
Model B's two buffers' windows and the bar for 300 frames (`bwincmp.mjs`), and both with
seeded random keys, throws and all (`SEED=7`, 500 frames); level 8 on the Model B on emulated
Watford and Solidisk boards (`BBOARD`); the menus frame-synchronised at `menu_keys` on both
machines (`menusync.mjs`); the frame period through a load from the menu on the Master, the
8271 and the 1770 (`loadsync2.mjs`); and a whole session's stores into sideways RAM on each
board, every one to the bank paged (`boardcheck.mjs`).  `sh test/perfcmp.sh REF` compares
frame cost with a snapshot: the Master's bench medians (`bench.mjs`) and the Model B's
frame-matched medians (`bwork2.mjs`), levels 0 2 4 6.  The rest of the tools -- profilers,
checkers, the BeebEm lock-step -- are tabled in `beeb/README.md`.
