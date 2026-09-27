# Peephole proposal catalogue

672 windows of 16 instructions were put to a farm of agents; 275 came back with a rewrite and 397 were judged already optimal (59% rejected).

Savings are **cycles per frame**, the unit the rest of this project measures in: the claimed per-execution saving times the window's executions per frame, capped at the cycles the profile actually attributes to those lines. A claim above that cap is a units mismatch (an agent costing a whole loop as one execution), flagged `OVERCLAIM` and worth less than it says.

**Nothing here is verified.** Each entry is one agent's reasoning about 16 instructions in isolation, with no assembler and no emulator. Apply one at a time and gate it on `statediff` + `pixdiff` per `opt/README.md`.

51 of the 127 clusters are single proposals that can be taken on their own merits. The rest overlap: two or more agents rewrote the same lines, so at most one applies, and the disagreement itself is evidence.

## Ranked

| cy/frm | per exec | bytes | x/frm | conf | where | agents |
|---:|---:|---:|---:|:--|:--|---:|
| 2262 ! | 38 | -24 | 116 | high | `engine.s:2199-2216` mirror_run | 3 |
| 1388 | 28 | -17 | 50 | medium | `engine.s:733-749` drawrect | 2 |
| 802 | 13 | +12 | 62 | medium | `engine.s:1945-1961` copy_partial | 6 |
| 646 | 12 | -7 | 54 | medium | `engine.s:3733-3754` pagelogic | 1 |
| 493 | 5 | +3 | 99 | high | `engine.s:1698-1727` pd | 1 |
| 383 | 3 | +3 | 128 | high | `engine.s:603-618` drawrect | 2 |
| 336 ! | 144 | -30 | 10 | high | `logic.s:2926-2942` bar_digit | 6 |
| 311 ! | 114 | +1 | 11 | medium-high | `logic.s:3016-3037` div10_16 | 1 |
| 279 ! | 250 | +16 | 14 | medium | `engine.s:2726-2742` calc_ring | 2 |
| 252 | 3 | +2 | 84 | high | `engine.s:1514-1531` ds_done | 1 |
| 199 ! | 56 | -12 | 7 | high | `logic.s:1170-1176` gravity | 1 |
| 163 ! | 6457 | +2 | 15 | high | `engine.s:2011-2026` bar_bg | 3 |
| 157 | 6 | +2 | 26 | high | `engine.s:2436-2458` build_sections | 3 |
| 156 | 2 | +2 | 78 | high | `engine.s:520-537` drawrect | 1 |
| 156 | 2 | +2 | 78 | high | `engine.s:538-563` drawrect | 1 |
| 155 | 16 | +12 | 10 | high | `logic.s:1801-1816` po_star | 2 |
| 149 | 3 | +2 | 50 | high | `engine.s:687-707` drawrect | 3 |
| 146 | 2 | +2 | 73 | high | `engine.s:464-481` drawrect | 2 |
| 116 | 3 | +3 | 39 | high | `engine.s:650-667` drawrect | 2 |
| 101 | 20 | -1 | 5 | high | `logic.s:1428-1447` player_update | 5 |
| 91 | 18 | +12 | 5 | high | `logic.s:1390-1409` player_update | 4 |
| 89 | 26 | +10 | 3 | high | `engine.s:2484-2500` build_sections | 3 |
| 84 | 2 | +3 | 42 | high | `engine.s:3084-3095` scan_keys | 1 |
| 74 | 12 | +8 | 6 | high | `logic.s:1047-1066` game_frame | 3 |
| 60 ! | 256 | +2 | 1 | medium | `logic.s:467-484` level_init | 3 |
| 58 | 5 | +3 | 12 | high | `logic.s:1840-1855` inrange | 1 |
| 47 | 24 | +16 | 2 | high | `logic.s:1269-1286` player_update | 10 |
| 42 | 2 | +0 | 21 | medium | `engine.s:1661-1677` pl | 2 |
| 41 | 3 | +2 | 14 | high | `engine.s:1025-1040` draw_sprites | 4 |
| 39 | 4 | +6 | 10 | high | `logic.s:1914-1931` ob_star | 2 |
| 38 | 9 | +5 | 4 | medium | `engine.s:1250-1267` drawsprite | 2 |
| 37 | 5 | +2 | 7 | high | `logic.s:373-388` getaltitude | 3 |
| 37 ! | 24 | +16 | 2 | high | `logic.s:1670-1688` player_update | 2 |
| 35 | 9 | +5 | 4 | medium | `engine.s:1359-1376` drawsprite | 6 |
| 34 | 8 | +6 | 4 | high | `logic.s:1774-1789` process_object | 3 |
| 29 | 2 | +0 | 14 | high | `engine.s:1490-1504` ds_rowdone | 1 |
| 29 | 2 | +0 | 14 | medium | `engine.s:1440-1452` ds_rowloop | 2 |
| 28 | 9 | +6 | 3 | high | `engine.s:2131-2147` mirror_run | 2 |
| 23 | 12 | +8 | 2 | high | `logic.s:1215-1231` player_update | 1 |
| 23 | 6 | -2 | 4 | high | `engine.s:433-453` drawrect | 1 |

`!` = OVERCLAIM. The `agents` column is how many proposals landed on those lines; >1 means the top entry is one option among several, not a consensus.
