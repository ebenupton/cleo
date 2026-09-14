# Peephole proposal catalogue

171 windows were put to a farm of agents; 59 came back with a rewrite and 112 were judged already optimal (65% rejected).

Savings are **cycles per frame**, the unit the rest of this project measures in: the claimed per-execution saving times the window's executions per frame, capped at the cycles the profile actually attributes to those lines. A claim above that cap is a units mismatch (an agent costing a whole loop as one execution), flagged `OVERCLAIM` and worth less than it says.

**Nothing here is verified.** Each entry is one agent's reasoning about 16 instructions in isolation, with no assembler and no emulator. Apply one at a time and gate it on `statediff` + `pixdiff` per `opt/README.md`.

19 of the 30 clusters are single proposals that can be taken on their own merits. The rest overlap: two or more agents rewrote the same lines, so at most one applies, and the disagreement itself is evidence.

## Ranked

| cy/frm | per exec | bytes | x/frm | conf | where | agents |
|---:|---:|---:|---:|:--|:--|---:|
| 6083 ! | 237 | +1 | 66 | high | `engine.s:1917-1950` copy_partial | 2 |
| 1747 | 13 | -2 | 134 | medium | `engine.s:458-537` drawrect | 5 |
| 395 ! | 72 | -15 | 12 | high | `logic.s:3072-3117` bar_digit | 2 |
| 167 | 84 | -24 | 2 | high | `logic.s:904-977` game_frame | 1 |
| 157 | 30 | -2 | 5 | medium | `logic.s:1427-1499` player_update | 6 |
| 142 | 7 | -4 | 20 | high | `engine.s:2894-2967` irq_handler | 3 |
| 128 | 10 | +6 | 13 | high | `engine.s:2127-2194` mirror_run | 1 |
| 114 | 9 | +14 | 13 | high | `logic.s:1012-1088` game_frame | 1 |
| 111 | 30 | -14 | 4 | medium | `engine.s:2301-2368` build_sections | 5 |
| 90 | 12 | -5 | 8 | high | `engine.s:1071-1142` drawsprite | 9 |
| 80 ! | 26 | +0 | 3 | medium | `logic.s:752-822` level_init | 1 |
| 50 | 18 | -7 | 3 | medium | `engine.s:2622-2637` drawrect_clip | 2 |
| 48 ! | 26 | +44 | 2 | medium | `logic.s:1793-1819` player_update | 2 |
| 36 | 18 | +16 | 2 | high | `logic.s:1686-1757` player_update | 1 |
| 24 | 12 | +8 | 2 | high | `logic.s:1252-1321` player_update | 2 |
| 14 | 11 | +9 | 1 | medium | `logic.s:2231-2299` ob_snake | 1 |
| 14 | 7 | +0 | 2 | high | `logic.s:1617-1685` player_update | 1 |
| 13 | 10 | +21 | 1 | medium | `logic.s:2300-2366` ob_snake | 1 |
| 10 | 6 | +4 | 2 | high | `logic.s:2770-2837` ob_walker | 2 |
| 8 | 4 | +8 | 2 | high | `logic.s:1213-1229` vy_step | 1 |
| 2 | 6 | +3 | 0 | high | `logic.s:619-684` level_init | 1 |
| 0 | 12 | +8 | 0 | high | `logic.s:2480-2518` ob_rsnake | 1 |
| 0 | 46 | +3 | 0 | high | `logic.s:2521-2538` square | 1 |
| 0 | 2 | +1 | 0 | high | `menu.s:404-422` help_screen | 1 |
| 0 | 2 | +4 | 0 | medium | `logic.s:2558-2628` ob_bat | 1 |
| 0 | 7 | +5 | 0 | high | `menu.s:512-579` winlose | 1 |
| 0 | 29 | +20 | 0 | medium | `logic.s:2629-2695` ob_bat | 1 |
| 0 | 2 | +1 | 0 | high | `engine.s:2820-2833` mark_dirty | 1 |
| 0 | 2 | +1 | 0 | medium | `logic.s:2696-2735` ob_bat | 1 |
| 0 | 2 | +1 | 0 | high | `logic.s:685-751` level_init | 1 |

`!` = OVERCLAIM. The `agents` column is how many proposals landed on those lines; >1 means the top entry is one option among several, not a consensus.
