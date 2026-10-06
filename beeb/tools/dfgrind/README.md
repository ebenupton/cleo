# The dataflow grind (6 Oct 2026)

beebgame's tools/dataflow run on Cleo's two builds (game sources with Cleo's object model,
`tools/dataflow_cleo.py`; engine sources too), the code cut into 32-instruction windows
annotated with the range analysis's state and liveness and the measured cycles a frame
(`windows.py`), dealt four windows to a batch, each batch given a reviewer and a skeptic
(`BRIEF.md`), the survivors applied behind the gates (`apply.py`: bytegrind's applier with
"better" = smaller and no slower than 4 cycles a frame, or the same size and faster), then
the 89-check sweep and an audit of every kept edit.

    python3 beebgame/tools/dataflow/annotate.py --config tools/dataflow_cleo.py --build build/modelb --out A_B
    (and build/master; and with a config of GAME_DIR = 'beebgame/src' for the engine)
    node test/linecyc.mjs modelb|master build/cleo.ssd build/<m>/labels.txt lc_<m>.json 0,2,4,6,8,10,12,14 100
    python3 tools/dfgrind/windows.py <ann_b> <ann_m> lc_b.json lc_m.json <dir> 32 4
    (the farm: BRIEF.md, reviewer then skeptic a batch, structured candidates as JSON lines)
    python3 tools/dfgrind/apply.py <candidates.jsonl> <work> 8

## Result

| | before | after |
|---|---|---|
| Model B code and data (all banks, low RAM, LDPROG, LOADER) | 28,066 | 27,883 (-183) |
| Master | 26,778 | 26,581 (-197) |
| Model B bank 7 game image, spare | 138 | 289 |
| play, 8 levels (linecyc, idle excluded): Model B | 78,251 | 77,873 (-0.5%) |
| Master | 82,627 | 82,299 (-0.4%) |

214 windows, 60 batches (logic.s's 24 again with the object model): 84 proposals survived
the skeptics (10 refuted); 62 kept, 18 changed the anonymous-label count (refused), 7
stale, 6 slower on the Model B (page crossings).  `applied.json` records every attempt.
The audit found no wrong edit; three rested on unguarded facts, now asserted (level_init's
type ladder: OT_RSNAKE/OT_BAT; get_altitude: alt bytes nonzero, low nibble <= 8, in
tools/assets.py).  kernel.s's edits are in build_sections and calc_ring: SECTAB checked
identical frame by frame on both machines; the chain's CRTC writes move only by interrupt
latency (crtctime).
