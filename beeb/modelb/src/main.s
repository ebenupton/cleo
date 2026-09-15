; ============================================================================
; Cleo, Model B target: one assembly, four bank images.  The engine, the logic and
; the game are the Master's sources (../src), assembled with MODELB=1 and MODE1=1;
; what is this target's own is under modelb/src: the addresses (defs.inc), the low
; RAM (low.s), the rupture chain (display.s), the banks' tables and data (banks.s)
; and the start-up (init.s).  See DESIGN.md.
; ============================================================================
        .include "cpu.inc"          ; -D MODELB=1 -D MODE1=1 on the command line
        .include "defs.inc"
        .include "engine.s"
        .include "logic.s"
        .include "game.s"
        .include "low.s"
        .include "display.s"
        .include "banks.s"
        .include "init.s"
