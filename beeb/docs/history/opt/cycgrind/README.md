# The cycle grind (1 Oct 2026)

Every hot region of both machines' frame was put to a farm of agents, each asked for
behaviour-identical speedups; the candidates were applied in batches, each batch kept
only when it built, matched the base frame by frame on both machines and measured
faster.

## Pipeline

    node test/linecyc.mjs modelb|master <disc> <labels> <out.json> [levels] [frames]
            cycles and executions a frame per source line, every bank (idle excluded)
    python3 tools/cycgrind/regions.py <lc_modelb.json> <lc_master.json> <dir> 0.995 150
            the hot regions: contiguous runs of hot lines, annotated per line for both
            machines (54 regions, 99.5% of the profiled cycles)
    (the farm: one surveyor per region, a second with a structural lens on the six
     biggest; brief BRIEF.md; nothing edited, nothing built)
    python3 tools/cycgrind/apply.py <journal.jsonl> <work> <base> [batch]
            serial: locate each candidate (stale if its lines are gone), refuse any that
            changes the anonymous-label count, apply a batch, build (stepping the Model
            B's B4/B5_CODE_END through the batch's byte change), gate: test/statecmp.mjs
            (Master: game state and sprite list) and test/bwincmp.mjs (Model B: the
            visible windows) against the base on levels 2, 8, 13 over 300 frames, and
            linecyc's frame totals; keep, or bisect.  REPLAY=1 resets the tree and
            re-applies the record's kept candidates (an interrupted run).

## Result

| | candidates |
|---|---|
| proposed (58 of 59 surveyors; one stalled) | 113 |
| kept | 80 |
| changed the anonymous-label count | 14 |
| stale (an earlier edit took the lines) | 11 |
| did not build | 5 |
| changed behaviour | 2 |
| no faster | 1 |

Frame work, levels 2, 8, 13 (linecyc, idle excluded): Model B 79,598 -> 77,685 cycles
(-1,913, 2.4%), Master 75,034 -> 73,078 (-1,956, 2.6%).  The biggest single items:
the sprite loop's column step (r00s:0, -350 a frame), copy_partial (r06:0/1, -450),
the tile copy chain (r02:0).  The sweep (57 checks) passes; the raster-critical writes
(the Model B's palette kill, the Master's ACCCON D writes) land where they did.

## Files

- `BRIEF.md` -- what every surveyor was told
- `candidates.json` -- every candidate as proposed
- `applied.json` -- every attempt in order and its outcome (`dB`, `dM`: the batch's
  measured change)
- `regions.json` -- the regions and their cost

## Lessons

- The gate was the filter, as in the byte grind: no reviewers, and the two candidates
  that changed behaviour were caught by statecmp/bwincmp before they were kept.
- The sprite loops are assembled into both banks 4 and 5: a size change there moves
  both code-end constants at once.  The first applier stepped one bank at a time and
  rejected every sprite-loop candidate as "build".
- crtctime's write-by-write comparison is meaningless between builds of different
  speed (the frames that miss differ, so the sequences drift): compare the critical
  writes' position distributions instead.
