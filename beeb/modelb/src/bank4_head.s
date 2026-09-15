; ============================================================================
; Bank 4: the sprite images, their mask planes, the four MASKTABs and the
; blitter.  Everything the inner loop touches is here, so a sprite is drawn
; without a single bank switch; what crosses is one far call per erased
; rectangle, into the tile blitter.
; ============================================================================
        .segment "SPRCODE"

.macro ringmod                      ; A = a map char row -> its ring slot
        tax
        lda RINGMODTAB,x
.endmacro
.macro ringup                       ; A = sp+1 just advanced: fold sp:A at the ring end
        .local done
        cmp ringehi
        bcc done
        pha                         ; the ring is 23 rows of 640, which is not a whole
        lda sp                      ; number of pages, so the low byte moves too
        sec
        sbc #<RINGBYTES
        sta sp
        pla
        sbc #>RINGBYTES
done:
.endmacro
.macro spnext                       ; the next char to the right, with the ring fold
        .local done
        lda sp
        clc
        adc #8
        sta sp
        bcc done
        lda sp+1
        inca
        ringup
        sta sp+1
done:
.endmacro

; sp = the address of char (w16, A) of the window's ring
ringaddr:
        ringmod
        tax
        lda w16+1
        sta sp+1
        lda w16
        asl
        rol sp+1
        asl
        rol sp+1
        asl
        rol sp+1                    ; sp+1:A = cx*8
        clc
        adc RINGLO,x
        sta sp
        lda sp+1
        adc RINGHI,x
        ringup
        sta sp+1
        rts

sext:   and #$80
        beq :+
        lda #$FF
:       sta tmp3
        rts

; ---------------------------------------------------------------- the pass
; draw every sprite on the list, keeping a record of where each landed so the
; next frame can erase it.
draw_sprites:
        lda curbuf
        beq :+
        lda #>(SPRREC + 10*MAXREC)
        bra :++
:       lda #>SPRREC
:       sta rp+1
        lda curbuf
        beq :+
        lda #<(SPRREC + 10*MAXREC)
        bra :++
:       lda #<SPRREC
:       sta rp
        lda #0
        sta spi
@l:     lda spi
        cmp NSPR
        bcs @done
        cmp #MAXREC
        bcs @done
        asl                         ; entry = SPRLIST + i*5
        asl
        clc
        adc spi
        tay
        lda SPRLIST+1,y
        sta spx
        lda SPRLIST+2,y
        sta spx+1
        lda SPRLIST+3,y
        sta spy
        lda SPRLIST+4,y
        sta spy+1
        lda SPRLIST,y
        ldy #0
        sta (rp),y                  ; the record starts with the id
        jsr drawsprite
        lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc spi
        bra @l
@done:  ldx curbuf
        lda spi
        sta RECCNT,x
        rts

; ---------------------------------------------------------------- erase
; put the tiles back where this buffer's sprites were two frames ago.  The
; record is in chars; the tile blitter wants tiles, so round outwards.
erase_old:
        ldx curbuf
        lda RECCNT,x
        beq @done
        sta tmp4
        lda curbuf
        beq :+
        lda #>(SPRREC + 10*MAXREC)
        bra :++
:       lda #>SPRREC
:       sta rp+1
        lda curbuf
        beq :+
        lda #<(SPRREC + 10*MAXREC)
        bra :++
:       lda #<SPRREC
:       sta rp
@l:     ldy #5
        lda (rp),y                  ; cx low (the high byte only matters past 255
        lsr                         ; chars, which no window reaches)
        lsr
        sta dt_tx
        ldy #7
        lda (rp),y                  ; cy
        lsr
        sta dt_ty
        ldy #5
        lda (rp),y
        and #3                      ; the columns the rounding down left out
        sta tmp2
        ldy #8
        lda (rp),y                  ; w in chars
        clc
        adc tmp2
        adc #3
        lsr
        lsr
        sta dt_nx
        ldy #7
        lda (rp),y
        and #1
        sta tmp2
        ldy #9
        lda (rp),y                  ; h in rows, bit 7 = it was clipped
        and #$7F
        clc
        adc tmp2
        adc #1
        lsr
        sta dt_ny
        lda dt_nx
        beq @next
        lda dt_ny
        beq @next
        farjsr F_DRAWRECT
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       dec tmp4
        bne @l
@done:  rts

; ---------------------------------------------------------------- tables
; MASKTABk[x] is the AND mask for the column of phase k in mask byte x: the
; blitter indexes by the whole byte and never shifts.
init_masks:
        ldx #0
@mt:    txa
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        tay
        lda mask4,y
        sta MASKTAB0,x
        txa
        lsr
        lsr
        lsr
        lsr
        and #3
        tay
        lda mask4,y
        sta MASKTAB1,x
        txa
        lsr
        lsr
        and #3
        tay
        lda mask4,y
        sta MASKTAB2,x
        txa
        and #3
        tay
        lda mask4,y
        sta MASKTAB3,x
        txa                         ; and the four-dot reversal for mirroring:
        and #$88                    ; dot i is bit 7-i and bit 3-i, so 7<->4,
        lsr                         ; 6<->5, 3<->0, 2<->1
        lsr
        lsr
        sta tmp
        txa
        and #$44
        lsr
        ora tmp
        sta tmp
        txa
        and #$22
        asl
        ora tmp
        sta tmp
        txa
        and #$11
        asl
        asl
        asl
        ora tmp
        sta SWAPTAB,x
        inx
        bne @mt
        ; the directory carries offsets from the start of the sprite data
        lda #<SPRTAB
        sta ptr
        lda #>SPRTAB
        sta ptr+1
        ldx #103
@fx:    ldy #0
        lda (ptr),y
        clc
        adc #<SPRDATA
        sta (ptr),y
        iny
        lda (ptr),y
        adc #>SPRDATA
        sta (ptr),y
        lda ptr
        clc
        adc #8
        sta ptr
        bcc :+
        inc ptr+1
:       dex
        bne @fx
        lda #<SPRMSKTAB
        sta ptr
        lda #>SPRMSKTAB
        sta ptr+1
        ldx #103
@fm:    ldy #0
        lda (ptr),y
        clc
        adc #<SPRDATA
        sta (ptr),y
        iny
        lda (ptr),y
        adc #>SPRDATA
        sta (ptr),y
        lda ptr
        clc
        adc #2
        sta ptr
        bcc :+
        inc ptr+1
:       dex
        bne @fm
        rts

; the logic is in another bank, so it hands sprites over one at a time
addsprite:                          ; A = id, spx/spy = map px of the reference point
        ldx NSPR
        cpx #MAXSPR
        bcs @full
        sta tmp2                    ; the id, while X is turned into the list offset
        stx tmp
        txa
        asl
        asl
        clc
        adc tmp
        tay
        lda tmp2
        sta SPRLIST,y
        lda spx
        sta SPRLIST+1,y
        lda spx+1
        sta SPRLIST+2,y
        lda spy
        sta SPRLIST+3,y
        lda spy+1
        sta SPRLIST+4,y
        inc NSPR
@full:  rts
