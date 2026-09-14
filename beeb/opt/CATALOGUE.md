# Peephole proposal catalogue

337 windows were put to a farm of agents; 107 came back with a rewrite and 230 were judged already optimal (68% rejected).

Savings are **cycles per frame**, the unit the rest of this project measures in: the claimed per-execution saving times the window's executions per frame, capped at the cycles the profile actually attributes to those lines. A claim above that cap is a units mismatch (an agent costing a whole loop as one execution), flagged `OVERCLAIM` and worth less than it says.

**Nothing here is verified.** Each entry is one agent's reasoning about 16 instructions in isolation, with no assembler and no emulator. Apply one at a time and gate it on `statediff` + `pixdiff` per `opt/README.md`.

34 of the 57 clusters are single proposals that can be taken on their own merits. The rest overlap: two or more agents rewrote the same lines, so at most one applies, and the disagreement itself is evidence.

## Ranked

| cy/frm | per exec | bytes | x/frm | conf | where | agents |
|---:|---:|---:|---:|:--|:--|---:|
| 1137 ! | 87 | -1 | 54 | medium | `engine.s:1968-1976` copy_partial | 1 |
| 906 | 22 | +2 | 41 | high | `engine.s:3043-3054` scan_keys | 1 |
| 538 ! | 351 | +1 | 26 | high | `engine.s:2402-2440` build_sections | 4 |
| 316 ! | 118 | +6 | 6 | high | `logic.s:1376-1411` player_update | 12 |
| 201 | 2 | +1 | 101 | high | `engine.s:514-557` drawrect | 1 |
| 168 | 3 | +2 | 56 | high | `engine.s:420-456` drawrect | 5 |
| 166 ! | 72 | -15 | 10 | high | `logic.s:3073-3083` bar_digit | 3 |
| 161 | 3 | +2 | 54 | high | `engine.s:1913-1949` copy_partial | 3 |
| 137 | 2 | +0 | 68 | high | `engine.s:634-673` drawrect | 1 |
| 125 ! | 21 | -1 | 10 | medium | `engine.s:2693-2709` calc_ring | 1 |
| 93 | 9 | +5 | 10 | high | `logic.s:2030-2064` ob_star | 1 |
| 90 | 4 | +3 | 22 | high | `engine.s:3022-3033` irq_handler | 2 |
| 48 | 8 | +6 | 6 | high | `logic.s:1888-1904` process_object | 2 |
| 46 | 4 | +3 | 12 | high | `engine.s:1046-1079` draw_sprites | 2 |
| 39 | 10 | -1 | 4 | high | `engine.s:1335-1374` drawsprite | 1 |
| 38 | 2 | +1 | 19 | high | `engine.s:2944-2985` irq_handler | 2 |
| 24 | 12 | +8 | 2 | medium | `logic.s:1802-1833` process_object | 1 |
| 23 | 4 | +4 | 6 | high | `engine.s:1142-1175` drawsprite | 8 |
| 22 ! | 41 | +10 | 1 | high | `logic.s:443-477` level_init | 1 |
| 18 | 3 | +0 | 6 | high | `engine.s:1105-1141` drawsprite | 1 |
| 14 | 2 | -1 | 7 | high | `engine.s:2194-2221` mirror_run | 1 |
| 13 | 12 | +8 | 1 | high | `logic.s:1191-1202` gravity | 1 |
| 12 | 7 | +4 | 2 | medium | `logic.s:1655-1688` player_update | 2 |
| 8 | 3 | +1 | 3 | high | `logic.s:400-424` getaltitude | 2 |
| 5 | 2 | +1 | 3 | high | `logic.s:2090-2105` star_safe | 1 |
| 5 | 11 | +7 | 0 | high | `logic.s:496-529` level_init | 2 |
| 5 | 12 | +8 | 0 | high | `logic.s:2197-2232` ob_snake | 2 |
| 5 | 3 | +4 | 2 | medium | `logic.s:1271-1304` player_update | 1 |
| 5 | 12 | +8 | 0 | high | `logic.s:2284-2316` ob_snake | 3 |
| 5 | 3 | +3 | 2 | high | `logic.s:1584-1619` player_update | 1 |
| 5 | 3 | +0 | 2 | high | `logic.s:996-1028` game_frame | 1 |
| 4 | 3 | +2 | 1 | high | `engine.s:3547-3582` init_maprows | 1 |
| 4 | 2 | +1 | 2 | high | `engine.s:2619-2655` drawrect_clip | 1 |
| 4 | 2 | +2 | 2 | high | `logic.s:1070-1098` game_frame | 1 |
| 3 | 2 | +1 | 2 | high | `main.s:270-298` clamp_window | 1 |
| 3 | 2 | +2 | 2 | high | `logic.s:2737-2772` ob_walker | 1 |
| 3 | 2 | +0 | 2 | high | `logic.s:2789-2810` ob_walker | 2 |
| 3 | 3 | +1 | 1 | high | `engine.s:840-874` scroll_validate | 4 |
| 3 | 3 | +0 | 1 | high | `engine.s:2086-2105` mirror_seek | 1 |
| 3 | 3 | +0 | 1 | high | `engine.s:2872-2901` draw_dirty | 1 |

`!` = OVERCLAIM. The `agents` column is how many proposals landed on those lines; >1 means the top entry is one option among several, not a consensus.
