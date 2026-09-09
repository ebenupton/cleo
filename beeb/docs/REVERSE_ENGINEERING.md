# Memo: how the Cleo J2ME engine was reverse-engineered for the BBC port

Written for the next port of a game on the same High Energy Magic engine. It records what
was in the JAR, how each piece was decoded, which tools did the work, and the traps that
cost time. The formats below are the ones `beeb/tools/convert.py` implements; it is the
executable version of this memo and should be your starting point.

## 1. Anatomy of the JAR

Two builds existed (`CleoV500.jar`, `Cleo_GX_EN.jar`); the V500 one was used. Unzipped:

| file | size | what it is |
|---|---|---|
| `CleoApp.class` (33 KB), `a.class`, `b.class` | | the whole game. Obfuscated: `a`/`b` are the canvas and a helper; **all game logic is in `CleoApp.run()`** (6.9 KB of bytecode, one giant method) |
| `0` … `7` | ~19 KB each | one file per world: **bonus level first, then the main level**, back to back |
| `til.png` | 11 KB | tile sheet, 8×8 tiles stacked vertically, indexed colour |
| `spr.png` + `dim` | 10 KB + 618 B | sprite sheet plus 103 six-byte records `(x, y, w, h, refx, refy)` |
| `alt` | 4096 B | 512 tiles × 8 bytes: **altitude profile** per pixel column (collision) |
| `bar.png`, `tit.png`, `icon.png` | | status bar, title logo + font + win/lose pieces, midlet icon |
| `snd`, `thm.mid` | 209 B, 2.6 KB | sound-effect table and the theme as standard MIDI |
| `pal` (GX build) | | palette |

The other engine game will almost certainly have the same set with different sizes. Check
`dim` length (÷6 = sprite count), `alt` length (÷8 = tile count) and how many numbered
level files there are before assuming anything.

## 2. Getting at the code

Java is not installed on this Mac, so two routes were used:

1. **CFR decompiler** (first session, when a JRE was to hand) → readable `CleoApp.java`.
   This is by far the best way in: the run loop reads as C-like Java with obfuscated names.
2. **`beeb/tools/javadis.py`** — a 120-line class-file disassembler in pure Python (constant
   pool, fields, methods, bytecode with resolved names). No JVM needed. Used later to settle
   questions the port raised (e.g. "does the original really place the player at `sy*8`?" —
   yes: `readUnsignedByte() << 3` four times, at `run()` offsets 477–511).

Reading tip: obfuscated field names collide (`a`, `b`…) but their *descriptors* don't
(`a:[B` vs `a:[I` vs `a:Lb;`), so grep the disassembly for `getfield CleoApp.a:[S` etc. to
follow one variable. Constants are the signposts: `bipush 8`, `iconst_3 ishl`, `sipush 441`
(the win-screen animation pattern) locate the code that uses them.

## 3. Decoding the resources

All numbers are big-endian (Java `DataInputStream`), all coordinates are in **game pixels**
where a tile is 8×8 and an object/spawn/exit is stored in tiles.

### 3.1 Level files (`0`…`7`)
Each file holds two level records; the second starts where the first ends, so parse
sequentially (the port hard-codes the offsets as `LEVELSKIP` — they are just the parsed
length of the bonus record).

```
u8  lw, lh               map is (1<<lw) x (1<<lh) tiles   (32x32 bonus; 256x32 / 128x64 / 64x128 main)
s16 map[h][w]            tile ids into til.png (-1 = empty), row-major
u8  sx, sy, ex, ey       start / exit in tiles; player is placed at (sx*8, sy*8)
u8  nobj
per object: u8 type, x, y  then type-dependent extras:
             types 2,5,6 -> 1 byte    type 4 -> 2 bytes    type 12 -> 3 bytes
```
Object types as implemented in `logic.s` (`@tab`): 0 star, 1 trampoline, 2 snake, 3 rising
cobra (out of a basket), 4 bat, 5/6 walkers, 7 spike, 8 none, 9 flame, 10 power-up,
11 vanishing block, 12 switch. The extras are the per-type parameters (patrol range,
timer phase, switch target…) — read the handler in `run()` to see how each is consumed.

Only 467 of the 512 tile ids are used; the port renumbers them ("compact ids") and
keeps the two animated runs contiguous (vanish 366–373, flower variants 426–429, the
latter randomised at level start exactly as the original does).

### 3.2 Collision: `alt` and tile attributes
`alt[tile*8 + column]` = ground height in that pixel column: 128 = no ground, otherwise
the altitude (8 = solid full tile; other values give slopes). This is the *only* collision
data — walls, floors and slopes all come from it, sampled at a few points around the
player and objects (`getinfo`/`getaltitude` in `logic.s`). The port deduplicates the 8-byte
rows into classes (`ALTCLS` + `ALTTAB`).

Tile attributes were not in a file; they were **constants in the code**: conveyor "push"
tiles `(412,413 → −1) (414,415 → +1) (423 → −2) (424 → +2) (439–442 → 0)` and kill tiles
`101, 336` (lava). Expect the next game to have its own list — search `run()` for
comparisons against tile ids (`sipush 412` style) near the map lookup.

### 3.3 Tiles and sprites
`til.png` is indexed; tile *t* is rows `t*8 .. t*8+7`. `spr.png` + `dim`: each record's
`(refx, refy)` is the hotspot — the point placed at the object's `(x*8, y*8)` — so the
image's top-left is `(x*8 − refx, y*8 − refy)`. Sprite frames are addressed by id in the
code (`adc #34` = star frames 34–39, `adc #54` cobra, `adc #61` bat, Cleo 0–26 with
run/stand/fire/jump/knockback sets), mirrored variants are separate ids in `dim` and the
port collapses horizontally-mirrored duplicates. The transparent index is the PNG's
`transparency` entry.

### 3.4 Title, font, bar, sound
`tit.png` holds the logo pieces and a 40-glyph 8×8 font (A–Z, `>`, `<`, `/`, `.`, digits)
starting at y=26, ten per row. `bar.png` is the status bar backdrop; icons are just crops
of the sprites (Cleo head = sprite 0, heart = 97, star = 34). `thm.mid` is ordinary MIDI
(`midi2snd.py` reduces it to melody + two lowest chord notes at 50 Hz). `snd` is the SFX
table; the port re-authored the effects by ear rather than decode it.

## 4. Understanding the logic

The approach that worked: **port `run()` section by section, keeping the original's
integer arithmetic exactly** (16-bit positions, velocities in 1/256 px with the original
constants — gravity `+80`, drag `*31>>5`, jump `−1280`, etc.). Every place the port
"improved" a formula later turned out to be a bug. Specific things learned the hard way:

- The frame loop is fixed-step; the original runs 25 Hz logic. Timers compare frame
  counters with *unsigned* deltas (`frame − evframe`); a signed compare made the hurt
  flash and control lock stick after the 8-bit counter wrapped.
- Collision probes need full 16-bit `>>3` shifts — 8-bit shortcuts break past x = 256.
- The original clips sprites per pixel; objects legitimately sit partly off the top of
  the playfield (a star's bottom four scanlines under the status bar are *not* a bug).
- Objects that rewrite map tiles (vanishing blocks, switches) run inside the object grid
  walk; keep their scratch separate from the walk's cursor.
- Positions: `(sx*8, sy*8)` is the hotspot, Cleo's `refy` is 11, so her feet are at
  `y+16`; sprites drawn at tile-aligned y always start 2·refy scanlines into a char row
  (only matters for the BBC blitter).

## 5. Tooling that paid for itself

- `tools/convert.py` — the one-shot asset pipeline (levels → packs with per-row page
  tables, tiles/sprites → MODE 2 with the ordered dither, bar/font/title). Re-run it by
  hand: `build.sh` does not.
- `tools/javadis.py` — bytecode disassembler (see §2).
- Headless jsbeeb harnesses (`tools/profile.mjs`, `spawncheck.mjs`, `spritelog.mjs`,
  `barfrag.mjs`): the emulator core driven from Node with an instruction hook. Scripted
  play + memory/framebuffer inspection beat manual testing every time — the spawn probe
  found the page-table bug in one run, the framebuffer-vs-memory diff proved the "bar
  fragment" was a sprite, the IRQ raster trace found the CRTC chain desync.
- `tools/tile_editor.py` — hand-override dithered tiles that the automatic dither mangles.

## 6. Checklist for the next game

1. Unzip; list resources; confirm counts from `dim`/`alt`/level files.
2. Decompile (CFR if a JRE is available, else `javadis.py`); find the level-parse code by
   the `readUnsignedByte` / `readShort` cluster and confirm the record layout above —
   especially the **object type → extras** table, which is the part most likely to differ.
3. Extract the tile-id constants (push/kill/animated runs) and any sprite-id bases
   (`adc #n` style) from the object handlers.
4. Run `convert.py` on the new assets; look at the `preview_*.png` outputs before touching
   the 6502 side.
5. Port the object handlers one at a time against the decompiled source, verifying each
   with a scripted headless run (spawn, walk right, collect) rather than by eye.
6. Keep `cleo_oneshot.ssd`-style snapshots of milestones; the CRTC/ISR layer is shared,
   so only `logic.s` and the converter's tables should need real work.
