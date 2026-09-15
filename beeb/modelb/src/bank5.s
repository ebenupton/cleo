; ============================================================================
; Bank 5: this level's tiles and the blitter that draws them.  A tile is 8 game
; pixels square: 4 chars wide and 2 char rows tall, 64 bytes, and 1840 (the ring
; in chars) divides by 4, so a tile's four chars are always contiguous -- only
; whole tiles can straddle the ring end, never their columns.
; ============================================================================
        .segment "TILCODE"
; draw_maprect: the rectangle (dt_cx, dt_ty) size (dt_ncx chars, dt_ny tile rows),
; into the ring where the window arithmetic says it goes.  A map char (cx, cy) is
; ring char ((cy mod 23)*80 + cx) mod 1840, which does not depend on the window.
draw_maprect:
        jsr clip_rect               ; nothing left of the rectangle: nothing to draw
        bcc :+
        jmp dm_row
:       rts

; clip_rect: bring the rectangle -- chars (dt_cx, dt_ncx) by tile rows (dt_ty,
; dt_ny) -- inside both the window and the map.  Horizontally it has to be clipped
; to the CHAR, not the tile: the ring is 23 rows of 80 chars and the window is 22 of
; them, so a char written past the window's right edge lands on the ring slot of the
; window's leftmost chars one row down, which is still on screen.  Vertically the one
; spare ring row absorbs a row of overhang at either end, so tile rows are enough.
; C = 0 if nothing of the rectangle survives.
clip_rect:
        jmp @start
@out:   clc                         ; up here so every test can reach it backwards
        rts
@start: lda dt_ty
        cmp ty0
        bcs @t1
        lda ty0
        sec
        sbc dt_ty
        sta tmp
        lda dt_ny
        sec
        sbc tmp
        bcc @out
        beq @out
        sta dt_ny
        lda ty0
        sta dt_ty
@t1:    lda dt_ty
        clc
        adc dt_ny
        sta tmp
        lda ty0
        clc
        adc winy
        cmp tmp
        bcs @t2
        sec
        sbc dt_ty
        bcc @out
        beq @out
        sta dt_ny
@t2:    lda dt_cx                   ; ---- left edge, in chars
        cmp wcx
        bcs @t3
        lda wcx
        sec
        sbc dt_cx
        sta tmp
        lda dt_ncx
        sec
        sbc tmp
        bcc @out
        beq @out
        sta dt_ncx
        lda wcx
        sta dt_cx
@t3:    lda dt_cx                   ; ---- right edge
        clc
        adc dt_ncx
        sta tmp
        lda wcx
        clc
        adc #ROWCHARS
        cmp tmp
        bcs @m1
        sec
        sbc dt_cx
        bcc @out
        beq @out
        sta dt_ncx
        jmp @m1                     ; a second way out, in reach of the tests below
@out2:  clc
        rts
@m1:    lda dt_cx                   ; ---- the map's right edge, also in chars
        clc
        adc dt_ncx
        cmp #MAPW*4+1
        bcc @m2
        lda #MAPW*4
        sec
        sbc dt_cx
        bcc @out2
        beq @out2
        sta dt_ncx
@m2:    lda dt_ty
        clc
        adc dt_ny
        cmp #MAPH+1
        bcc @ok
        lda #MAPH
        sec
        sbc dt_ty
        bcc @out2
        beq @out2
        sta dt_ny
@ok:    sec
        rts

dm_row: lda dt_cx                   ; one strip of map per tile row: the tiles the
        lsr                         ; char range touches, first one first
        lsr
        sta tmp
        sta dt_t0
        lda dt_cx
        and #3
        sta dt_ls                   ; chars of the first tile that are not wanted
        clc
        adc dt_ncx
        clc
        adc #3
        lsr
        lsr
        sta dt_nt                   ; tiles the range spans
        sta cnt
        lda dt_ty
        sta tmp2
        farjsr F_MAPSTRIP
        lda dt_ty                   ; char row = 2*ty, and its ring slot
        asl
        jsr ring_row                ; -> dst0
        lda dt_t0                   ; + 4*tx chars = 32*tx bytes, which is 16 bit
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
        lda dt_ncx
        sta dt_rem
        lda dt_ls
        sta dt_s                    ; only the first tile starts part way in
        ldx #0
        stx dt_i
@tile:  lda #4                      ; how many of this tile's chars are wanted
        sec
        sbc dt_s
        cmp dt_rem
        bcc :+
        lda dt_rem
:       sta dt_n
        lda dt_rem
        sec
        sbc dt_n
        sta dt_rem
        ldx dt_i
        lda MAPBUF,x
        jsr draw_tile
        stz dt_s                    ; every tile after the first starts at its left
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
        cmp dt_nt
        bne @tile
        inc dt_ty
        dec dt_ny
        beq :+
        jmp dm_row
:
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

; draw_tile: A = tile id, dst0/dst1 = where its two char rows go, dt_s/dt_n = the
; first char of the tile to draw and how many (the whole tile is 0, 4)
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
        lda dt_s
        bne @topart
        lda dt_n
        cmp #4
        beq @full
@topart:jmp @part
@full:  ldy #0                      ; unrolled in eights: the dey/bpl per byte was a
        jsr @half32                 ; fifth of the cost of a tile
        lda tp
        clc
        adc #32
        sta tp
        bcc :+
        inc tp+1
:       lda dst0                    ; the second char row goes to dst1, and the caller
        pha                         ; still needs dst0 to step to the next tile
        lda dst0+1
        pha
        lda dst1
        sta dst0
        lda dst1+1
        sta dst0+1
        ldy #0
        jsr @half32
        pla
        sta dst0+1
        pla
        sta dst0
@done:  rts
@half32:
        .repeat 4
        .repeat 7
        lda (tp),y
        sta (dst0),y
        iny
        .endrepeat
        lda (tp),y
        sta (dst0),y
        iny
        .endrepeat
        rts
@part:  lda dt_n                    ; the edge tiles of a char-clipped rectangle: a
        bne :+                      ; run of dt_n chars starting dt_s chars in
        rts
:       asl
        asl
        asl
        sta dt_c
        lda dt_s
        asl
        asl
        asl
        tay
        ldx dt_c
:       lda (tp),y
        sta (dst0),y
        iny
        dex
        bne :-
        lda tp
        clc
        adc #32
        sta tp
        bcc :+
        inc tp+1
:       lda dst0
        pha
        lda dst0+1
        pha
        lda dst1
        sta dst0
        lda dst1+1
        sta dst0+1
        lda dt_s
        asl
        asl
        asl
        tay
        ldx dt_c
:       lda (tp),y
        sta (dst0),y
        iny
        dex
        bne :-
        pla
        sta dst0+1
        pla
        sta dst0
        rts

; the status bar's picture, copied into place once: it is single buffered and
; scanned where it is drawn.
bar_draw:
        lda #<BARIMG
        sta tp
        lda #>BARIMG
        sta tp+1
        lda #<BARADDR
        sta dst0
        lda #>BARADDR
        sta dst0+1
        ldx #5
        ldy #0
@l:     lda (tp),y
        sta (dst0),y
        iny
        bne @l
        inc tp+1
        inc dst0+1
        dex
        bne @l
        rts

        .segment "TILDATA"
        .align 256
TILES:  .incbin "build/tiles.bin"
BARIMG: .incbin "build/bar.bin"
