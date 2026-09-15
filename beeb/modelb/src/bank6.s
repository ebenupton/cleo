; ============================================================================
; Bank 6: the map, the level's tables, and the routines that read them.  The
; tile blitter and the logic live in other banks, so what leaves here goes
; through a strip copy into MAPBUF in main RAM, or one byte through mapbyte.
; ============================================================================
        .segment "MAPCODE"
; map_strip: copy cnt map bytes from tile (tmp, tmp2) into MAPBUF.
map_strip:
        stz w16+1                   ; stz is lda #0 on a 6502: it cannot go between
        lda tmp2                    ; the load of ty and the shifts that use it
        ldx #MAPLW                  ; * the map's stride
@sh:    asl
        rol w16+1
        dex
        bne @sh
        clc
        adc tmp
        sta w16
        lda w16+1
        adc #0
        clc
        adc #>LV_MAP
        sta w16+1
        lda w16
        clc
        adc #<LV_MAP
        sta w16
        bcc :+
        inc w16+1
:       ldy #0
@cp:    lda (w16),y
        sta MAPBUF,y
        iny
        cpy cnt
        bne @cp
        rts

; map_rect: cnt tiles across by tmp3 rows down from tile (tmp, tmp2), row after row
; into MAPBUF.  One far call for a whole rectangle instead of one a tile row, which
; for a narrow one was the largest single cost of drawing it.
map_rect:
        stz w16+1
        lda tmp2
        ldx #MAPLW
@sh:    asl
        rol w16+1
        dex
        bne @sh
        clc
        adc tmp
        sta w16
        lda w16+1
        adc #0
        clc
        adc #>LV_MAP
        sta w16+1
        lda w16
        clc
        adc #<LV_MAP
        sta w16
        bcc :+
        inc w16+1
:       ldx #0                      ; x walks MAPBUF, y each row of the map
@row:   ldy #0
@cp:    lda (w16),y
        sta MAPBUF,x
        inx
        iny
        cpy cnt
        bne @cp
        lda w16                     ; the next map row is MAPW on
        clc
        adc #MAPW
        sta w16
        bcc :+
        inc w16+1
:       dec tmp3
        bne @row
        rts

; map_col: the same, but a column: cnt bytes down from tile (tmp, tmp2)
map_col:
        stz w16+1
        lda tmp2
        ldx #MAPLW
@sh:    asl
        rol w16+1
        dex
        bne @sh
        clc
        adc tmp
        sta w16
        lda w16+1
        adc #0
        clc
        adc #>LV_MAP
        sta w16+1
        lda w16
        clc
        adc #<LV_MAP
        sta w16
        bcc :+
        inc w16+1
:       ldx #0
        ldy #0
@cp:    lda (w16),y
        sta MAPBUF,x
        lda w16
        clc
        adc #MAPW
        sta w16
        bcc :+
        inc w16+1
:       inx
        cpx cnt
        bne @cp
        rts

; map_copy: cnt bytes from w16b in this bank into MAPBUF
map_copy:
        ldy #0
:       lda (w16b),y
        sta MAPBUF,y
        iny
        cpy cnt
        bne :-
        rts

        .segment "MAPDATA"
        .align 256                      ; the map, and only the map: the header, the
LV_MAP:                                 ; objects and the two tile tables are read by
        .incbin "build/map.bin"         ; the logic, which is in bank 7
; The sprite directory lives here too: bank 4 is full of pictures, and the blitter
; needs only ten bytes of it a sprite, which come across in one copy into MAPBUF.
SPRTAB: .incbin "build/sprtab.bin"
