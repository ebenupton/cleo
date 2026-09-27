; ============================================================================
; The addresses, for both machines (BHW, cpu.inc: the hardware).  The code lives in
; four sideways banks, each with the data its inner loops read:
;   4  the sprite row loop (with the mirrored blitter), most of the sprite images
;      and masks, SWAPTAB and the mask tables
;   5  the row loop again (no mirrored blitter), the gather, the rest of the sprites,
;      the map (a fixed 8K) and the mask tables
;   6  the tile blitter and the ring work, then the level's tiles from TILES
;   7  at the top the kernel, resident: the chain's builders, the palette, the disc
;      driver, and on the Model B the interrupt's work, the keys and the sound.
;      Below it one of two images, swapped by a disc load (disc.s go_game, go_menu):
;      the game's -- the level's tables, the logic, the game loop, the sprite
;      prologue and its records, the HUD, the level's sprite directory -- or the
;      menus' -- the menus, the tune, the font, the title pieces
; Main RAM on the Model B is the display from $0300 -- the bar, two mirrors and two
; 23-slot rings (engine.s, screen shape) -- leaving zero page and $0100-$02FF (the
; stack, low.s).  On the Master the bar is at $2B00 and the ring at $3000 in main and
; shadow RAM; below them its handler, chain and their state, and LV_PAGE0.  Every
; level is gathered from the disc into the banks by the loader (ldprog.s), which runs
; in main RAM while the palette is black.
; ============================================================================
VSPEG     = 3                       ; vsyncs a rendered frame (game.s): 16.7 Hz of render
IMG_GAME  = 0                       ; bank 7's images (disc.s load_image, ldprog.s
IMG_MENU  = 1                       ; image_load)

SWAPTAB   = $BB00                   ; static in bank 4, below the mask tables: dot
MASKTAB0  = $BC00                   ; reversal (bank 5 draws nothing mirrored); the
MASKTAB1  = MASKTAB0 + $100         ; four mask-phase pages end both sprite banks
MASKTAB2  = MASKTAB0 + $200
MASKTAB3  = MASKTAB0 + $300
BANKENTRY = $8000                   ; banks 4, 5 and 6: the routine bank 7 calls once a
                                    ; sprite or rect starts the bank (low.s callbank):
                                    ; the sprite row loop's ds_entry, bank6_entry
TILES     = $8600                   ; bank 6: this level's tiles, 64 bytes a slot from this
                                    ; page (drawrect's gather is arithmetic): id k's slot
                                    ; is k + TOFF (assets.inc), so the first tile (id 1;
                                    ; id 0 is the solid, filled) sits at the first 64 bytes
                                    ; clear of the code and its variables
LV_MAP    = MAP5                    ; bank 5, $9C00: row major, a fixed 8K below the
                                    ; mask tables; the level's sprites below it
  .if BHW
LV_OBJS   = $7C00                   ; the level's objects, 6 bytes each (894 at most): main RAM (the
                                    ; display, black while they are read: level_init
                                    ; reads them once, before the first render)
  .else                             ; the Master: main RAM below the screen
LV_OBJS   = $1C00                   ; (the loader's program ends by $1BFF)
LV_PAGE0  = $0400                   ; tile id -> the gather's pair: 256 lo, 256 hi (the
                                    ; level's, the loader's), page aligned
  .endif

; ---------------------------------------------------------------- zero page
; The engine's first (ZEROPAGE: these, then engine.s's; the Model B's own, ZPHW,
; after them), then the game's (ZPGAME: BINI here, then logic.s's), $00-$EF (the
; cfgs).  $F0-$FF is the MOS's, and the engine's (engine.s ZPF0/ZPF5/ZPFD), all but
; $F4 (ROMSEL_CPY) and $FC (the interrupt entry's A).  Those used before engine.s
; are here, so every access is assembled as zero page.
        .zeropage
NSPR:     .res 1                    ; the sprite list's length (the game's addsprite)
BARDIRTY: .res 1                    ; the bar's digits to redraw (the game sets it)
SFXREQ:   .res 1                    ; a sound effect asked for (the game; sound_tick)
mtmp:     .res 1                    ; cpu.inc's scratch (inca/deca/bitimm/ldazy)
ringbhi:  .res 1                    ; the buffer being drawn: ring base high byte,
ringehi:  .res 1                    ;   ring end high byte (ringup's fold test),
ringe3:   .res 1                    ;   >RINGEND-3 and 256->RINGEND (drawrect's wrap test)
ringneg:  .res 1
mrow:     .res 1                    ; the map char row in the ring's last slot (calc_ring)
wcxm:     .res 1                    ; ringS mod 80: the mirror's first useful char
sp_disp:  .res 1                    ; the sprite's blitter index, for the loop's bank
sp_mpg0:  .res 1
sp_mh:    .res 1
sp_mrp:   .res 2
sp_mbase: .res 2
curR7:    .res 1                    ; two hot scalars (profiled: ~41 and ~35 accesses a
SECIDX:   .res 1                    ;  frame): the chain's R7 and step
        .segment "ZPGAME": zeropage
BINI:     .res 1                    ; the bin walk's index (44-64 accesses a frame)
        .zeropage

; ---------------------------------------------------------------- display
LINE      = 64                      ; T1 ticks in one scanline
BARCRTC   = BARADDR / 8
  .if BHW
CRTCB_A   = RING_A / 8              ; each buffer's ring base, as the CRTC counts
CRTCB_B   = RING_B / 8
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
  .else                             ; the Master: the screen, both copies of it --
STAGE     = $3000                   ; a shared file in SHADOW RAM (ACCCON X = 1 while it
STAGE_LVL = $3000                   ; is read or copied), the level's in main RAM
  .endif
FDC8271_CMD = $FE80                 ; the Model B's 8271: command/status, parameter/result, data
FDC8271_PAR = $FE81
FDC8271_DAT = $FE84
  .if BHW
FDC1770_CTL = $FE80                 ; the Acorn 1770 board: the drive control latch,
FDC1770_CMD = $FE84                 ; then the WD1770 at $FE84-$FE87
FDC1770_TRK = $FE85
FDC1770_SEC = $FE86
FDC1770_DAT = $FE87
FDC_RESET   = $08                   ; the latch: reset held (bit 5 low), FM
FDC_DRV0    = $29                   ;   reset released, FM, drive 0 / drive 1 (bits 0, 1)
FDC_DRV1    = $2A
FDC_SIDE1   = $04                   ;   side 1 (bit 2)
  .else
FDC1770_CTL = $FE24                 ; the Master's: its drive control latch, then the
FDC1770_CMD = $FE28                 ; WD1770 at $FE28-$FE2B
FDC1770_TRK = $FE29
FDC1770_SEC = $FE2A
FDC1770_DAT = $FE2B
FDC_RESET   = $20                   ; the latch: reset held (bit 2 low)
FDC_DRV0    = $25                   ;   reset released, FM, drive 0 / drive 1 (bits 0, 1)
FDC_DRV1    = $26
FDC_SIDE1   = $10                   ;   side 1 (bit 4)
  .endif

