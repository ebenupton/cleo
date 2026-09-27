; ============================================================================
; The banks' static tables, the level's space in bank 7 and the few routines that
; exist only here.  Everything a level brings -- tiles, map, sprites, directory, its
; tables -- is loaded into the banks by ldprog.s; the menus' image of bank 7 (MNUCODE
; on) is the menus with the tune, the font and the title pieces, and is loaded the
; same way, over the game's.
; ============================================================================

; ---------------------------------------------------------------- the small tables
; Assembled, each in the bank of the code that indexes it: the row multiples are
; bank 7's (calc_ring, ringaddr7, the chain), the ring modulus bank 6's (ringaddr).
        .segment "KRNDATA"          ; (the kernel's: calc_ring and ringaddr7 are there)
        .assert RINGROWS <= 32, error, "the row multiples are sized for 32"
mulrowlo:                           ; (32 rows on both machines, the Master's ring, so
.repeat 32, i                       ; bank 7's data lies alike: the Model B reads 23)
        .byte <(i*ROWCHARS)
.endrepeat
mulrowhi:
.repeat 32, i
        .byte >(i*ROWCHARS)
.endrepeat
  .if BHW                           ; (the Master's ring is 32 rows: ringmod is and #31)
        .segment "TILCODE"
ringmodtab:                         ; A = a map char row (brought under RINGROWS*5 by
.repeat RINGROWS*5, i               ; the ringmod macro) -> its ring slot
        .byte i .mod RINGROWS
.endrepeat
  .endif

; ---------------------------------------------------------------- the sprite banks
; MASKTAB0..3 at the same address in both banks that hold sprite data, so the
; prologue in bank 7 can name a mask page for either; SWAPTAB in bank 4 alone
; (bank 5 draws nothing mirrored: the packer keeps such images out, and that page
; holds the map instead).  MODE 1: four pixels a byte, two bits each.
.macro MASK4 f                      ; AND mask by pair: keep what is NOT opaque
  .if f = 0
        .byte $FF
  .elseif f = 1
        .byte $CC
  .elseif f = 2
        .byte $33
  .else
        .byte $00
  .endif
.endmacro
.macro MASK_TABLES
        .assert * = MASKTAB0, error, "MASKTAB0 must be at the same address in both sprite banks"
.repeat 4, kk                       ; MASKTABk[x] = mask4[(x >> (6 - 2k)) & 3]
  .repeat 256, xx
        MASK4 {((xx >> (6 - 2*kk)) & 3)}
  .endrepeat
.endrepeat
.endmacro
        .segment "SPR4SWAP"
        .assert * = SWAPTAB, error, "SWAPTAB must be at SWAPTAB"
.repeat 256, xx                     ; four-dot reversal: bits 7<->4, 6<->5, 3<->0, 2<->1
        .byte ((xx & $88) >> 3) | ((xx & $44) >> 1) | ((xx & $22) << 1) | ((xx & $11) << 3)
.endrepeat
        .segment "SPR4MASK"
        MASK_TABLES
        .segment "SPR5MASK"
        MASK_TABLES

; ---------------------------------------------------------------- the mirror's notes
; the mirror's range: A = the first window column written of the row the mirror
; follows, X = the last (0..79).  Those chars sit in the last slot row at wcxm on;
; only the ones up to char 79 are in it (the rest wrapped to slot row 0), and only
; those from wcxm are ever read (mirror.s).  Called by the tile blitter's head
; (bank 6: mirdirty6) and the sprite prologue and copy_partial (bank 7: mirdirty):
; one body, twice.
        .segment "TILBSS"
  .if BHW                           ; (the Master has no mirror: the hardware folds)
.macro MIRDIRTY_BODY
        clc
        adc wcxm
        cmp #ROWCHARS
        bcs @out
        pha
        txa                         ; C clear: bcs @out not taken
        adc wcxm
        cmp #ROWCHARS
        bcc :+
        lda #ROWCHARS-1
:       tax
        ldy curbuf
        lda #1
        sta mirdty,y
        pla
        cmp mirlo,y
        bcs :+
        sta mirlo,y
:       txa
        cmp mirhi,y
        bcc :+
        sta mirhi,y
:
@out:   rts
.endmacro
        .segment "TILCODE"
mirdirty6:
        MIRDIRTY_BODY
        .segment "ENGCODE"
mirdirty:
        MIRDIRTY_BODY
  .endif

        .segment "ENGCODE"          ; (the engine's per-level clear: load_level's)
lvreset:
        lda #$80                    ; both buffers invalid: an unreachable window x
        sta BUF_CX+1                ; (scroll_validate redraws them whole)
        sta BUF_CX+3
        lda #0                      ; (the caller stores this A: it must be 0)
        sta RECCNT
        sta RECCNT+1
        sta DIRTYCNT
        sta DIRTYCNT+1
        rts

; ---------------------------------------------------------------- bank 7: the level
        .segment "LGCLVL"           ; the level's tables, loaded by ldprog.s (the
LV_ATTR0:   .res 256                ; objects go to main RAM: LV_OBJS, defs.inc)
LV_ALTCLS:  .res 256                ; alt class by tile id
LV_HDR:     .res 32                 ; header: lw, lh, start, exit, nobj, the special
                                    ; tiles, gset, ntiles, maprow's shift
        .segment "LGCDATA"
LV_ALTTAB:                          ; alt class -> eight altitudes (global)
        .incbin "alt.bin"
digits_art:                         ; the HUD's ten digits, 16 bytes each: a nibble per
        .incbin "digits.bin"      ; byte column and two game rows (assets.py)
DIGTOP:     .incbin "digtab.bin", 0, 16   ; a nibble's top scanline byte
DIGBOT:     .incbin "digtab.bin", 16, 16  ; and its bottom one
        .segment "LGCBSS"
; the object state arrays, laid out as logic.s names them: O_STAMP + k*OBJN, then
; the grid heads and chains and the cached bin walk lists.  level_init's clear runs
; 2560 bytes from LV_OBJST, which stays inside these.
LV_OBJST:   .res 16*OBJN
LV_GRID:    .res 128
LV_BOBJ:    .res 256                ; an entry per object per grid cell it covers: up
LV_BNEXT:   .res 256                ; to 255 of them
LV_BINSTAR: .res BINMAX
LV_BINOTH:  .res BINMAX
        .assert 16*OBJN + 128 + 512 + 2*BINMAX >= 2560, error, "level_init's clear overruns the arrays"
        .segment "ENGBSS"           ; the engine's: the sprite directory
SPRMASK:    .res 2*BOXID0           ; mask plane address by sprite id (the boxes, from
                                    ; BOXID0, have none): the loader's, read by the
                                    ; prologue (this bank)
SPR_TABLE:  .res 118*8              ; the sprite directory as the packer finished it
                                    ; (the level's addresses): the loader's, read by
                                    ; the prologue in place

; ---------------------------------------------------------------- bank 7: the menus' image
        .segment "MNUDATA"
MUSIC_ADDR:                         ; 144 bytes of periods (the table itself, here),
        .incbin "music.bin"   ; then the note stream
font_art:                           ; the menus' 40 glyphs, 8 bytes each
        .incbin "font.bin"
        .include "title.inc"        ; the title pieces' directory (assets.py): tp_lo,
title_art:                          ; tp_hi, tp_cols, tp_rows; their streams (menu.s
        .incbin "title.bin"         ; unpack)
