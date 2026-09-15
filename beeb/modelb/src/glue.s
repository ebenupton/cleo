; ============================================================================
; What the ported logic (logicm.s) asks of the engine, on this target.  The
; Master's names are kept so that logicm.s stays a copy of its logic.s: what
; differs is where things live, not what they do.
; ============================================================================
VIA_ORB   = $FE40
VIA_DDRA  = $FE43
VIA_ORANH = $FE4F

        .segment "LGCCODE"

; ---------------------------------------------------------------- the keyboard
; The MOS is gone by the time this runs, so the matrix is read directly.  The keys
; are the original's: Z and X or the cursors to walk, up or : to jump, RETURN to
; throw.
scan_keys:
        lda #$7F
        sta VIA_DDRA
        lda #3
        sta VIA_ORB                 ; autoscan off: the matrix is read directly
        lda #0
        sta tmp
        ldx #9                      ; down and throw as well as the walk and the jump
@k:     lda keytab,x
        sta VIA_ORANH
        lda VIA_ORANH
        bpl :+
        lda keybits,x
        ora tmp                     ; no tsb on a 6502
        sta tmp
:       dex
        bpl @k
        lda tmp
        sta keys
        rts
keytab:  .byte $61,$19, $42,$79, $48,$39,$49, $68,$29, $62
keybits: .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE, K_DOWN,K_DOWN, K_FIRE


; ---------------------------------------------------------------- sprites
; The list and the blitter are in bank 4 together, so this is a far call; on the
; Master addsprite is in main RAM and the thunk only pages the bank back.
m_addsprite:
        farjsr F_ADDSPR
        rts

; ---------------------------------------------------------------- the camera
; game_frame sets wx/wy to where it wants the window; this clamps it to the map
; and works out the char window the renderer scrolls by.
m_clamp_window:
        lda wx+1                    ; wx < 0 -> 0
        bpl :+
        stz wx
        stz wx+1
:       lda wx+1
        cmp #>(MAPW*8-160)
        bcc @xok
        bne :+
        lda wx
        cmp #<(MAPW*8-160)
        bcc @xok
:       lda #<(MAPW*8-160)
        sta wx
        lda #>(MAPW*8-160)
        sta wx+1
@xok:   lda wy+1
        bpl :+
        stz wy
        stz wy+1
:       lda wy+1
        cmp #>(MAPH*8-VISROWS*4)
        bcc @yok
        bne :+
        lda wy
        cmp #<(MAPH*8-VISROWS*4)
        bcc @yok
:       lda #<(MAPH*8-VISROWS*4)
        sta wy
        lda #>(MAPH*8-VISROWS*4)
        sta wy+1
@yok:   lda wx+1                    ; wcx = wx >> 1 (a char is two game pixels)
        lsr
        sta wcx+1
        lda wx
        ror
        sta wcx
        lda wy                      ; wfine = (wy & 3) * 2 scanlines
        and #3
        asl
        sta wfine
        lda wy+1                    ; wcy = wy >> 2 (a char row is four pixels)
        lsr
        sta tmp
        lda wy
        ror
        lsr tmp
        ror
        sta wcy
        rts

; ---------------------------------------------------------------- the map changed
; mapput writes a tile into the map; both buffers hold the old one.  The tile is
; remembered with an age of two, and every frame the ages are walked and each
; still-live tile is redrawn into the buffer being drawn.
MAXDIRT = 12
m_mark_dirty:                       ; A = tx, X = ty
        ldy NDIRT
        cpy #MAXDIRT
        bcs @full                   ; the list overflowed: the rectangle draw below
        sta DIRTX,y                 ; will not repair it, but nothing is lost that a
        txa                         ; scroll over it does not put back
        sta DIRTY_,y
        lda #2                      ; once into each buffer
        sta DIRTAGE,y
        inc NDIRT
@full:  rts

; draw every remembered tile into the buffer being drawn, and forget the ones that
; have now been into both
dirt_flush:
        lda NDIRT
        beq @none
        ldx #0
@l:     lda DIRTAGE,x
        beq @next
        lda DIRTX,x
        asl                         ; a tile is four chars across and two rows down
        asl
        sta dt_cx
        lda #4
        sta dt_ncx
        lda DIRTY_,x
        asl
        sta dt_cy
        lda #2
        sta dt_ncy
        phx
        farjsr F_DRAWRECT
        plx
        dec DIRTAGE,x
@next:  inx
        cpx NDIRT
        bcc @l
        ldx #0                      ; compact: drop the entries that are done
        ldy #0
@c:     lda DIRTAGE,x
        beq :+
        sta DIRTAGE,y
        lda DIRTX,x
        sta DIRTX,y
        lda DIRTY_,x
        sta DIRTY_,y
        iny
:       inx
        cpx NDIRT
        bcc @c
        sty NDIRT
@none:  rts

; ---------------------------------------------------------------- the map
        .assert MAPLW = 5, error, "maprow assumes a 32-tile map row"
maprow:                             ; A = tile row -> mapptr
        pha
        and #7
        asl
        asl
        asl
        asl
        asl
        sta mapptr
        pla
        lsr
        lsr
        lsr
        clc
        adc #>LV_MAP
        sta mapptr+1
        rts


; ---------------------------------------------------------------- the map's shape
; The Master builds a row address table per level; here the map is one fixed size
; and maprow computes the address, so this only has to say how big it is.
init_maprows:
        lda #MAPLW
        sta maplw
        lda #0
        sta mapw
        sta maph
        lda #MAPW/32                ; the map in pixels: tiles * 8
        sta mapw+1
        lda #MAPH/32
        sta maph+1
        rts

; ---------------------------------------------------------------- random
m_rnd:  lsr seed+1
        ror seed
        bcc :+
        lda seed+1
        eor #$B4
        sta seed+1
:       lda seed
        rts

; ---------------------------------------------------------------- the level
; The logic reads these in its own bank: the map itself stays in bank 6, where the
; tile blitter can fetch a strip of it without leaving its own.
        .segment "LGCDATA"
        .align 256
LV_HDR:                                 ; header, objects, attributes, alt classes
        .incbin "build/level.bin"
LV_ALTTAB:                              ; alt class -> eight altitudes
        .incbin "build/alt.bin"
SPR_DIGITS:                             ; the HUD's ten digits, 64 bytes each.  They
        .incbin "build/digits.bin"      ; are in this bank, so HUD_BANK is this bank
                                        ; and the setbank around the blit is a no-op
LV_OBJS  = LV_HDR + 256                 ; page aligned, as the logic's entry pointer
LV_ATTR0 = LV_HDR + 512                 ; arithmetic assumes
LV_ALTCLS= LV_HDR + 768

        .segment "LGCBSS"
LV_OBJST: .res 16*OBJN                  ; the object state arrays
LV_GRID:  .res 128                      ; the collision grid's heads
LV_BOBJ:  .res OBJN+1                   ; and its chains
LV_BNEXT: .res OBJN+1
LV_BINSTAR: .res BINMAX                 ; the cached bin walk: stars, then the rest
LV_BINOTH:  .res BINMAX
bvalid:   .res 2                        ; per buffer: has it ever been drawn, and the
bptx:     .res 2                        ; window origin in chars it was last drawn for
bpty:     .res 2
seed:     .res 2
NDIRT:    .res 1
DIRTX:    .res MAXDIRT
DIRTY_:   .res MAXDIRT
DIRTAGE:  .res MAXDIRT
; the logic's own engine-side variables, which on the Master live in its zero page
BARDIRTY: .res 1
BARCACHE: .res 16
BINR:     .res 4
NSTARL:   .res 1
NOTHL:    .res 1
BINI:     .res 1
BINOK:    .res 1
SFXREQ:   .res 1
mapw:     .res 2
maph:     .res 2
maplw:    .res 1
