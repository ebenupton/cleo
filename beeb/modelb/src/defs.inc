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
  .if BHW
VSPEG     = 3                       ; vsyncs a rendered frame, as the Master
  .endif

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
  .if BHW
LV_OBJS   = $7C00                   ; the level's objects, 6 bytes each (894 at most): main RAM (the
                                    ; display, black while they are read: level_init
                                    ; reads them once, before the first render)
  .else                             ; the converged Master: main RAM below the screen
LV_OBJS   = $1C00                   ; (the loader's program ends by $1BFF)
TAILBUF   = $2000                   ; SPRX's last pages past HAZEL and ANDY (ldprog.s)
LV_PAGE0  = $0400                   ; tile id -> the gather's pair: 256 lo, 256 hi (the
                                    ; level's, the loader's), page aligned
  .endif

; ---------------------------------------------------------------- zero page
; The Master's zero page: engine.s's .zeropage ends at $A1, the logic's temps are
; $A8-$DE.  These fill the gaps.  $F4 is the MOS's ROMSEL copy: nothing past $EF.
NSPR     = $A3                      ; (main RAM tables on the Master: low RAM is short)
BARDIRTY = $A4
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
BINI     = $A5                      ; the Model B's three hottest scalars outside zero page
curR7    = $EE                      ;  (profiled: 44-64, ~41 and ~35 accesses a frame); the
SECIDX   = $EF                      ;  menus' menuptr, which had $EE-$EF, went to MNUBSS
fcA      = $A7                      ; fcret's A across the bank switch (low.s)
.assert SECIDX < $F0, error, "zero page runs into the MOS's"

; ---------------------------------------------------------------- display
  .if BHW                           ; (the converged Master: the Master's own, engine.s)
LINE      = 64                      ; T1 ticks in one scanline
BARCRTC   = BARADDR / 8
CRTCB_A   = RING_A / 8
CRTCB_B   = RING_B / 8
; CA1 fires at the end of the 2-line vsync pulse.  -35 would put each step ~5 us INTO
; its section; the further -36 puts it ~30 us BEFORE the restart, so the shape
; registers land early in the section's first scanline.  The interrupt stub's bank
; switch (~30 cycles) replaces the hold the Master's handler had; since the switch went
; through pagelogic (the write bank too) both the vsync's T1 restart and every step are
; ~23 cycles later -- 46 in all, 23 ticks -- and the -23 takes that back: tools/bcrtc.mjs
; shows R9 landing at char 41-53 of the section's first scanline, as before.
VS2T = (QROWS-QVSYNC)*8*LINE - 2*LINE - 35 - 36 - 23 - 12 + 2   ; -12: the step's LOADREQ test and the
                                    ; IER-masked entry; +2 (ticks): loaded as an immediate, 4 cycles sooner
  .endif

; ---------------------------------------------------------------- sideways RAM boards
; Which register chooses the bank a store goes to (the loader finds out: findram).  The
; game's own code is patched for it at boot (cpu.inc wrsel); what comes off the disc
; reads PBOARD (ldprog.s).
BOARD_STD      = 0                  ; through ROMSEL, as reads
BOARD_WATFORD  = 1                  ; a store to $FF30 + bank
BOARD_SOLIDISK = 2                  ; user VIA port B bits 0-3: $FE62 = $0F, $FE60 = bank
WRSEL_WATFORD  = $FF30
WRSEL_SOLIDISK = $FE60

; ---------------------------------------------------------------- the loader
NMIPAGE   = $0D00                   ; the disc transfer routine, while a load runs
LDPROG    = $0E00                   ; the load-time program (ldprog.s), read there
  .if BHW
STAGE     = $1C00                   ; a shared file staged here, 16K at most ($5BFF)
STAGE_LVL = $5C00                   ; the level's own file, 8K at most (tools/assets.py
                                    ; asserts it): the objects go to LV_OBJS ($7C00)
                                    ; while it is still being read
  .else                             ; the converged Master: the screen, both of it --
STAGE     = $3000                   ; a shared file in SHADOW RAM (ACCCON X = 1 while it
STAGE_LVL = $3000                   ; is read or copied), the level's in main RAM
  .endif
FDC8271_CMD = $FE80                 ; the 8271: command/status, parameter/result, data
FDC8271_PAR = $FE81
FDC8271_DAT = $FE84
  .if BHW
FDC1770_CTL = $FE80                 ; the Acorn 1770 board: the drive control latch,
FDC1770_CMD = $FE84                 ; then the WD1770 at $FE84-$FE87
FDC1770_TRK = $FE85
FDC1770_SEC = $FE86
FDC1770_DAT = $FE87
  .else
FDC1770_CTL = $FE24                 ; the Master's: its drive control latch, then the
FDC1770_CMD = $FE28                 ; WD1770 at $FE28-$FE2B
FDC1770_TRK = $FE29
FDC1770_SEC = $FE2A
FDC1770_DAT = $FE2B
  .endif

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
