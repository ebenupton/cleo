# The byte grind (25-26 Sep 2026)

Every 32-instruction contiguous block of both targets (stride 1: 8,710 windows over
`src/*.s` and `modelb/src/*.s`) was put to a farm of agents, each asked for a smaller,
cycle-neutral implementation. 88 regions (76, with three that stalled split into 12);
one surveyor and one adversarial reviewer per region.

| stage | count |
|---|---|
| candidates proposed | 728 |
| survived review (accept or fix) | 721 |
| applied and verified | 438 (440 applied, 2 later removed) |
| stale: lines already rewritten by an earlier, larger edit | 238 |
| no measured byte saving | 16 |
| moved an anonymous branch outside the edit | 14 |
| failed the behavioural gate | 7 |
| did not assemble | 6 |

The review was nearly useless as a filter (7 rejections in 728); the mechanical gates
did the work, and two edits got past them (below).

## Result

| target | before | after | saved |
|---|---|---|---|
| Master (all segments) | 19537 | 18304 | 1233 |
| Model B (banks, low RAM, LDPROG, LOADER) | 32708 | 30251 | 2457 |

Model B free space: bank 7 (B7) 31 -> ~1327 bytes; bank 5's B5X 3 -> ~212; LOWCODE
0 -> 26. Frame cost fell on both (Master render -1.3k to -1.6k cycles a frame, logic
-0.5k to -0.8k; Model B median frame -3.4k to -12.3k), mostly from the Model B's 3-byte
`bra` and 5-byte `stz` expansions.

## Files

- `BRIEF.md` -- what every surveyor was told (the dual-target rules, the hazards)
- `CANDIDATES.md` / `merged.json` -- every candidate, with its reviewer's verdict
- `applied.json` -- every apply attempt in order, its outcome and measured saving;
  `line_now` is where it landed, so `tools/grind_bisect.py` can replay any prefix
- `SPACE.md` -- the segment map the surveyors worked from

## Pipeline

    python3 tools/regions.py 32 128      cut the regions (build/grind/regions)
    (the farm: one surveyor + one reviewer per region, brief BRIEF.md)
    python3 tools/grind_merge.py <journal.jsonl>...   -> build/grind/merged.json
    python3 tools/grind_apply.py         serial: locate, anon check, build both, measure
                                         bytes, tools/gate.sh; revert on any failure
    python3 tools/grind_bisect.py <dir> N [--skip k,...]   replay the first N edits
    tools/sweep.sh 600                   the wide check (103 runs, both targets)

## What got past the per-candidate gate

`tools/gate.sh` (3 Master levels, 3 Model B levels, 200 frames, both menus) passed both
of these; the wide sweep caught them and bisection named them. Both were removed.

- `r073:5` (loader.s): the proposer marked it "FALLBACK: apply only if C4 was not
  applied" -- C4 had been. Watford boards never reached play. The gate runs no boards.
- `r038c:3` (logic.s): inlined `add16 bvy, t16` through X, claiming X and t16+1 dead.
  The boomerang diverged at frame 380 of level 14. 200 frames did not reach it.

## Gate lessons

- Title checks must be frame-synchronised (`tools/menusync.mjs`): a faster build
  reaches a fixed cycle count at a different point in the drawing.
- On the Master only the bar and both screens are display: comparing $0300-$7FFF
  compares the code too, and every Master size change "failed".
- Skip the first menu frame or two: a changed file size moves the disc load.
- Candidates can be conditional on each other ("fallback", "alternative"); a serial
  applier that finds text by exact match does not see that.
