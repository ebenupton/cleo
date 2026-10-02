# The byte grind, round 2 (2 Oct 2026)

Every code file of both machines, cut into 130 regions (`tools/bytegrind/regions.py`,
up to 110 lines each, every line annotated with its measured cycles a frame on both
machines), was put to a farm of agents asked for **cycle-neutral byte savings**: one
surveyor per region (instruction level), and a second, structural one (shared tails,
cold duplication) on the 86 regions whose code lands in the full places -- bank 7's
game image and kernel, low RAM, LDPROG. 216 surveyors, nothing edited, nothing built
(`BRIEF.md`).

## Result

| | before | after | |
|---|---|---|---|
| Model B code and data (all banks, low RAM, LDPROG, LOADER) | 28,991 | 27,681 | -1,310 bytes |
| Master | 28,505 | 27,113 | -1,392 bytes |
| Model B bank 7 game image, spare | 21 | 796 | |
| frame work, 8 levels (linecyc, idle excluded): Model B | 79,179 | 78,373 | -1.0% |
| Master | 79,178 | 78,375 | -1.0% |

| candidates | 509 |
|---|---|
| kept | 256 |
| stale (an earlier edit took the lines) | 169 |
| changed the anonymous-label count | 65 |
| slower on a machine | 10 |
| changed behaviour | 5 |
| did not build | 2 |
| broke the sweep (bisected out) | 1 |
| no smaller | 1 |

Kept by file: logic.s 99, ldprog.s 47, kernel.s 20, menu.s 16, tiles.s 14, loader.s 12,
frame.s 12, sprloops.s 7, game.s 7, disc.s 7, menus.s 4, lowram.s 3, init.s 3, gather.s
2, macros.s 2, boot.s 1.  (The disc.s edits passed the sweep's load checks on the 8271,
the 1770 and the Master; they are the ones to watch on real hardware.)

## Pipeline

    node test/linecyc.mjs modelb|master <disc> <labels> <out.json> 0,2,...,14 100
    python3 tools/bytegrind/regions.py <lc_modelb.json> <lc_master.json> <dir> 110
    (the farm: BRIEF.md, one or two surveyors a region, structured candidates)
    python3 tools/bytegrind/apply.py <journal.jsonl> <work> 8

The applier: batches of 8, kept only when the batch builds, is smaller on one machine
and larger on neither (the code and data segments, LDPROG, LOADER), matches the base
frame by frame (statecmp on the Master, bwincmp on the Model B, levels 2, 8, 13; a
Master reload; a Watford board; both machines' menus, frame-synchronised) and costs
at most 4 cycles a frame over the last kept state and 8 over the base; a failing batch
is bisected.  Then the whole sweep against the base; a failure is bisected over the
kept edits replayed from HEAD and the culprit dropped (here b109s:0, an LDPROG edit
that broke every reload).  The run took 1 h 50 m.

## Lessons

- The Model B's sprite banks must end exactly at B4/B5_CODE_END.  An edit inside a
  macro expanded many times (the sprite loops' cells) moves them by far more than the
  surveyor's per-site claim: stepping the constants round the claim never converged.
  The applier now probes -- one build with those two asserts made warnings, the true
  ends read from its labels.
- The per-batch gate's one reload (level 2) passed an LDPROG edit that broke the reload
  of most other levels: the sweep's sixteen reloads caught it.  Loader edits need more
  than one level's reload.
- Verify against a forced full redraw too (both buffers invalid every frame): the
  displayed windows still match on both machines after the grind.
