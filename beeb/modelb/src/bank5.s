; ============================================================================
; Bank 5: this level's tiles and the blitter that draws them.  A tile is 8 game
; pixels square: 4 chars wide and 2 char rows tall, 64 bytes, and 1840 (the ring
; in chars) divides by 4, so a tile's four chars are always contiguous -- only
; whole tiles can straddle the ring end, never their columns.
; ============================================================================
        .segment "TILCODE"

.macro SETPTR2                      ; X = tile id -> tp = its top char row, tp2 its
        lda TILELO,x                ; bottom one
        sta tp
        clc
        adc #32
        sta tp2
        lda TILEHI,x
        sta tp+1
        sta tp2+1
.endmacro
.macro SETY                         ; Y = dt_s chars in, X = dt_n, Z = nothing to draw
        lda dt_s
        asl
        asl
        asl
        tay
        ldx dt_n
.endmacro
.macro SPAN                         ; how many of this tile's chars are wanted, and
        lda #4                      ; what is left of the rectangle after them
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
.endmacro

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
:       lda dt_cy                   ; does it write the window's top row, which the
        cmp wcy                     ; composed row above it is made from?
        bne :+
        lda dt_cx
        sec
        sbc wcx
        pha
        clc
        adc dt_ncx
        tax
        dex
        pla
        jsr part5                   ; (in this bank: main RAM has no room for another
:       lda mrow                    ;  shared routine, and the variables are in it)                    ; does it write the row the mirror follows?
        sec
        sbc dt_cy
        bcc :+
        cmp dt_ncy
        bcs :+
        lda dt_cx                   ; then the mirror needs these chars of it again
        clc
        adc dt_ncx
        tax
        dex
        lda dt_cx
        jsr mirdirty
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
        stz dt_mbase
        lda dt_cy                   ; tile rows the rectangle spans
        and #1
        clc
        adc dt_ncy
        clc
        adc #1
        lsr
        sta tmp3                    ; nt * rows tiles in all: one far call if they fit
        tax
        lda #0
:       clc
        adc dt_nt
        cmp #41
        bcs @perrow
        dex
        bne :-
        lda dt_cy                   ; they fit: fetch the lot, rows contiguous
        lsr
        sta tmp2
        lda dt_t0
        sta tmp
        lda dt_nt
        sta cnt
        farjsr F_MAPRECT
        lda #$FE
        sta dt_lastty               ; "MAPBUF holds the whole rectangle"
@perrow:
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

; part5: A = the first window column of the top row written, X = the last.  The
; composed row above the window is made from that row, so only these columns of it
; need making again.  The same few lines live in bank 4 for the sprite blitter: the
; variables are in main RAM, and main RAM has no room for the code.
part5:  cmp #ROWCHARS
        bcs @pout
        pha
        cpx #ROWCHARS
        bcc :+
        ldx #ROWCHARS-1
:       ldy curbuf
        pla
        cmp partlo,y
        bcs :+
        sta partlo,y
:       txa
        cmp parthi,y
        bcc :+
        sta parthi,y
:       rts
@pout:  rts

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

dm_row: lda dt_lastty
        cmp #$FE                    ; the whole rectangle is already in MAPBUF
        beq @haverow
        lda dt_cy                   ; the map strip is per tile row, so the second
        lsr                         ; char row of a pair reuses it
        cmp dt_lastty
        beq @haverow
        sta dt_lastty
        sta tmp2
        lda dt_t0
        sta tmp
        lda dt_nt
        sta cnt
        farjsr F_MAPSTRIP           ; (this is why w16 is set up below it, not above)
@haverow:
        lda dst1                    ; the row's first char
        sta dst0
        lda dst1+1
        sta dst0+1
        lda dt_ncx
        sta dt_rem
        lda dt_ls
        sta dt_s                    ; only the first tile starts part way in
        lda dt_mbase                ; the strip for this tile row
        sta dt_i
        clc
        adc dt_nt
        sta dt_ilim
        lda dt_cy
        and #1                      ; the bottom char row of a tile row on its own
        bne @to1
        lda dt_ncy                  ; the top one on its own, at the rectangle's end
        cmp #2
        bcs :+
@to1:   jmp @one                    ; the two-row chain is between here and there
:
        ; ---- both char rows of this tile row, which share everything but the store
        lda dst0                    ; w16 = the char row below dst0
        clc
        adc #<ROWBYTES
        sta w16
        lda dst0+1
        adc #>ROWBYTES
        cmp ringehi
        bcc :+
        pha
        lda w16
        sec
        sbc #<RINGBYTES
        sta w16
        pla
        sbc #>RINGBYTES
:       sta w16+1
@t2:    lda dt_s                    ; a whole tile, which is every tile but the two
        bne @edge2                  ; at the ends of the rectangle
        lda dt_rem
        cmp #4
        bcc @edge2
        sbc #4
        sta dt_rem
        ldx dt_i
        lda MAPBUF,x
        jsr draw_tile2_full
        bra @adv2
@edge2: SPAN
        ldx dt_i
        lda MAPBUF,x
        jsr draw_tile2
@adv2:  stz dt_s
        lda dst0                    ; the next tile is four chars on in both rows
        clc
        adc #32
        sta dst0
        bcc :+
        inc dst0+1
        jsr fold0
:       lda w16
        clc
        adc #32
        sta w16
        bcc :+
        inc w16+1
        lda w16+1
        cmp ringehi
        bcc :+
        lda w16
        sec
        sbc #<RINGBYTES
        sta w16
        lda w16+1
        sbc #>RINGBYTES
        sta w16+1
:       inc dt_i
        lda dt_i
        cmp dt_ilim
        bne @t2
        jsr dt_nextstrip
        inc dt_cy
        inc dt_cy
        dec dt_ncy
        dec dt_ncy
        bne :+
        rts
:
        lda dst1                    ; two char rows on: 1280 crosses the ring end at
        clc                         ; most once
        adc #<(2*ROWBYTES)
        sta dst1
        lda dst1+1
        adc #>(2*ROWBYTES)
        bra @nextrow
        ; ---- one char row: the tile's top half or its bottom half
@one:   lda dt_cy
        and #1
        beq :+
        lda #32
:       sta dt_half
@t1:    lda dt_s
        bne @edge1
        lda dt_rem
        cmp #4
        bcc @edge1
        sbc #4
        sta dt_rem
        ldx dt_i
        lda MAPBUF,x
        jsr draw_tile_full
        bra @adv1
@edge1: SPAN
        ldx dt_i
        lda MAPBUF,x
        jsr draw_tile
@adv1:  stz dt_s
        lda dst0
        clc
        adc #32
        sta dst0
        bcc :+
        inc dst0+1
        jsr fold0
:       inc dt_i
        lda dt_i
        cmp dt_ilim
        bne @t1
        lda dt_cy                   ; a bottom half finishes its tile row
        and #1
        beq :+
        jsr dt_nextstrip
:       inc dt_cy
        dec dt_ncy
        beq dm_done
        lda dst1                    ; the next char row is one row of bytes on
        clc
        adc #<ROWBYTES
        sta dst1
        lda dst1+1
        adc #>ROWBYTES
@nextrow:
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
dm_done:
        rts

; dt_nextstrip: the next tile row's strip, when MAPBUF holds the whole rectangle
dt_nextstrip:
        lda dt_lastty
        cmp #$FE
        bne :+
        lda dt_mbase
        clc
        adc dt_nt
        sta dt_mbase
:       rts

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
:       ldx curbuf                  ; the whole row when the fine offset has changed:
        cmp partfine,x              ; every column of it shows different scanlines then
        beq :+
        sta partfine,x
        lda #0
        sta partlo,x
        lda #ROWCHARS-1
        sta parthi,x
        lda wfine
:       ldx curbuf
        lda partlo,x                ; nothing has been written: the row still stands
        cmp parthi,x
        bcc :+
        beq :+
        rts
:       lda mrow                    ; the composed row is the ring row above the
        sec                         ; window, which is the mirror's row when the
        sbc wcy                     ; window starts on a multiple of 23
        cmp #BUFROWS
        bne :+
        ldx #ROWCHARS-1             ; and it writes all 80 chars of it
        lda #0
        jsr mirdirty
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
;
; The copy is one unrolled chain of 32 `lda (tp),y / sta (dst0),y / iny', labelled
; every 8 bytes: the y value comes from the register, so entering at the block for
; dt_n chars and running to the end copies exactly dt_n chars from wherever y starts.
; A partial run therefore costs the same 13 cycles a byte as a whole tile.
draw_tile_full:
        tax
        lda BLANKT,x
        bne @blank
        lda TILELO,x                ; the tile's bytes for this char row, from a table:
        ora dt_half                 ; id*64 is 64-aligned, so the half never carries
        sta tp
        lda TILEHI,x
        sta tp+1
        ldy #0
        jmp dt_cp4
@blank: ldy #0
        lda #0
        jmp dt_bl4
draw_tile:
        tax
        lda BLANKT,x                ; over half of a level's map is a tile with
        bne @blank                  ; nothing in it: fill, do not copy 32 zero bytes
        lda TILELO,x
        ora dt_half
        sta tp
        lda TILEHI,x
        sta tp+1
        SETY                        ; y = the first char wanted, X = how many
        beq @none
        cpx #4
        bne :+
        jmp dt_cp4
:       cpx #3
        bne :+
        jmp dt_cp3
:       cpx #2
        bne :+
        jmp dt_cp2
:       jmp dt_cp1
@none:  rts
@blank: SETY
        beq @none
        lda #0                      ; the fill chain is past the copy chain, so these
        cpx #4                      ; are out of branch range
        bne :+
        jmp dt_bl4
:       cpx #3
        bne :+
        jmp dt_bl3
:       cpx #2
        bne :+
        jmp dt_bl2
:       jmp dt_bl1

; draw_tile2 / draw_tile2_full: both char rows of a tile row at once, the top at dst0
; and the bottom at w16.  A tile row is two char rows of the same tile, so the map
; byte, the tile pointer and the rectangle's bookkeeping are all shared -- which is
; most of the cost of a narrow rectangle.
draw_tile2_full:
        tax
        lda BLANKT,x
        bne @blank
        SETPTR2
        ldy #0
        jmp dt_2cp4
@blank: ldy #0
        lda #0
        jmp dt_2bl4
draw_tile2:
        tax
        lda BLANKT,x
        bne @blank
        SETPTR2
        SETY
        beq @none
        cpx #4
        bne :+
        jmp dt_2cp4
:       cpx #3
        bne :+
        jmp dt_2cp3
:       cpx #2
        bne :+
        jmp dt_2cp2
:       jmp dt_2cp1
@none:  rts
@blank: SETY
        beq @none
        lda #0
        cpx #4
        bne :+
        jmp dt_2bl4
:       cpx #3
        bne :+
        jmp dt_2bl3
:       cpx #2
        bne :+
        jmp dt_2bl2
:       jmp dt_2bl1

dt_2cp4: .repeat 8
        lda (tp),y
        sta (dst0),y
        lda (tp2),y
        sta (w16),y
        iny
        .endrepeat
dt_2cp3: .repeat 8
        lda (tp),y
        sta (dst0),y
        lda (tp2),y
        sta (w16),y
        iny
        .endrepeat
dt_2cp2: .repeat 8
        lda (tp),y
        sta (dst0),y
        lda (tp2),y
        sta (w16),y
        iny
        .endrepeat
dt_2cp1: .repeat 8
        lda (tp),y
        sta (dst0),y
        lda (tp2),y
        sta (w16),y
        iny
        .endrepeat
        rts

dt_2bl4: .repeat 8
        sta (dst0),y
        sta (w16),y
        iny
        .endrepeat
dt_2bl3: .repeat 8
        sta (dst0),y
        sta (w16),y
        iny
        .endrepeat
dt_2bl2: .repeat 8
        sta (dst0),y
        sta (w16),y
        iny
        .endrepeat
dt_2bl1: .repeat 8
        sta (dst0),y
        sta (w16),y
        iny
        .endrepeat
        rts

dt_cp4: .repeat 8
        lda (tp),y
        sta (dst0),y
        iny
        .endrepeat
dt_cp3: .repeat 8
        lda (tp),y
        sta (dst0),y
        iny
        .endrepeat
dt_cp2: .repeat 8
        lda (tp),y
        sta (dst0),y
        iny
        .endrepeat
dt_cp1: .repeat 8
        lda (tp),y
        sta (dst0),y
        iny
        .endrepeat
        rts

dt_bl4: .repeat 8                   ; a tile with nothing in it: 8 cycles a byte
        sta (dst0),y
        iny
        .endrepeat
dt_bl3: .repeat 8
        sta (dst0),y
        iny
        .endrepeat
dt_bl2: .repeat 8
        sta (dst0),y
        iny
        .endrepeat
dt_bl1: .repeat 8
        sta (dst0),y
        iny
        .endrepeat
        rts

; tile_init: the tile address tables, built once from where the linker put TILES
tile_init:
        ldx #0
:       txa
        lsr
        lsr
        clc
        adc #>TILES                 ; id*64 is (id >> 2) pages plus (id & 3) * 64,
        sta TILEHI,x                ; and TILES is page aligned
        txa
        and #3
        asl
        asl
        asl
        asl
        asl
        asl
        sta TILELO,x
        inx
        cpx #128
        bne :-
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
TILELO: .res 128                    ; tile id -> the address of its bytes, built by
TILEHI: .res 128                    ; tile_init
TILES:  .incbin "build/tiles.bin"
        .align 256
BLANKT: .incbin "build/tileblank.bin"   ; one byte a tile: non-zero = entirely black
BARIMG: .incbin "build/bar.bin"
