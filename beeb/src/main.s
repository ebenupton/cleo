; ============================================================================
; Cleo: one assembly, four bank images, for either machine -- BHW=1 the Model B's
; hardware, BHW=0 the Master's (cpu.inc); build.sh builds both onto one disc.  The
; engine is beebgame's (beebgame/src: cpu.inc, defs.inc, engine.s, low.s, disc.s,
; mirror.s, banks.s, init.s -- see beebgame/docs/DESIGN.md); the game is Cleo's:
; the logic, the game loop, the menus and their tables (gamedata.s).
; ============================================================================
        .include "cpu.inc"          ; (-D BHW=0: the Master)
        .include "defs.inc"
        .include "engine.s"
        .include "logic.s"
        .include "game.s"
        .include "menu.s"
        .include "low.s"
        .include "disc.s"
  .if BHW                           ; (the Master's CRTC folds its ring itself)
        .include "mirror.s"
  .endif
        .include "banks.s"          ; (the engine's tables, then the game's)
        .include "gamedata.s"
        .include "init.s"

; ---------------------------------------------------------------- beebgame's hooks
; What the engine calls in the game (beebgame/README.md)
hook_title = game_main              ; start-up, the menus' image in (menu.s)
hook_play  = level_loop             ; a game starts, the game's image in (game.s)
hook_over  = menu_over              ; a game has ended, the menus' image in; A = 0 lost,
                                    ; 1 won (menu.s)
hook_image = bar_bg                 ; the game's image has come in: the bar's template
                                    ; with it, so the HUD's digit cache is stale (logic.s)
hook_hud   = redraw_hud             ; render_frame, BARDIRTY set: the bar's digits (logic.s)

