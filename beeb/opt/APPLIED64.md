# Applied proposals -- round 3 (64-instruction windows)

171 windows of up to 64 instructions went to 18 agents; 59 came back with a rewrite
and 112 were judged already optimal (66% rejected). 42 are applied.

The cy/frm column is the catalogue ranking and over-reads badly at this window size:
a 64-instruction window contains a whole loop, so an agent quoting a per-CALL saving
is multiplied by the INNER LOOP's execution count. `engine_1917` is ranked at 6083
and is worth about 237. Use tools/linecost.py, not this column.

| ranked cy/frm | id | file | routine |
|---:|:--|:--|:--|
| 6082.6 | `engine_1917` | engine.s | copy_partial |
| 1747.2 | `engine_458` | engine.s | drawrect |
| 1075.2 | `engine_538` | engine.s | drawrect |
| 381.0 | `engine_387` | engine.s | drawrect |
| 268.8 | `engine_496` | engine.s | drawrect |
| 167.0 | `logic_904` | logic.s | game_frame |
| 156.7 | `logic_1427` | logic.s | player_update |
| 141.6 | `engine_2894` | engine.s | irq_handler |
| 128.1 | `engine_2127` | engine.s | mirror_run |
| 114.4 | `logic_1012` | logic.s | game_frame |
| 111.2 | `engine_2301` | engine.s | build_sections |
| 99.2 | `logic_1538` | logic.s | player_update |
| 96.5 | `engine_2933` | engine.s | irq_handler |
| 90.0 | `engine_1071` | engine.s | drawsprite |
| 80.5 | `logic_752` | logic.s | level_init |
| 62.4 | `engine_1284` | engine.s | drawsprite |
| 57.7 | `logic_1393` | logic.s | player_update |
| 50.3 | `engine_2622` | engine.s | drawrect_clip |
| 47.8 | `logic_1793` | logic.s | player_update |
| 37.1 | `engine_2333` | engine.s | build_sections |
| 35.8 | `logic_1686` | logic.s | player_update |
| 30.0 | `engine_1143` | engine.s | drawsprite |
| 22.5 | `engine_1108` | engine.s | drawsprite |
| 19.2 | `engine_1322` | engine.s | drawsprite |
| 15.9 | `logic_1759` | logic.s | player_update |
| 14.4 | `engine_1249` | engine.s | drawsprite |
| 14.3 | `logic_2231` | logic.s | ob_snake |
| 13.9 | `logic_1617` | logic.s | player_update |
| 13.0 | `logic_2300` | logic.s | ob_snake |
| 11.1 | `engine_1212` | engine.s | drawsprite |
| 9.8 | `logic_2770` | logic.s | ob_walker |
| 8.0 | `logic_1213` | logic.s | vy_step |
| 7.1 | `engine_2407` | engine.s | build_sections |
| 2.1 | `logic_619` | logic.s | level_init |
| 0.0 | `menu_512` | menu.s | winlose |
| 0.0 | `menu_404` | menu.s | help_screen |
| 0.0 | `logic_685` | logic.s | level_init |
| 0.0 | `logic_2696` | logic.s | ob_bat |
| 0.0 | `logic_2629` | logic.s | ob_bat |
| 0.0 | `logic_2521` | logic.s | square |
| 0.0 | `logic_2480` | logic.s | ob_rsnake |
| 0.0 | `engine_2820` | engine.s | mark_dirty |
