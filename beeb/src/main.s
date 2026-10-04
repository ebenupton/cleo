; ============================================================================
; Cleo: the one assembly.  One source tree builds the four bank images for
; either machine -- BHW=1 the Model B's hardware, BHW=0 the Master's (cpu.inc;
; build.sh builds both onto one disc).  The engine's files are beebgame's
; (beebgame/src: cpu.inc, defs.inc, engine.s, low.s, disc.s, mirror.s, banks.s,
; init.s -- beebgame/docs/DESIGN.md); the game's are Cleo's: logic.s (the level
; logic and the HUD), game.s (the camera clamp, the level and frame loops, the
; sound effects), menu.s (the menus) and gamedata.s (its tables).  This file is
; the include order and the engine's hooks (beebgame/docs/GUIDE.md step 3); it
; defines no code of its own.
; ============================================================================
        .include "cpu.inc"         ; (-D BHW=0: the Master)
        .include "defs.inc"
        .include "engine.s"
        .include "logic.s"
        .include "game.s"
        .include "menu.s"
        .include "low.s"
        .include "disc.s"
  .if BHW                          ; hardware: the Master's CRTC folds its ring itself
        .include "mirror.s"
  .endif
        .include "banks.s"         ; (the engine's tables, then the game's)
        .include "gamedata.s"
        .include "init.s"

; ---------------------------------------------------------------- beebgame's hooks
; What the engine jumps to or calls in the game (ldprog.s ld_image, frame.s
; render_frame).  Each is reached with the image it needs in bank 7.
hook_title = game_main             ; start-up: the menus' image in, the stack reset,
                                    ; jumped to (menu.s)
hook_play  = level_loop            ; go_game has loaded the game's image: jumped to,
                                    ; interrupts off, the disc still open (game.s)
hook_over  = menu_over             ; go_menu has loaded the menus' image: jumped to with
                                    ; its caller's A, 0 lost or 1 won (menu.s)
hook_image = bar_bg                ; the game's image is in, and the bar's template
                                    ; (BAR) with it: called before hook_play, so the
                                    ; HUD's digit cache is reset (logic.s)
hook_hud   = redraw_hud            ; render_frame finds bar_dirty set: the bar's digits
                                    ; (logic.s)
