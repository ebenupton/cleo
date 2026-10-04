# How the J2ME Cleo was reverse-engineered for the BBC port

Written for the next port of a High Energy Magic game.  It records what is in the JAR, how
each resource is decoded, how it maps onto the BBC engine, and the traps that cost time.  The
formats are the ones `tools/convert.py` implements: it is the executable form of this note,
and its comments carry the detail.

## 1. The JAR

Two builds exist, `CleoV500.jar` and `Cleo_GX_EN.jar`, both unzipped in the repository as
`assets/v500/` (the build's input) and `assets/gx/` (reference).  The V500 contents (sizes
from `ls -l assets/v500`):

| file | bytes | what |
|---|---|---|
| `CleoApp.class` | 33,589 | the whole game, obfuscated; all the logic is in `CleoApp.run()` |
| `a.class`, `b.class` | 2,308 / 3,232 | the canvas and a helper |
| `0` .. `7` | 18,725-19,003 | one file per world: the bonus level's record, then the main level's |
| `til.png` | 11,442 | the tile sheet: 8x8 tiles stacked vertically, indexed colour |
| `spr.png` + `dim` | 9,856 + 618 | the sprite sheet and 103 six-byte records `(x, y, w, h, refx, refy)` |
| `alt` | 4,096 | 512 tiles x 8 bytes: the collision profile per pixel column |
| `bar.png` | 1,385 | the status bar and the digits |
| `tit.png` | 3,351 | the logo, YOU/WIN/LOSE, big Cleo's frames and the 40-glyph font |
| `icon.png` | 270 | the midlet icon |
| `snd` | 209 | the sound-effect table |
| `thm.mid` | 2,649 | the theme as standard MIDI |

The GX build has `CleoCanvas.class`, `Engine.class`, a raw `til` (77,376 bytes) and a `pal`
(512) in place of `til.png`.  Check the counts before assuming anything: `dim` / 6 = sprites,
`alt` / 8 = tiles, and how many numbered level files there are.

## 2. Getting at the code

Java is not installed here, so two routes were used:

1. The CFR decompiler, when a JRE was to hand: readable `CleoApp.java`, by far the best way
   in -- `run()` reads as C-like Java with obfuscated names.
2. `tools/javadis.py`, a class-file disassembler in pure Python (constant pool, fields,
   methods, bytecode with resolved names), for the questions the port raised later:

       python3 tools/javadis.py assets/v500/CleoApp.class [method-name-substring]

Reading tips: obfuscated field names collide (`a`, `b`, ...) but their descriptors do not
(`a:[B` vs `a:[I`), so grep the disassembly for `getfield CleoApp.a:[S` and the like to follow
one variable.  Constants are the signposts: `bipush 8`, `iconst_3 ishl`, `sipush 441` (the win
screen's frame sequence, `menu.s WIN_SEQ`) locate the code that uses them.  `logic.s` cites
the places it settled this way (`CleoApp.run 2865: bipush -16, if_icmple` for the red snake's
`RSNAKE_SHOW`; `case 7` for the spike's knock direction; `case 3` for the dormancy idiom).

## 3. The formats

All numbers are big-endian (Java `DataInputStream`).  Coordinates are game pixels, a tile 8x8;
an object, the start and the exit are stored in tiles.

### 3.1 Level files (`parse_level`)

Each file holds two records back to back, the bonus level first: the port reads the bonus
at offset 0 and the main level at `LEVELSKIP[lv]`, the parsed length of the bonus record.

    u8  lw, lh                 the map is (1<<lw) x (1<<lh) tiles
                               (32x32 bonus; 256x32, 128x64, 64x128 main)
    s16 map[h][w]              tile ids into til.png (-1 empty), row-major
    u8  sx, sy, ex, ey         start and exit in tiles; the player is placed at (sx*8, sy*8)
    u8  nobj
    per object: u8 type, x, y  then extras by type:
                               2, 5, 6 -> 1 byte;  4 -> 2 bytes;  12 -> 3 bytes

The types (`convert.py OT`, `logic.s process_object`'s table): 0 star, 1 trampoline, 2
snake, 3 rising snake in a basket, 4 bat, 5 mask, 6 mummy, 7 spike, 8 none, 9 flame, 10 health
powerup, 11 vanishing block, 12 switch.  The extras are the parameters (`level_init`: a
patrol's far end x 8 for 2/5/6, the bat's hover rectangle x 16, the switch's A/B/C); read the
handler in `run()` to see how each is consumed.  Levels: the port plays the original's level 5
as its level 1 and 1 as 5 (`LEVEL_SOURCE`); file index = 2 x level + sub, even main ('B'),
odd bonus ('A').  `OBJ_MAX` is 149, which the biggest level (L7B, file 14) reaches.

### 3.2 Collision: `alt` and the tile attributes

`alt[tile*8 + col]` is the column's profile: the high nibble is the surface row from the
tile's top (8 = no ground), which is all the converter reads (`bg_mask`, `_solid`); the engine
(`logic.s get_altitude`) reads the low nibble too, where the solid part ends, and looks into
the tile above or below when a column is solid to its top or empty to its bottom.  A full solid
tile is $08 and an empty one $80; off the map reads as `ALT_OUTSIDE` = 8 (solid).  This is the
only collision data: floors, walls and slopes all come from it, sampled at a few points about
the player and the objects.  The port deduplicates the 8-byte rows into classes (9) and gives
every level an id -> class table (`LV_ALTCLS`) over the global `alt_tab`.

The tile attributes are not in a file; they are constants in the code: push tiles `412, 413 ->
-1; 414, 415 -> +1; 423 -> -2; 424 -> +2; 439..442 -> 0` and kill tiles `101, 336`
(`push_tiles`, `kill_tiles`).  Expect the next game to have its own list: search `run()` for
compares against tile ids (`sipush 412`) near the map lookup.  Two animated runs are tiles
too: the vanishing block 366..373 and the flower variants 426..429 (`special`); the original
randomises 427 at level start.

### 3.3 Tiles and sprites

`til.png` is indexed; tile t is rows `t*8 .. t*8+7`.  Of the 512 tiles 467 are used (the
`compact tiles:` print).  `spr.png` + `dim`: a record's `(refx, refy)` is the hotspot placed
at the object's `(x*8, y*8)`, so the image's top-left is `(x*8 - refx, y*8 - refy)` (signed
bytes: `struct 'BBBBbb'`).  Frames are addressed by id in the code; `convert.py SPR_IDS` has
each animation's first frame and count (Cleo 0..26 run/stand/idle/throw/jump/mid/fall/dead,
boomerang 27, stars 34, sparkle 40, trampoline 43, snake 46, red snake 54 and basket 60, bat
61, mask 67, mummy 76, spike 85, flame 93, powerup 97, pickup 98, switch 100).  Mirrored
variants are separate ids in `dim`; the port folds horizontally mirrored duplicates (71
images).  Sprite 102, the BONUS LEVEL banner, is skipped (`SKIP`).  The transparent index is
the PNG's `transparency` entry.

### 3.4 Title, font, bar, sound

`tit.png` (`pieces`): the logo at (0, 0) 80x26, YOU (0, 58) 38x13, WIN (38, 58) 39x13, LOSE
(0, 71) 45x13, nine 26x31 Cleo frames from (0, 85) three a row (the ninth is never shown), and
the 40-glyph 8x8 font from y = 26, ten a row: A-Z, `>`, `<`, `/`, `.`, digits.  `bar.png`: the
bar backdrop, the digits 0..9 at `(63 + n%5*8, n//5*8)`, the background indices `BAR_BG`; the
icons are crops of the sprites (Cleo's head = sprite 0, the heart = 97, the star = 34).
`thm.mid` is ordinary MIDI; `beebgame/tools/midi2snd.py` reduces it to three voices at 50 Hz
(Cleo's `1:max/0:min/0:min2`: the melody the highest note of channel 1, the backing the two
lowest of channel 0).  `snd` was not decoded: the port's effects are authored in `game.s`
(`sfx_tab`, the `SFX` macro's chip latches).

## 4. The logic

Port `run()` section by section, keeping the original's integer arithmetic exactly: 16-bit
positions, velocities in 1/256 px, and its constants (`logic.s`: gravity `GRAV` 80 a step
with `(vy + GRAV) * 31 >> 5`, jump -1280, trampoline -2048, knockback and top speed 768, the
throw 3584, the boomerang's 61/64 drag).  Every place the port "improved" a formula later
turned out to be a bug.  Learned the hard way:

- The original is fixed-step at 25 Hz.  The port renders at 3 vsyncs (16.7 Hz) and makes one
  update a rendered frame composing two of the original's steps: every rate doubled, every
  timer halved (`game.s frame_loop`, `logic.s game_frame`).  Where the two steps' positions
  mattered -- the trampoline band, the bat stomp -- the test is swept over the frame's move
  (`csweep`), never taken at a midpoint (`docs/DESIGN.md` section 4).
- Timers compare frame counters with unsigned deltas (`frame - ev_frame`); a signed compare
  stuck the hurt flash after the counter wrapped.
- Collision probes need the full 16-bit `>> 3`; 8-bit shortcuts break past x = 256.
- The bat's position is never stored back: `run()` re-reads the home position and draws at
  it plus half the velocity, so it stays in its rectangle however far the player runs
  (`convert.py`'s margin comment, `ob_bat`).
- Objects that rewrite the map (vanishing blocks, switches) run inside the grid walk: keep
  their scratch apart from the walk's cursor (`q4`/`q5`, not `gx`/`gy`).
- Positions: `(sx*8, sy*8)` is the hotspot; Cleo's `refy` is 11, so her feet are at `y + 16`
  (`CLEO_FEET`).  Sprites drawn at tile-aligned y start `2*refy` scanlines into a char row,
  which is why the stars' `refy` is snapped (`convert.py`).
- The original's object record carries no extras for types 0, 1 and 10; the packer writes
  its own there (`assets.py pack_level`: e0 a box id, e1 disturbable, e2 a star's phase).

## 5. How it maps

| JAR resource | converter | what the engine gets |
|---|---|---|
| `0`..`7` | `parse_level`, `LEVEL_SOURCE`, the maps, `pack_tiles`, `assets.py pack_level` | `L0..L15` (beebgame's level file: header with Cleo's `HDR_*` fields and the `RNGTAB` tail, objects with e0..e2, attribute and class tables, tile lists, placement, RLE map, directory, `LV_PAGE0`) |
| `til.png` + `alt` | the dither, blackening, ramp feet, `pack_tiles` | `TILES0-2` (the set, outdoor/shared/indoor), each level's id layout, `alt.bin` (`alt_tab`), `LV_ALTCLS`, `LV_ATTR0` |
| `spr.png` + `dim` | `images`/`entry`, the 4-bit form, `NIBTAB`, the boxes, `BAKE_KINDS` | `SPRC`, `SPRX`, `img_tab.bin`, `nibtab.bin`, `sprgeom.inc`, `bake_geom.bin`, `bake_kind.bin` |
| `bar.png` | `bar16`/`bar_icon`, `digits`; `assets.py _digits` | `BAR` (1280 bytes to `BARADDR`), `digits.bin`, `digtab.bin` |
| `tit.png` | `font`, `pieces`, `title_rle` | `font.bin`, `title.bin` + `title.inc` |
| `thm.mid` | `beebgame/tools/midi2snd.py` | `build/MUSIC` -> `music.bin` (`music_addr`) |
| `snd` | -- | `game.s sfx_tab`, re-authored |
| `CleoApp.run()` | by hand | `logic.s`, `game.s`, `menu.s` |

## 6. Tooling that paid for itself

- `tools/convert.py`, imported by `tools/assets.py` (the build runs that; neither is run
  alone except `convert.py` for its previews).  Look at `build/preview_*.png` before
  touching the 6502 side.
- `tools/javadis.py` (section 2).
- `tools/tile_editor.py`: hand-paint a tile's dither; writes `beeb/tile_edits.json`, which
  the converter honours.
- The jsbeeb harness (`beebgame/test/lib/harness.mjs`, `test/harness.mjs`, `test/bopen.mjs`):
  the emulator driven from Node with an exact break at `frame_top`.  Scripted play with
  memory and framebuffer inspection beat manual testing every time; the checkers in
  `test/` (`tilecheck.mjs` against `tools/tileids.py`, `statecmp.mjs`, `wincmp.mjs`) are
  what settled each object handler.
- `test/hbeebem/`: a headless BeebEm in lock step with jsbeeb, for what one emulator alone
  cannot settle (the CRTC's and the boards').

## 7. Checklist for the next game

1. Unzip; list the resources; confirm the counts from `dim`, `alt` and the level files.
2. Decompile (CFR if a JRE is available, else `javadis.py`); find the level parser by its
   `readUnsignedByte`/`readShort` cluster and confirm the record layout above -- the object
   type -> extras table most of all, it is what will differ.
3. Extract the tile-id constants (push, kill, animated runs) and the sprite-id bases from the
   object handlers.
4. Run the converter on the new assets and look at the previews before any 6502 work.
5. Port the handlers one at a time against the decompiled source, each verified by a
   scripted headless run (spawn, walk, collect) rather than by eye.
6. Keep snapshots (`test/snapshot.sh`) of milestones and sweep against them; the display,
   loader and blitters are the engine's, so only the logic and the converter's tables
   should need real work.
