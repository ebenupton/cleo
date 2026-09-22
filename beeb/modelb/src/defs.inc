; ============================================================================
; Cleo, Model B target: what differs from the Master is addresses -- this file --
; and the 65C02 spellings (src/cpu.inc).  The engine, the logic, the game loop and
; the menus are ../src/engine.s, logic.s, game.s and menu.s, assembled with MODELB=1.
;
; Main RAM is the display: $0300-$7BFF is the bar, two mirrors and two 22-slot rings
; (engine.s, screen shape).  What is left is zero page, $0100-$02FF (the stack, the
; far-call thunk, the interrupt stub, the map helpers, the sprite list), $7C00-$7FFF
; (the code every bank calls: the tile blitter's head, ringaddr, the record scans,
; select_backbuf, mark_dirty, and the small tables) and two holes below the mirrors
; (the buffers' state, the dirty lists).  The code lives in four sideways banks, each
; with the data its inner loops read:
;   4  most of the sprite images and masks, the mask tables, the sprite row loop
;   5  the level's tiles (the Master's own count, up to 233) with the tile blitter's
;      row loop, scroll_validate, draw_dirty and blank_below above them; the menu
;      overlay (the menus, the tune, the font) goes over the tiles for the menus
;   6  the map, the sprite directory and the rest of the sprites with their own copy
;      of the row loop; the title pack sits over the map during the menus
;   7  the logic, the game loop, the level's tables, the sprite prologue and its
;      records, copy_partial, the display driver, the interrupt's work, the sound,
;      the HUD, the disc driver
; Every level is gathered from the disc into the banks by the loader (ldprog.s),
; which runs in main RAM while the palette is black.  docs/PLAN_MODELB_FULL.md.
; ============================================================================
VSPEG     = 3                       ; vsyncs a rendered frame, as the Master

FARTAB    = $8000                   ; every bank carries the same far table here
                                    ; (banks.s)
SWAPTAB   = $8300                   ; static in bank 4: dot reversal (bank 6 draws
MASKTAB0  = $8400                   ; nothing mirrored, so that page holds data there);
MASKTAB1  = MASKTAB0 + $100         ; the four mask-phase pages in both sprite banks
MASKTAB2  = MASKTAB0 + $200
MASKTAB3  = MASKTAB0 + $300
BANKCODE  = $8040                   ; bank 7's entry vector, where the loader jumps
BANKENTRY = $BFFD                   ; banks 4, 5 and 6: a jump to the routine bank 7 calls
                                    ; once a sprite or rect (low.s callbank): the sprite
                                    ; row loop, drawrect_clip
TILES     = $8100                   ; bank 5: this level's tiles, 64 bytes each, by id,
                                    ; page aligned (drawrect's gather is arithmetic)
MENU_BASE = TILES                   ; or the menu overlay, over them
LV_MAP    = MAP6                    ; bank 6, $8800: row major, up to 8K; the sprite
                                    ; directory follows it (sprtab, set by the loader)
LV_OBJS   = $7800                   ; the level's objects, 6 bytes each: main RAM (the
                                    ; display, black while they are read: level_init
                                    ; reads them once, before the first render)

; ---------------------------------------------------------------- zero page
; The Master's zero page: engine.s's .zeropage ends at $A1, the logic's temps are
; $A8-$DE.  These fill the gaps.  $F4 is the MOS's ROMSEL copy: nothing past $EF.
NSPR     = $A3                      ; (main RAM tables on the Master: low RAM is short)
BARDIRTY = $A4
BARBG    = $A5
SFXREQ   = $A6
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
menuptr  = $EE                      ; 2: the menus' list pointer
.assert menuptr + 2 <= $F0, error, "zero page runs into the MOS's"

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

; ---------------------------------------------------------------- the loader
NMIPAGE   = $0D00                   ; the disc transfer routine, while a load runs
LDPROG    = $0E00                   ; the load-time program (ldprog.s), read there
STAGE     = $1C00                   ; a shared file staged here, 16K at most ($5BFF)
STAGE_LVL = $5C00                   ; the level's own file, under 7K (tools/assets.py
                                    ; asserts it): the objects go to LV_OBJS ($7800)
                                    ; while it is still being read
FDC8271_CMD = $FE80                 ; the 8271: command/status, parameter/result, data
FDC8271_PAR = $FE81
FDC8271_DAT = $FE84
FDC1770_CTL = $FE80                 ; the Acorn 1770 board: the drive control latch,
FDC1770_CMD = $FE84                 ; then the WD1770 at $FE84-$FE87
FDC1770_TRK = $FE85
FDC1770_SEC = $FE86
FDC1770_DAT = $FE87

; ---------------------------------------------------------------- far calls
; The index of a (bank, address-1) entry in FARTAB (modelb/src/banks.s).  Everything
; that crosses a bank boundary goes through one of these: two a frame for the ring
; work in bank 5, one a sprite for its row loop, one a rect for the tile blitter's
; rows, and the rare rest.  A goes in and comes back, Y survives, X does not.
; (The sprite row loop, erase_old's rects and the prologue's ring address do not go
; through the table: low.s callbank, engine.s ringaddr7.)
F_RENDER5   = 0*3                   ; scroll_validate + draw_dirty + blank_below, bank 5
F_SELBB     = 1*3                   ; select_backbuf        bank 5
F_TITLE     = 2*3                   ; the menus: bank 5's overlay, present only while
F_HELP      = 3*3                   ;   title_res says so
F_LEVELSEL  = 4*3
F_WINLOSE   = 5*3
F_BUILDSECT = 6*3                   ; build_sections, bank 7 (the menus call it)
F_BLANKPAL  = 7*3                   ; blank_palette   bank 7
F_SETPAL    = 8*3                   ; set_palette     bank 7
F_LOADTITLE = 9*3                   ; load_title      bank 7: the overlay and the pack
F_MUSSTOP   = 10*3                  ; music_stop      bank 7
F_DIV10     = 11*3                  ; div10_16        bank 7
F_DRAWSPR   = 12*3                  ; drawsprite      bank 7 (the menus' title pieces)
F_CALCRING  = 13*3                  ; calc_ring       bank 7 (the menus)
F_COPYPART  = 14*3                  ; copy_partial    bank 5
F_MARKDIRTY = 15*3                  ; mark_dirty      bank 5 (the logic; X in farx)
F_INIT5     = 16*3                  ; init5 + take_over, bank 5's low corner (start-up)
NFAR        = 17
.assert 3*NFAR <= $40, error, "the far table has outgrown its $40 bytes"
