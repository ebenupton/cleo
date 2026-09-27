; ============================================================================
; Cleo: one assembly, four bank images, for either machine -- BHW=1 the Model B's
; hardware, BHW=0 the Master's (cpu.inc); build.sh builds both onto one disc.  The
; engine, the logic, the game loop and the menus; the addresses (defs.inc), the low
; RAM (low.s), the disc driver (disc.s), the Model B's rupture chain (display.s), the
; banks' tables and data (banks.s) and the start-up (init.s).  See docs/DESIGN.md.
; ============================================================================
        .include "cpu.inc"          ; (-D BHW=0: the Master)
        .include "defs.inc"
        .include "engine.s"
        .include "logic.s"
        .include "game.s"
        .include "menu.s"
        .include "low.s"
        .include "disc.s"
  .if BHW                           ; (the Master's handler and chain are engine.s's)
        .include "display.s"
  .endif
        .include "banks.s"
        .include "init.s"

.assert camoff < NSPR, error, "the zero page segment grew into defs.inc's fixed equates: raise NSPR/BARDIRTY/BINI/SFXREQ/fcA there"
