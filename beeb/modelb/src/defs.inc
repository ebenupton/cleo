; ============================================================================
; Cleo, Model B target: what differs from the Master is addresses -- this file --
; and the 65C02 spellings (src/cpu.inc).  The engine, the logic and the game loop
; are ../src/engine.s, logic.s and game.s, assembled with MODELB=1.
;
; Main RAM is the display: $0300-$7FFF is the bar, two mirrors and two 23-slot rings
; (engine.s, screen shape).  What is left is zero page and $0100-$02FF: the stack, the
; far-call thunk, the interrupt stub, the map helpers and the sprite list.  The code
; lives in four sideways banks, each with the data its inner loops read:
;   4  most of the sprite images and masks, the mask tables, the sprite row loop
;   5  the tiles, the tile blitter, the sprite prologue and directory, the records
;   6  the map, and the rest of the sprites with their own copy of the row loop
;      (the Master's directory flag $10 names bank 6 too)
;   7  the logic, the game loop, the level's tables, the display driver, the
;      interrupt's work, the sound and the music, the HUD
; ============================================================================
; LEVEL_IDX is in assets.inc: the level tools/assets.py packed (build.sh LEVEL="lv sub")
VSPEG     = 3                       ; vsyncs a rendered frame, as the Master: the median
                                    ; frame is 70k cycles, the 90th percentile 111k
MAPSTRIDE = 1 << MAPLW              ; bytes per map row: a constant here, so the row
                                    ; tables are arithmetic (maprow, maprow5)

FARTAB    = $8000                   ; every bank carries the same far table here,
sprmul5   = $8030                   ; and these small tables (banks.s COMMON_TABLES)
mulrowlo  = $8050
mulrowhi  = $8068
ringmodtab = $8080
SWAPTAB   = $8300                   ; static, in both sprite data banks: dot reversal
MASKTAB0  = $8400                   ; and the four mask-phase pages (1K aligned)
MASKTAB1  = MASKTAB0 + $100
MASKTAB2  = MASKTAB0 + $200
MASKTAB3  = MASKTAB0 + $300
BANKCODE  = $8100                   ; bank 7's entry vector, where the loader jumps

; ---------------------------------------------------------------- zero page
; The Master's zero page: engine.s's .zeropage ends at $A1, the logic's temps are
; $A8-$DE.  These fill the gaps.  $F4 is the MOS's ROMSEL copy: nothing past $EF.
NSPR     = $A2                      ; (main RAM tables on the Master: low RAM is short)
BARDIRTY = $A3
BARBG    = $A4
SFXREQ   = $A5
mtmp     = $DF                      ; cpu.inc's scratch (inca/deca/bitimm/ldazy)
ringbhi  = $E0                      ; the buffer being drawn: ring base high byte,
ringehi  = $E1                      ;   ring end high byte (ringup's fold test),
ringe3   = $E2                      ;   >RINGEND-3 and 256->RINGEND (drawrect's wrap test)
ringneg  = $E3
mrow     = $E4                      ; the map char row in the ring's last slot (calc_ring)
wcxm     = $E5                      ; ringS mod 80: the mirror's first useful char
rstar    = $E6                      ; the window row that lives in the last slot
sp_disp  = $E7                      ; the sprite's blitter index, for the loop's bank
sp_mpg0  = $E8                      ; (the Master keeps these four in main RAM)
sp_mh    = $E9
sp_mrp   = $EA                      ; 2
sp_mbase = $EC                      ; 2
.assert sp_mbase + 2 <= $F0, error, "zero page runs into the MOS's"

; ---------------------------------------------------------------- display
LINE      = 64                      ; T1 ticks in one scanline
BARCRTC   = BARADDR / 8
CRTCB_A   = RING_A / 8
CRTCB_B   = RING_B / 8
; CA1 fires at the end of the 2-line vsync pulse.  -35 would put each step ~5 us INTO
; its section; the further -36 puts it ~30 us BEFORE the restart, so the shape
; registers land early in the section's first scanline.  The interrupt stub's bank
; switch (~30 cycles) replaces the hold the Master's handler had.
VS2T_DEFAULT = (QROWS-QVSYNC)*8*LINE - 2*LINE - 35 - 36

; ---------------------------------------------------------------- far calls
; The index of a (bank, address-1) entry in FARTAB (modelb/src/banks.s).  Everything
; that crosses a bank boundary goes through one of these: once a frame for the
; render, once a sprite for its row loop, and the rare rest.
F_RENDCORE  = 0*3                   ; render_frame's middle: the ring work, bank 5
F_SPRLOOP4  = 1*3                   ; the sprite row loop   bank 4
F_SPRLOOP6  = 2*3                   ;                       bank 6
F_MARKDIRTY = 3*3                   ; mark_dirty            bank 5 (A = tx, Y = ty)
F_LVRESET   = 4*3                   ; the records and dirty lists cleared, bank 5
F_INIT5     = 5*3                   ; bank 5's start-up
NFAR        = 6
