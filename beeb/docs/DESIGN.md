# Cleo: the design

Cleo is a port of the 2004 J2ME platformer to the BBC Micro, on beebgame (the engine,
a submodule in `beebgame/`: its `docs/DESIGN.md` is the machine, the display, the
blitters, the loader and the level format).  This is the game's side: its sources,
how it meets the engine, its menus, its packer and its tests.

## The game's sources

| File | What |
|---|---|
| `src/main.s` | the root: the engine's sources and the game's, in order, and the hooks the engine calls (`hook_title`, `hook_play`, `hook_over`, `hook_image`, `hook_hud`) |
| `src/logic.s` | the logic: the player, the boomerang, the objects and their collision grid, the HUD (`bar_bg`, `bar_digit`, `redraw_hud`), `rnd` |
| `src/game.s` | the game loop from `level_loop`, `load_level`, the camera clamp, the sound effects (`sfx_tab`, resident) |
| `src/menu.s` | the menus' image: the top of the game loop (`game_main`, `title_loop`, `new_game`, `menu_over`) and the screens |
| `src/gamedata.s` | the tables: the altitude classes, the HUD's digits, the object state; the tune, the font, the title pieces |
| `src/keymap.inc` | the keys, for the engine's keyboard scan |
| `tools/convert.py` | the original game's data (`assets/v500/`, CleoV500.jar's contents) to the BBC's: art dithered to MODE 1, the maps, the objects, the tile set, the bar, the font, the title pieces |
| `tools/assets.py` | the packer: what goes in each level (written by beebgame's `levelfile.py`: the header's game fields HDR_STARTX..HDR_SPECIAL are Cleo's), SPRC, SPRX, img_tab.bin, assets.inc |

`build.sh` sets beebgame's build driver going (`beebgame/tools/build.sh`) with Cleo's
root, assets step and tune.

## The packer

The packer picks the tiles the map (and the animations) can show, merges the identical
ones, classes them full, half or flat and numbers them, and places the level's sprites
not in SPRC wherever they fit, largest first; when that greedy order leaves a hole too
small, it tries other orders, deterministically.

The sprites are beebgame's 4-bit format (NIBSPR, since 29 Sep 2026; `NIBSPR=0 sh
build.sh` builds the masked format as before): a game pixel is one of fifteen 2x2
patterns of MODE 1 dots, a nibble, 0 transparent, with no mask.  Cleo's dither already
turns each colour into one fixed pattern; the fifteen (`convert.py` NIB_PATTERNS) are
solid cyan, for the box stars' sky, and the fourteen of the dither's twenty-one that
lose least (a colour whose pattern is not among them takes the nearest in Lab: 3.4% of
the opaque game pixels).  The box stars and the trampoline's boxes are opaque 4-bit
images, drawn by the same blitter, so either bank takes any sprite, mirrored or not.
The boxes are screen bytes, drawn by the copy blitter, so the sky's box stars are exact.
Every trampoline's rest state is a box baked over its own backdrop (identical ones share
a slot), and so are the masked stars that cost the most vsyncs: `test/starplan.mjs`
finds the frames that miss the 3-vsync peg and what each star costs in them
(`tools/starbake.json`), and `assets.py` takes, greedily, the stars that save the most
vsyncs a byte of bank (a bonus level at a quarter), within each level's slots (8 stars:
the ids run out) and its banks.  The loader bakes them at load (beebgame `ldprog.s
bake`) from the level's tiles and an overlay a kind in SPRX (convert.py BAKE_KINDS),
so they cost nothing on the disc; `test/bakecheck.mjs` checks every one against the
packer's bytes on either machine.  Each object's box id is
in its e0 (logic.s: ob_star, ob_tramp), and a box-drawn object that overlaps another
static object is marked disturbable (e1), so it is redrawn rather than kept.
The directory is split (SPRGEOM): a level carries the images' addresses, and the
geometry, by shape, is `sprgeom.inc` in bank 7's GAMEDATA (`sprg_fl` carries the
mirror, Cleo's being by id).  Against the masked format: frame work -5.2% on the
Model B and -6.2% on the Master (every level faster), sprites 23.0K to 10.3K, bank 7
+443 bytes free, loads 2-3 seconds shorter.  (The masked format placed box stars and
trampolines in bank 5, for the copy blitter, and mirrored images in bank 4, SWAPTAB's.)  A box star's art is chosen by its star's class (on sky, the first
six boxes; on black, the second six), not by the level's set.  MAXSPR and BINMAX are
the maxima over every level of what the walk rectangle can cover from any camera
position (24 and 18).

The sprite banks' code ends are set by hand in `assets.py` (B4_CODE_END,
B5_CODE_END), because the packer runs before the assembler; `engine.s` asserts
them, so the build stops if the code moves.


## The menus

`menu.s` is the menus' image of bank 7: the top of the game loop (`game_main`,
`title_loop`, `new_game`, `menu_over`), the title, help, level select and win/lose
screens, the font, and the title tune with its player.  It draws into buffer 0 with
the window at the origin, the palette black until a page is finished and flipped in,
calling the kernel for the sections, the palette and `ring_addr7`.  On the Model B the
screens are laid out for its window, 84 game pixels tall.

Everything the menus draw is on black, so the title pieces (the logo, YOU, WIN, LOSE
and big Cleo's eight frames) have no masks and no blitter of the game's: each is a
run-length stream (`convert.py` `title_rle`: n < $80, n+1 literals; $80-$FE, n-$7D
copies of a byte; $FF the end) of its screen bytes in the screen's own order, a char
row at a time, which `unpack` puts in TBUF as a straight run and `blit` copies to the
screen a char row at a time.  Big Cleo is unpacked a frame ahead, so what follows the
vsync is the copy alone, which stays ahead of the beam (no torn frame: counted on both
machines).  The 11,574-byte masked title pack is 5,394 bytes of streams (each piece padded to whole char rows).

The tune is stepped once a frame from the interrupt: the vsync's `sound_tick` raises
mus_tick while mus_on is set, and the stub (the Model B's, with bank 7 already paged) or
the handler (the Master's, which pages it) calls `music_tick`.  `music_stop` (the
kernel's, called by every load) clears mus_on, so the interrupt never calls into the
menus' image while the game's is in.


## Testing

The tests drive jsbeeb through `test/harness.mjs` (beebgame's `test/lib/harness.mjs`
with Cleo's scene and its way into a level through the title), which breaks exactly at
`frame_top` (never polling cycles, which let key timing drift with code size), and
compare a build with a reference kept by `test/snapshot.sh`.  `sh test/sweep.sh REF`
runs, in parallel:

- every level on the Master: the displayable window and the scene, 400 frames, and 200
  more after the level ends and loads again (`wincmp.mjs`);
- every level on the Model B: both buffers' 21 rows at their own windows and the bar,
  300 frames (`bwincmp.mjs`), and a level on emulated Watford and Solidisk boards
  (`BBOARD`; jsbeeb models neither, so `bopen.mjs` wraps the CPU's stores);
- the menus on both machines, frame-synchronised at `menu_keys` (`menusync.mjs`);
- the frame period through a real load from the title (`loadsync2.mjs`): every CRTC
  frame must be 312 lines, on the Master, the 8271 and the 1770.

and, run on its own, `roundtrip.mjs`: whole sessions -- the title, a game lost, the
title, a game won, the title -- with bank 7's images swapped between, build against
build, on both machines and on the boards (`BBOARD`, `BSWRAM`).

Other tools: `bench.mjs` (the Master's render work at fixed positions, with scene
fingerprints so that only like scenes are compared; a few tens of cycles of spread is
page-crossing noise) and `benchcmp.mjs`; `bwork2.mjs` (the Model B's frame cost);
`hotvars.mjs` (every variable's accesses a frame: what zero page is worth);
`loadtime.mjs`; `tilecheck.mjs` and `btilecheck.mjs` (the drawn window against the
map's tiles, independent of the packer); `audit.mjs` (every store into sideways RAM, by
PC and bank: the sites whose write bank matters); `bboot.mjs` (the disc booted through
the title into a game, with sockets chosen by `BSWRAM`); and `test/hbeebem/`, a
headless BeebEm core that runs the Model B in lock step with jsbeeb (`bdump.mjs`) and
compares the state, the display RAM and the picture frame by frame.
