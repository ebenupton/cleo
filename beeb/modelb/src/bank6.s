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

; alt_row: tmp2 = tile id -> MAPBUF[0..7] = the altitude row of its class
alt_row:
        ldx tmp2
        lda LV_ACLS,x
        asl
        asl
        asl
        clc
        adc #<LV_ALT
        sta w16
        lda #0
        adc #>LV_ALT
        sta w16+1
        ldy #7
:       lda (w16),y
        sta MAPBUF,y
        dey
        bpl :-
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
        .align 256
LV_HDR:
        .incbin "build/level.bin"       ; header, objects, attributes, alt classes
LV_ALT:
        .incbin "build/alt.bin"
        .align 256
LV_MAP:
        .incbin "build/map.bin"
LV_OBJS = LV_HDR + 32
LV_ATTR = LV_HDR + 32 + 256
LV_ACLS = LV_HDR + 32 + 256 + 256
