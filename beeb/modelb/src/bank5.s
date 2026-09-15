; ============================================================================
; Bank 5: this level's tiles and the blitter that draws them.  A tile is 8 game
; pixels square: 4 chars wide and 2 char rows tall, 64 bytes, and 1840 (the ring
; in chars) divides by 4, so a tile's four chars are always contiguous -- only
; whole tiles can straddle the ring end, never their columns.
; ============================================================================
        .segment "TILCODE"
; draw_maprect: the rectangle (dt_cx, dt_cy) size (dt_ncx chars, dt_ncy char rows),
; into the ring where the window arithmetic says it goes.  A map char (cx, cy) is
; ring char ((cy mod 23)*80 + cx) mod 1840, which does not depend on the window.
; Both axes are in chars, not tiles: the window moves a char at a time in either, and
; a rectangle rounded out to whole tiles does twice the work and -- across the ring's
; 80-char rows -- lands on slots that are still on screen.
draw_maprect:
        jsr clip_rect               ; nothing left of the rectangle: nothing to draw
        bcs :+
        rts
:       lda mrow                    ; does it write the row the mirror follows?
        sec
        sbc dt_cy
        bcc :+
        cmp dt_ncy
        bcs :+
        ldx curbuf
        lda #1
        sta mirdty,x
:       lda dt_cx                   ; the tiles the char range spans, first one first
        lsr
        lsr
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
        lda #$FF
        sta dt_lastty               ; no map strip fetched yet
        lda dt_cy                   ; the first row's ring address, once: every row
        jsr ring_row                ; below it is one row of bytes further on
        lda dt_t0                   ; + 4*t0 chars = 32*t0 bytes, which is 16 bit
        sta w16                     ; from t0 = 8 on
        stz w16+1
        ldx #5
:       asl w16
        rol w16+1
        dex
        bne :-
        lda dst0
        clc
        adc w16
        sta dst1                    ; dst1 is the row base; dst0 walks the tiles
        lda dst0+1
        adc w16+1
        cmp ringehi
        bcc :+
        pha                         ; past the ring end: - RINGBYTES, which is not a
        lda dst1                    ; whole number of pages
        sec
        sbc #<RINGBYTES
        sta dst1
        pla
        sbc #>RINGBYTES
:       sta dst1+1
        jmp dm_row

; clip_rect: bring the rectangle inside both the window and the map.  Both axes are
; clipped to the char: the ring is 23 rows of 80 chars and the window is 22 of them,
; so a char written past the window's right edge lands on the ring slot of the
; window's leftmost chars one row down, which is still on screen.  C = 0 if nothing
; of the rectangle survives.
clip_rect:
        jmp @start
@out:   clc                         ; up here so every test can reach it backwards
        rts
@start: lda dt_cy                   ; ---- top edge
        cmp wcy
        bcs @t1
        lda wcy
        sec
        sbc dt_cy
        sta tmp
        lda dt_ncy
        sec
        sbc tmp
        bcc @out
        beq @out
        sta dt_ncy
        lda wcy
        sta dt_cy
@t1:    lda dt_cy                   ; ---- bottom edge
        clc
        adc dt_ncy
        sta tmp
        lda wcy
        clc
        adc #BUFROWS
        cmp tmp
        bcs @t2
        sec
        sbc dt_cy
        bcc @out
        beq @out
        sta dt_ncy
@t2:    lda dt_cx                   ; ---- left edge
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
@m1:    lda dt_cx                   ; ---- the map's right edge
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
@m2:    lda dt_cy                   ; ---- and its bottom
        clc
        adc dt_ncy
        cmp #MAPH*2+1
        bcc @ok
        lda #MAPH*2
        sec
        sbc dt_cy
        bcc @out2
        beq @out2
        sta dt_ncy
@ok:    sec
        rts

dm_row: lda dt_cy                   ; one char row: half of a row of tiles
        lsr
        cmp dt_lastty               ; the strip is per tile row, so the second char
        beq @haverow                ; row of a pair reuses it
        sta dt_lastty
        sta tmp2
        lda dt_t0
        sta tmp
        lda dt_nt
        sta cnt
        farjsr F_MAPSTRIP
@haverow:
        lda dt_cy
        and #1                      ; the tile's second char row is 32 bytes on
        beq :+
        lda #32
:       sta dt_half
        lda dst1                    ; the row's first char
        sta dst0
        lda dst1+1
        sta dst0+1
        lda dt_ncx
        sta dt_rem
        lda dt_ls
        sta dt_s                    ; only the first tile starts part way in
        ldx #0
        stx dt_i
@tile:  lda dt_s                    ; a whole tile, which is every tile but the two at
        bne @edge                   ; the ends of the rectangle
        lda dt_rem
        cmp #4
        bcc @edge
        sbc #4
        sta dt_rem
        ldx dt_i
        lda MAPBUF,x
        jsr draw_tile_full
        bra @adv
@edge:  lda #4                      ; how many of this tile's chars are wanted
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
@adv:   stz dt_s                    ; every tile after the first starts at its left
        lda dst0                    ; the next tile is four chars on, and the columns
        clc                         ; of a row can carry past the ring end
        adc #32
        sta dst0
        bcc @nc
        inc dst0+1
        lda dst0+1
        cmp ringehi
        bcc @nc
        lda dst0
        sec
        sbc #<RINGBYTES
        sta dst0
        lda dst0+1
        sbc #>RINGBYTES
        sta dst0+1
@nc:    inc dt_i
        lda dt_i
        cmp dt_nt
        bne @tile
        inc dt_cy
        dec dt_ncy
        beq @done
        lda dst1                    ; the next char row is one row of bytes on
        clc
        adc #<ROWBYTES
        sta dst1
        lda dst1+1
        adc #>ROWBYTES
        cmp ringehi
        bcc :+
        pha
        lda dst1
        sec
        sbc #<RINGBYTES
        sta dst1
        pla
        sbc #>RINGBYTES
:       sta dst1+1
        jmp dm_row
@done:  rts

; til_copy: w16b = an address in this bank, cnt = bytes -> MAPBUF.  Every bank has
; one of these: it is the only way anything outside the bank can read its data.
til_copy:
        ldy #0
:       lda (w16b),y
        sta MAPBUF,y
        iny
        cpy cnt
        bne :-
        rts

; copy_partial: compose the row section A shows.  It is the 80 chars above the
; window, and holds lines wfine..7 of the window's first row in lines 0..7-wfine,
; so the playfield can scroll in two-scanline steps.
copy_partial:
        lda wfine
        bne :+
        rts
:       lda mrow                    ; the composed row is the ring row above the
        sec                         ; window, which is the mirror's row when the
        sbc wcy                     ; window starts on a multiple of 23
        cmp #BUFROWS
        bne :+
        ldx curbuf
        lda #1
        sta mirdty,x
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

; draw_tile: A = tile id, dst0 = where its chars go, dt_half = 0 for the tile's top
; char row and 32 for its bottom one, dt_s/dt_n = the first char of the tile to draw
; and how many.  Only the two edge tiles of a rectangle are ever partial, so the rest
; go through draw_tile_full, which skips the tests and the dt_rem bookkeeping.
draw_tile_full:
        tax
        lda BLANKT,x
        beq :+
        jmp dt_blankfill
:       txa
        jsr dt_setptr
        jmp dt_fullcopy
draw_tile:
        tax
        lda BLANKT,x                ; over half of a level's map is a tile with
        bne @blank                  ; nothing in it: fill, do not copy 32 zero bytes
        txa
        jsr dt_setptr
        lda dt_s
        bne @part
        lda dt_n
        cmp #4
        bne @part
        jmp dt_fullcopy
@part:  lda dt_n                    ; the edge tiles of a char-clipped rectangle: a
        bne :+                      ; run of dt_n chars starting dt_s chars in
        rts
:       asl
        asl
        asl
        tax
        lda dt_s
        asl
        asl
        asl
        tay
:       lda (tp),y
        sta (dst0),y
        iny
        dex
        bne :-
        rts
@blank: lda dt_s
        bne @bpart
        lda dt_n
        cmp #4
        bne @bpart
        jmp dt_blankfill
@bpart: lda dt_n
        bne :+
        rts
:       asl
        asl
        asl
        tax
        lda dt_s
        asl
        asl
        asl
        tay
        lda #0
:       sta (dst0),y
        iny
        dex
        bne :-
        rts

; dt_setptr: A = tile id -> tp = its bytes for this char row
dt_setptr:
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
        clc
        adc dt_half                 ; (id & 3)*64 + 32 is 224 at most: it cannot carry
        sta tp
        rts

dt_fullcopy:
        ldy #0                      ; unrolled: the dey/bpl per byte was a fifth of
        .repeat 32                  ; the cost of a tile
        lda (tp),y
        sta (dst0),y
        iny
        .endrepeat
        rts
dt_blankfill:
        lda #0                      ; a tile with nothing in it: 8 cycles a byte
        ldy #0
        .repeat 32
        sta (dst0),y
        iny
        .endrepeat
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
        .align 256
BLANKT: .incbin "build/tileblank.bin"   ; one byte a tile: non-zero = entirely black
BARIMG: .incbin "build/bar.bin"
