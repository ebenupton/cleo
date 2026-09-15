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
        jsr fold0                   ; the columns can carry past the ring end
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
:       jsr fold0
        lda dst1
        clc
        adc #32
        sta dst1
        bcc :+
        inc dst1+1
:       jsr fold1
        inc dt_i
        lda dt_i
        cmp dt_nx
        bne @tile
        inc dt_ty
        dec dt_ny
        bne @row
        rts

; copy_partial: compose the row section A shows.  It is the 80 chars above the
; window, and holds lines wfine..7 of the window's first row in lines 0..7-wfine,
; so the playfield can scroll in two-scanline steps.
copy_partial:
        lda wfine
        bne :+
        rts
:
        lda ringS                   ; source = the window's first char
        sta w16
        lda ringS+1
        sta w16+1
        asl w16
        rol w16+1
        asl w16
        rol w16+1
        asl w16
        rol w16+1
        lda w16
        clc
        adc ringbase
        sta dst1                    ; dst1 is the source here, and carries the
        lda w16+1                   ; wfine offset: a positive offset under 8 on an
        adc ringbase+1              ; 8-aligned pointer leaves its page crossings on
        sta dst1+1                  ; the char boundaries, so the fold still works
        lda dst1                    ; destination = one row earlier, wrapped
        sec
        sbc #<ROWBYTES
        sta dst0
        lda dst1+1
        sbc #>ROWBYTES
        sta dst0+1
        cmp ringbase+1              ; below the base: + RINGBYTES
        bcs :+
        lda dst0
        clc
        adc #<RINGBYTES
        sta dst0
        lda dst0+1
        adc #>RINGBYTES
        sta dst0+1
:       lda #8                      ; bytes per char = 8 - wfine
        sec
        sbc wfine
        sta tmp2
        lda dst1                    ; the source starts wfine lines into the row
        clc
        adc wfine
        sta dst1
        bcc :+
        inc dst1+1
:       lda #ROWCHARS
        sta tmp
@char:  ldy #0
@l:     lda (dst1),y
        sta (dst0),y
        iny
        cpy tmp2
        bne @l
        lda dst0                    ; next char in both
        clc
        adc #8
        sta dst0
        bcc :+
        inc dst0+1
:       jsr fold0
        lda dst1
        clc
        adc #8
        sta dst1
        bcc :+
        inc dst1+1
:       jsr fold1
        dec tmp
        beq :+
        jmp @char
:       rts

; fold0/fold1: bring a destination back inside the ring.  A row of the window is
; 80 chars wherever it starts, so the columns of a tile row can run off the end.
fold0:
        lda dst0+1
        cmp ringehi
        bcc :+
        lda dst0
        sec
        sbc #<RINGBYTES
        sta dst0
        lda dst0+1
        sbc #>RINGBYTES
        sta dst0+1
:       rts
fold1:
        lda dst1+1
        cmp ringehi
        bcc :+
        lda dst1
        sec
        sbc #<RINGBYTES
        sta dst1
        lda dst1+1
        sbc #>RINGBYTES
        sta dst1+1
:       rts

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
