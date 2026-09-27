; ============================================================================
; The addresses, for both machines (BHW, cpu.inc: the hardware).  The code lives in
; four sideways banks, each with the data its inner loops read:
;   4  the sprite row loop (with the mirrored blitter), most of the sprite images
;      and masks, SWAPTAB and the mask tables
;   5  the row loop again (no mirrored blitter), the gather and fetch8, the rest of
;      the sprites, the map (a fixed 8K) and the mask tables; the title pack goes
;      over them for the menus
;   6  the tile blitter and the ring work, then the level's tiles from TILES; the
;      menu overlay (the menus, the tune, the font) goes over the tiles for the menus
;   7  the level's tables, then the logic, the game loop, the sprite prologue and
;      its records, the HUD, the disc driver, the level's sprite directory; on the
;      Model B the display driver, the interrupt's work and the sound too
; Main RAM on the Model B is the display from $0300 -- the bar, two mirrors and two
; 23-slot rings (engine.s, screen shape) -- leaving zero page and $0100-$02FF (the
; stack, low.s).  On the Master the bar is at $2B00 and the ring at $3000 in main and
; shadow RAM; below them its handler, chain and their state, and LV_PAGE0.  Every
; level is gathered from the disc into the banks by the loader (ldprog.s), which runs
; in main RAM while the palette is black.
; ============================================================================
VSPEG     = 3                       ; vsyncs a rendered frame (game.s): 16.7 Hz of render

SWAPTAB   = $BB00                   ; static in bank 4, below the mask tables: dot
MASKTAB0  = $BC00                   ; reversal (bank 5 draws nothing mirrored); the
MASKTAB1  = MASKTAB0 + $100         ; four mask-phase pages end both sprite banks
MASKTAB2  = MASKTAB0 + $200
MASKTAB3  = MASKTAB0 + $300
BANKENTRY = $8000                   ; banks 4, 5 and 6: the routine bank 7 calls once a
                                    ; sprite or rect starts the bank (low.s callbank):
                                    ; the sprite row loop's ds_entry, bank6_entry
  .if TILEMIRROR                    ; (cpu.inc) the mirror's code takes the page below
TILES     = $8700                   ; bank 6: this level's tiles, 64 bytes each, by id,
  .else
TILES     = $8600                   ; bank 6: this level's tiles, 64 bytes each, by id,
  .endif
                                    ; page aligned (drawrect's gather is arithmetic);
                                    ; slot 0 is id 0, the solid: filled, never stored
TILES_END = $BF58                   ; and to here: above, the solid's fill (TILHI, the
                                    ; Model B's size on both; convert.py B_TILES_END)
MENU_BASE = TILES                   ; or the menu overlay, over them
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
; The ZEROPAGE segment ends below $A3 (the cfgs cap it) and the logic's temporaries
; are $A8-$DE (logic.s): these fill the gaps.  $F0-$FF is the MOS's, and engine.s's
; (ZPF0/ZPF5/ZPFD), all but $F4 (ROMSEL_CPY) and $FC (the interrupt entry's A).
NSPR     = $A3
BARDIRTY = $A4
SFXREQ   = $A6
mtmp     = $DF                      ; cpu.inc's scratch (inca/deca/bitimm/ldazy)
ringbhi  = $E0                      ; the buffer being drawn: ring base high byte,
ringehi  = $E1                      ;   ring end high byte (ringup's fold test),
ringe3   = $E2                      ;   >RINGEND-3 and 256->RINGEND (drawrect's wrap test)
ringneg  = $E3
mrow     = $E4                      ; the map char row in the ring's last slot (calc_ring)
wcxm     = $E5                      ; ringS mod 80: the mirror's first useful char
sp_disp  = $E7                      ; the sprite's blitter index, for the loop's bank
sp_mpg0  = $E8
sp_mh    = $E9
sp_mrp   = $EA                      ; 2
sp_mbase = $EC                      ; 2
BINI     = $A5                      ; three hot scalars (profiled: 44-64, ~41 and ~35
curR7    = $EE                      ;  accesses a frame): the bin walk's index, and the
SECIDX   = $EF                      ;  chain's R7 and step
fcA      = $A7                      ; xcall's A across the bank switch (low.s)
.assert SECIDX < $F0, error, "zero page runs into the MOS's"

; ---------------------------------------------------------------- display
  .if BHW                           ; (the Master's are engine.s's)
LINE      = 64                      ; T1 ticks in one scanline
BARCRTC   = BARADDR / 8
CRTCB_A   = RING_A / 8
CRTCB_B   = RING_B / 8
; CA1 fires at the end of the 2-line vsync pulse.  -35 would put each step ~5 us INTO
; its section; the further -36 puts it ~30 us BEFORE the restart, so the shape
; registers land early in the section's first scanline.  The interrupt stub's bank
; switch stands in for the hold the Master's handler has; it goes through pagelogic
; (the write bank too), which makes both the vsync's T1 restart and every step ~23
; cycles later -- 46 in all, 23 ticks -- and the -23 takes that back: R9 lands at
; char 41-53 of the section's first scanline (measured).
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

