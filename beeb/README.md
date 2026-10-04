# Cleo for the BBC Micro: the developer's index

The port of the 2004 J2ME platformer *Cleo* to the BBC Model B (64K sideways RAM) and the
Master 128, on the beebgame engine.  One disc, `build/cleo.ssd`, serves both machines.  This
page is the map of `beeb/`: the layout, the build, how to run and test it, and the tables of
tools and tests.  The design is in `docs/DESIGN.md` (the game) and `beebgame/docs/DESIGN.md`
(the engine); `docs/REVERSE_ENGINEERING.md` is what the J2ME original yielded.

## Layout

    build.sh           Cleo's build: beebgame's driver with Cleo's root, assets step and tune
    src/               the game's sources: main.s (the root and the hooks), logic.s, game.s,
                       menu.s, gamedata.s, keymap.inc
    tools/             the asset pipeline (convert.py, assets.py), its measured inputs
                       (drawfreq.json, starbake.json) and the analysis tools (table below)
    test/              the checks and profilers on beebgame's jsbeeb harness; hbeebem/, the
                       headless BeebEm (table below)
    assets/            the original game's data: v500/ (CleoV500.jar's contents, the build's
                       input) and gx/ (the GX edition's, for reference)
    docs/              DESIGN.md, REVERSE_ENGINEERING.md; history/ (earlier plans and records)
    beebgame/          the engine (a git submodule): src/, cfg/, tools/, test/, docs/
    build/             generated: TILES0-2, MUSIC, LOADER, BOOT, cleo.ssd, sprpack.cache,
                       preview_*.png; modelb/ and master/ with each machine's labels.txt,
                       map.txt, game.dbg, assets.inc, sprgeom.inc, the level files L0-L15,
                       SPRC, SPRX, BAR, the bank images and the generated includes

## Building

Needs Python 3 with Pillow and numpy, and cc65 (`ca65`, `ld65`, `od65`); the tests need Node
with jsbeeb in the npx cache (`beebgame/test/lib/harness.mjs findJsbeeb`).

    git submodule update --init   # the engine
    sh build.sh                   # the tune, the assets, both machines, one disc: build/cleo.ssd

`build.sh` exports `GAME_MAIN GAME_SRC DISC_TITLE DISC_OUT GAME_NAME GAME_MUSIC GAME_ASSETS`
and runs `beebgame/tools/build.sh`, then copies the disc to `../cleo.ssd` (not with
`ALLLEVELS`).  Knobs: `NFLAT=n` (flat tiles a level, default 4; `convert.py`), `ALLLEVELS=1`
(a test build: every world on the level select, every bonus level taken), `SKIP_ASSETS=1`
(skip the tune and the packer; the driver's).  The driver assembles the sources twice (`BHW=1`
the Model B, `BHW=0` the Master) against one sector table, and stops on: shared files that
differ between the machines (`cmp` of SPRX, SPRC, BAR, L0-L15, `assets.inc`), a level file that
fails `levelfile.py check`, a bank-number or write-select patch that lands on the wrong byte,
loader headers that differ, and any segment or data label at different addresses on the two
machines (`layoutcheck.py`).  It prints the packer's per-level line, the sizes of the bank 7
pieces and `ls -l` of the outputs.

## Running

Boot `build/cleo.ssd` on a Master 128, or on a Model B with four 16K banks of sideways RAM
(any sockets; ROMSEL, or a Watford or Solidisk write-select board) and an 8271 or 1770 DFS.
In jsbeeb choose Master 128, or Model B with DFS 1.2 (8271) or the 1770 board; `test/bboot.mjs`
boots the Model B headless and watches it.  The headless BeebEm is `test/hbeebem/` (rebuild
it with `test/hbeebem/build.sh`: the checked-in binary predates the current `main.cpp`).

## Testing

    sh test/snapshot.sh REF     # keep the current build as a reference
    ...change something, sh build.sh...
    sh test/sweep.sh REF        # 89 checks, both machines, in parallel; prints what fails
    sh test/perfcmp.sh REF      # frame cost against the reference, levels 0 2 4 6

The sweep: every level on the Master (the displayable window and scene, 400 frames, and 200
after a reload) and on the Model B (both buffers' windows and the bar, 300 frames), both again
with seeded random keys (`SEED=7`, 500 frames), level 8 on emulated Watford and Solidisk
boards, the menus frame-synchronised on both machines, the frame period through a load
(Master, 8271, 1770), and every store into sideways RAM on each board.  Everything breaks at
`frame_top`, never at a cycle count (`beebgame/test/lib/harness.mjs`).

## Tools and tests

### `test/` (run `sh` and `node` from `beeb/`)

| file | purpose | usage |
|---|---|---|
| `sweep.sh` | the behavioural gate: 89 checks, both machines, in parallel, against a snapshot | `sh test/sweep.sh REF [jobs=7]` |
| `snapshot.sh` | keep a build (disc, labels, game.dbg, defs_ld.inc) as a reference | `sh test/snapshot.sh DIR` |
| `perfcmp.sh` | frame cost vs a snapshot: bench medians (Master), bwork2 medians (Model B) | `sh test/perfcmp.sh REF [levels="0 2 4 6"]` |
| `harness.mjs` | Cleo's harness over beebgame's: the scene, the way into a level via the title | `import { open } from "./harness.mjs"` |
| `bopen.mjs` | the same for a jsbeeb Model B (BMODEL, BBOARD, BSWRAM) | `const B = await openB({ level, model })` |
| `wincmp.mjs` | two Master builds' displayable window and scene, frame by frame (RELOAD=1, SEED=n) | `node test/wincmp.mjs <discA> <labelsA> <discB> <labelsB> <level> [frames=300]` |
| `bwincmp.mjs` | two Model B builds: both buffers' 21 rows at their windows and the bar (SEED=n, BBOARD) | `node test/bwincmp.mjs <discA> <labelsA> <discB> <labelsB> <level> [frames=300]` |
| `menusync.mjs` | the menus build vs build, frame-synchronised at `menu_keys` | `node test/menusync.mjs master\|modelb <discA> <labelsA> <discB> <labelsB>` |
| `loadsync2.mjs` | every CRTC frame's period through a real load (312 lines, or reported) | `node test/loadsync2.mjs master\|modelb <disc> <labels>` (BMODEL=B1770) |
| `boardcheck.mjs` | a write-select board's rule over a whole session: every SWRAM store to the bank paged | `node test/boardcheck.mjs watford\|solidisk <disc> <labels> [play-seconds=20]` |
| `roundtrip.mjs` | whole sessions build vs build: title, lose, title, win, title, with the image swaps (BBOARD) | `node test/roundtrip.mjs master\|modelb <discA> <labelsA> <discB> <labelsB> [pngdir]` |
| `statecmp.mjs` | two builds in lock step: every object's fields, Cleo's, the sprite list at each `frame_top` (STARANIM=1) | `node test/statecmp.mjs <discA> <labelsA> <discB> <labelsB> [frames=600] [seeds=1,2] [levels=0-15]` |
| `tilecheck.mjs` | the Master's drawn window against the level's tiles (ids from `tools/tileids.py`) | `node test/tilecheck.mjs <disc> <labels> <level> <frames> [idsdir=build/tileids]` |
| `btilecheck.mjs` | the same for the Model B's two rings (MIR=lo,hi) | `node test/btilecheck.mjs <disc> <labels> <level> <frames> [idsdir=build/tileids]` |
| `bakecheck.mjs` | the loader's baked boxes against the packer's bytes, every level | `node test/bakecheck.mjs master\|modelb [disc] [labels] [levels=0-15]` |
| `bench.mjs` | render work at fixed positions (`bench_locations.json`), jump and run, scene-matched | `node test/bench.mjs <level 0-7> [out.json] [disc] [labels]` |
| `benchcmp.mjs` | compare bench runs: scene agreement, then cycles | `node test/benchcmp.mjs <a.json> <b.json> ...` |
| `bench_locations.json` | the 97 bench positions (levels 0-7) | data for bench.mjs |
| `bwork2.mjs` | Model B frame cost, frame-matched (BDISC, BLABELS, BDUMP) | `node test/bwork2.mjs [frames=300] [seed=1] [level=0]` |
| `mwork.mjs` | the same on the Master (MDISC, MLABELS, MDUMP) | `MDISC=.. MLABELS=.. node test/mwork.mjs [frames=300] [seed=1] [level=0]` |
| `fwork.mjs` | a frame's work split logic/render, either machine; interrupt cycles a vsync | `node test/fwork.mjs master\|modelb <disc> <labels> [frames=300] [seed=1] [level=0] [dump.json]` |
| `logprof.mjs` | the logic's cycles by routine tree (FLAT=n, FULL=1) | `node test/logprof.mjs master\|modelb <disc> <labels> [frames=300] [seed=1] [levels=0] [depth=3]` |
| `isrprof.mjs` | the interrupt's time by line and routine; interrupts a vsync by kind | `node test/isrprof.mjs master\|modelb <disc> <labels> [level=0] [frames=200] [rows=30]` |
| `linecyc.mjs` | cycles and executions per source line, JSON for the grinds | `node test/linecyc.mjs master\|modelb <disc> <labels> <out.json> [levels=0,2,4,8,9] [frames=150]` |
| `cycprof.mjs` | branch and page-crossing cost per line; PHASEDUMP for padopt/blockopt | `node test/cycprof.mjs master\|modelb <disc> <labels> [levels=0,2,4,6] [frames=150] [rows=40] [cross\|taken\|line=file:line,...]` |
| `hotvars.mjs` | every variable's accesses a frame: what zero page is worth | `node test/hotvars.mjs master\|modelb <disc> <labels> [levels=0,4,8] [frames=200] [rows=40]` |
| `hotmap.mjs` | where a level misses its vsync peg, driven diagonally; JSON for `tools/hotmap.py` | `node test/hotmap.mjs modelb\|master <disc> <labels> <level> <out.json> [step=48]` |
| `drawfreq.mjs` | draws a frame per sprite id per level -> `tools/drawfreq.json` (the packer's weights) | `node test/drawfreq.mjs [frames=300] [out=tools/drawfreq.json]` |
| `starplan.mjs` | which stars to bake -> `tools/starbake.json` | `node test/starplan.mjs [frames=600] [seeds=1,2] [machine=modelb]` |
| `loadtime.mjs` | a level's first and second load time in CPU cycles | `node test/loadtime.mjs master\|modelb <disc> <labels> <level>` |
| `crtctime.mjs` | where every CRTC (and ACCCON, palette) write lands in the frame; `cmp` two logs | `node test/crtctime.mjs master\|modelb <disc> <labels> [level=0] [frames=60] > log`; `node test/crtctime.mjs cmp <logA> <logB>` |
| `audit.mjs` | every store into sideways RAM by PC and bank (the write-bank sites), Model B | `node test/audit.mjs [frames=300] [level=4]` |
| `bboot.mjs` | boot a Model B and watch it: screenshots, PC/bank sampled (BSWRAM) | `node test/bboot.mjs [model] [seconds] [outdir]` |
| `bdump.mjs` | jsbeeb's half of the BeebEm lock-step: per-frame state line, dumps, shots (BDISC, BLABELS) | `node test/bdump.mjs [frames] [seed] [level] [shotFrame] [outPrefix] [shotEvery]` |
| `blockopt.py` | the order of ENGCODE's blocks from cycprof's PHASEDUMP profile | `PHASEDUMP=build/pd_$m.json node test/cycprof.mjs ...` for both machines, then `python3 test/blockopt.py` |
| `padopt.py` | bank 7's pads (`pads.inc` PADB_xx/PADM_xx) from the same profile | same, then `python3 test/padopt.py [bytes_lo=-8] [bytes_hi=8]` |
| `hbeebem/` | a headless BeebEm core and harness for lock-step against jsbeeb (README.md, build.sh, main.cpp, cmpdump.py, cmpshots.py, the Win32 shim and stubs, Video.cpp.patch) | `test/hbeebem/build.sh`; `hbeebem --userdata DIR --disc cleo.ssd --labels labels.txt [--frames N] [--seed S] [--level L] [--shot F] [--shotevery K] [--out PREFIX]`; `python3 test/hbeebem/cmpdump.py hb.txt jb.txt`; `python3 test/hbeebem/cmpshots.py beebem.ppm jsbeeb.png [diff.png]` |

### `tools/` (the asset pipeline and analysis)

| file | purpose | usage |
|---|---|---|
| `assets.py` | the packer: every level file, SPRC/SPRX/img_tab, assets.inc, sprgeom.inc, the HUD, font, tune, title streams, bake tables | `python3 tools/assets.py` (from `beeb/`; TARGET and BD set by build.sh; run once per machine) |
| `convert.py` | the original's data (assets/v500) to MODE 1: dither, tiles and TILES0-2, maps, objects, sprites, boxes, bake kinds, bar, digits, font, title pieces, previews | imported by assets.py (not run alone) |
| `drawfreq.json` | draws a frame per sprite id per level (from test/drawfreq.mjs): placement weights | data, read by assets.py |
| `starbake.json` | the star bake plan (from test/starplan.mjs) | data, read by assets.py |
| `hotmap.py` | draw test/hotmap.mjs's result over the level map | `python3 tools/hotmap.py <hotmap.json> <out.png> [cell=16] [strip=512] [scale=2]` |
| `javadis.py` | Java class-file disassembler, no JVM | `python3 tools/javadis.py <file.class> [method-name-substring]` |
| `tile_editor.py` | Tk editor: hand-paint a tile's dither; writes `beeb/tile_edits.json`, which convert.py honours | `python3 tools/tile_editor.py [level] [main\|A]` (from `beeb/`) |
| `tileids.py` | what each tile id of each level should draw, for tilecheck/btilecheck | `python3 tools/tileids.py [outdir=build/tileids]` |
| `bytegrind/` (BRIEF.md, regions.py, apply.py) | the cycle-neutral byte grind: agent brief, region cutter, batch applier with sweep gate and bisection | `python3 tools/bytegrind/regions.py <lc_modelb.json> <lc_master.json> <outdir> [maxlines=110]`; `python3 tools/bytegrind/apply.py <journal.jsonl> <work> [batch=8]` |
| `cycgrind/` (regions.py, apply.py) | the cycle grind: hot regions from linecyc, applier gated by statecmp/bwincmp/linecyc | `python3 tools/cycgrind/regions.py <lc_modelb.json> <lc_master.json> <outdir> [cover=0.97] [maxlines=150]`; `python3 tools/cycgrind/apply.py <journal.jsonl> <work> <base_dir> [batch=10]` |

### `beebgame/tools/` (the engine's)

| file | purpose | usage |
|---|---|---|
| `build.sh` | the build driver: both machines, one disc, from a game's GAME_* variables; options in its header (MASTERONLY GAMEHAZEL GAMESOUND DRAWFLAGS TALLMAP TIGHTBSS ALLLEVELS MAXSPR, SKIP_ASSETS) | run by the game's build.sh |
| `mkdfs.py` | a DFS .ssd from a file list, or the sector table (files.inc) the loader reads | `python3 tools/mkdfs.py build out.ssd title name:path[:load[:exec]] ...`; `python3 tools/mkdfs.py table files.inc name:path ...` |
| `pincfg.py` | the Master's linker config pinned to the Model B's segment starts, to stdout | `python3 tools/pincfg.py <master cfg> <Model B game.dbg> > <pinned cfg>` |
| `layoutcheck.py` | fail if the two machines' segments or data labels differ (zero page without exception) | `python3 tools/layoutcheck.py [modelb_dir=build/modelb] [master_dir=build/master]` |
| `pagecheck.py` | every taken branch that crosses a page, by segment, with its source line | `python3 tools/pagecheck.py <build dir> [segments=SPR4CODE,...]` (ALL=1 lists every branch) |
| `sprpack.py` | sprite placement within a bank against page crossings, cached (build/sprpack.cache) | imported by the game's packer (`optimise`, `image_table`, `load_cache`, `save_cache`) |
| `levelfile.py` | the level file format: writer, reader/checker, the loader's constants | `python3 tools/levelfile.py inc`; `python3 tools/levelfile.py check <assets.inc> <level file>...`; `import levelfile` |
| `midi2snd.py` | MIDI to the three-voice 50 Hz note stream | `python3 beebgame/tools/midi2snd.py <in.mid> <out> [<voices>]` (default `1:max/0:min/0:min2`) |
| `codecmp.py` | compare two sources' code ignoring comments and layout | `python3 tools/codecmp.py old.s new.s` |

### `beebgame/test/`

| file | purpose | usage |
|---|---|---|
| `test_levelfile.py` | the level file writer against its reader, the RLE, the directory, the header tail, the constants | `python3 -m unittest discover -s beebgame/test` (11 tests) |
| `lib/harness.mjs` | the frame-exact jsbeeb driver: breaks at `frame_top`, bank/image aware, scene fingerprint, render-work meter | `import { Harness, findJsbeeb, loadLabels, loadBanks, dbgPath, imgOk } from ".../beebgame/test/lib/harness.mjs"` |
| `lib/boards.mjs` | Watford/Solidisk write-select boards emulated on a jsbeeb Model B; counts stores to the wrong bank | `boardEmu(cpu, "watford"\|"solidisk")` |

## Further reading

- `docs/DESIGN.md` -- the game: loop, logic, the collision rule, objects, HUD, menus, the
  packer, the bake plans, the tests.
- `docs/REVERSE_ENGINEERING.md` -- the J2ME original's formats and how they map.
- `beebgame/docs/DESIGN.md` and `beebgame/docs/GUIDE.md` -- the engine, and how to build a
  game on it.
- `docs/history/` -- earlier plans and records, kept as history.
