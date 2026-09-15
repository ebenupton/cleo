; ============================================================================
; Bank 5: this level's tiles and the blitter that draws them.  A tile is 8 game
; pixels square: 4 chars wide and 2 char rows tall, 64 bytes, and 1840 (the ring
; in chars) divides by 4, so a tile's four chars are always contiguous -- only
; whole tiles can straddle the ring end, never their columns.
; ============================================================================
        .segment "TILCODE"
; draw_maprect: the tile rectangle (dt_tx, dt_ty) size (dt_nx, dt_ny), into the
; ring where the window arithmetic says it goes.  A map char (cx, cy) is ring
; char ((cy mod 23)*80 + cx) mod 1840, which does not depend on the window.
draw_maprect:
@row:   lda dt_tx                   ; one strip of map per tile row
        sta tmp
        lda dt_ty
        sta tmp2
        lda dt_nx
        sta cnt
        farjsr F_MAPSTRIP
        lda dt_ty                   ; char row = 2*ty, and its ring slot
        asl
        jsr ring_row                ; -> dst0
        lda dt_tx                   ; + 4*tx chars = 32*tx bytes, which is 16 bit
        sta w16                     ; from tx = 8 on
        stz w16+1
        ldx #5
:       asl w16
        rol w16+1
        dex
        bne :-
        lda dst0
        clc
        adc w16
        sta dst0
        lda dst0+1
        adc w16+1
        sta dst0+1
        jsr ring_next               ; dst1 = the char row below
        ldx #0
        stx dt_i
@tile:  ldx dt_i
        lda MAPBUF,x
        jsr draw_tile
        lda dst0                    ; the next tile is four chars on
        clc
        adc #32
        sta dst0
        bcc :+
        inc dst0+1
:       lda dst1
        clc
        adc #32
        sta dst1
        bcc :+
        inc dst1+1
:       inc dt_i
        lda dt_i
        cmp dt_nx
        bne @tile
        inc dt_ty
        dec dt_ny
        bne @row
        rts

; ring_row: A = char row -> dst0 = the address of its first char in the ring
ring_row:
        tax
        lda RINGMODTAB,x            ; the slot
        tax
        lda RINGLO,x
        sta dst0
        lda RINGHI,x
        sta dst0+1
        rts

; ring_next: dst1 = dst0 + one char row, folded at the ring end
ring_next:
        lda dst0
        clc
        adc #<ROWBYTES
        sta dst1
        lda dst0+1
        adc #>ROWBYTES
        cmp ringehi
        bcc :+
        pha                         ; past the end: - RINGBYTES, which is not a
        lda dst1                    ; whole number of pages
        sec
        sbc #<RINGBYTES
        sta dst1
        pla
        sbc #>RINGBYTES
:       sta dst1+1
        rts

; draw_tile: A = tile id, dst0/dst1 = where its two char rows go
draw_tile:
        cmp #EMPTYTILE              ; nothing to draw for a hole in the map
        beq @done
        pha
        lsr
        lsr
        clc
        adc #>TILES                 ; the tiles are page aligned: id*64 is
        sta tp+1                    ; (id >> 2) pages plus (id & 3) * 64
        pla
        and #3
        asl
        asl
        asl
        asl
        asl
        asl
        sta tp
        ldy #31
:       lda (tp),y
        sta (dst0),y
        dey
        bpl :-
        lda tp
        clc
        adc #32
        sta tp
        bcc :+
        inc tp+1
:       ldy #31
:       lda (tp),y
        sta (dst1),y
        dey
        bpl :-
@done:  rts

        .segment "TILDATA"
        .align 256
TILES:  .incbin "build/tiles.bin"
