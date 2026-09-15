; ============================================================================
; Bank 7: the game logic, the frame loop, and the chain the CRTC is driven by.
; Bank 7 is the one the loader leaves paged in, so $8000 is the entry vector.
; ============================================================================
        .segment "LGCCODE"
entry:  jmp init

; ---------------------------------------------------------------- start up
init:
        ldx #$3F                    ; the stack is 64 bytes: $0100-$013F
        txs
        lda #0                      ; the OS left its own variables here; $F0-$FF is
        ldx #0                      ; left alone ($F4 is the bank the loader selected,
:       sta $00,x                   ; and the OS IRQ still restores from it until
        inx                         ; take_over).  Counting up: $EF is negative, so a
        cpx #$F0                    ; dex/bpl loop would stop after one store
        bne :-
        ; the main-RAM image travels in bank 7 and is copied down to $0140
        lda #<__LOWCODE_LOAD__
        sta w16
        lda #>__LOWCODE_LOAD__
        sta w16+1
        lda #<__LOWCODE_RUN__
        sta w16b
        lda #>__LOWCODE_RUN__
        sta w16b+1
        ldy #0
        ldx #>(__LOWCODE_SIZE__ + 255)
@lc:    lda (w16),y
        sta (w16b),y
        iny
        bne @lc
        inc w16+1
        inc w16b+1
        dex
        bne @lc
        jsr init_far
        jsr clear_screen
        lda #0
        sta curbuf
        jsr select_backbuf
        jsr draw_window
        jsr mirror_copy
        lda #1
        sta curbuf
        jsr select_backbuf
        jsr draw_window
        jsr mirror_copy
        jsr bar_pattern
        lda #0
        sta curbuf
        sta DISPSECT
        sta NEXTSECT
        sta SECIDX                  ; the chain starts at the bar; the first vsync
        sta wcx                     ; re-phases everything
        sta wcx+1
        sta wcy
        sta wfine
        sta frame
        lda #<VS2T_DEFAULT
        sta VS2T
        lda #>VS2T_DEFAULT
        sta VS2T+1
        jsr select_backbuf
        jsr calc_ring
        jsr build_sections          ; buffer 0's chain, before anything can display it
        jsr set_palette
        jsr crtc_init
        jsr take_over
        ; ---------------------------------------------------------------- loop
frame_top:
        inc frame
        .ifdef TESTY                ; a fixed window, so a screenshot can be checked
        lda #TESTY                  ; against the geometry it is meant to show
        sta wcy
        lda #TESTX
        sta wcx
        lda #0
        sta wcx+1
        lda #TESTF
        sta wfine
        .else
        lda frame                   ; walk the window: two frames a char row down,
        lsr                         ; and a char right every eight, which takes the
        sta wcy                     ; straddling row through every column
        lda frame
        lsr
        lsr
        lsr
        sta wcx
        lda #0
        sta wcx+1
        lda frame
        and #3
        asl
        sta wfine
        .endif
        jsr calc_ring
        jsr build_sections
        lda curbuf
        beq :+
        lda #48
:       sta NEXTSECT
        lda #1
        sta flipreq
:       lda flipreq
        bne :-
        lda curbuf
        eor #1
        sta curbuf
        jsr select_backbuf
        jmp frame_top

; ---------------------------------------------------------------- vsync
; Reached from the interrupt handler in main RAM, 64 lines before the bar.
vsync_tick:
        lda VS2T                    ; restart T1 first, for constant latency
        sta VIA_T1LL
        lda VS2T+1
        sta VIA_T1CH
        lda #$02
        sta VIA_IFR
        lda #9                      ; re-phase: end this frame curR7 + (QROWS-1-QVSYNC)
        sta CRTC_IDX                ; rows from the vsync, whatever the row counter did
        lda #7
        sta CRTC_DAT
        lda #6                      ; pre-arm the bar's R6 here in Q, where the display
        sta CRTC_IDX                ; is off and a new R6 cannot show
        lda #BARROWS
        sta CRTC_DAT
        lda #4
        sta CRTC_IDX
        lda curR7
        clc
        adc #QROWS-1-QVSYNC
        and #$7F
        sta CRTC_DAT
        inc vsyncs
        lda flipreq
        beq @noflip
        lda vsyncs
        sec
        sbc flipvs
        cmp #2
        bcc @noflip
        lda vsyncs
        sta flipvs
        lda NEXTSECT
        sta DISPSECT
        stz flipreq
@noflip:
        ldx #0                      ; section 0 is the bar: its address and length come
        ldy DISPSECT                ; from the buffer about to be displayed
        beq :+
        ldx #2
:       lda BUF_SEC0T1,x
        sta VIA_T1LL
        lda BUF_SEC0T1+1,x
        sta VIA_T1LH
        lda #12
        sta CRTC_IDX
        lda BUF_SEC0,x
        sta CRTC_DAT
        lda #13
        sta CRTC_IDX
        lda BUF_SEC0+1,x
        sta CRTC_DAT
        lda #$40
        sta VIA_IFR
        sty SECIDX
        rts

; the (bank, address) table the thunk in main RAM indexes
init_far:
        ldx #3*NFAR-1
:       lda @src,x
        sta FARTAB,x
        dex
        bpl :-
        rts
@src:   .byte BANK_LGC, <vsync_tick, >vsync_tick
        .byte BANK_LGC, <vsync_tick, >vsync_tick    ; F_SCANKEYS, not yet
        .byte BANK_LGC, <vsync_tick, >vsync_tick    ; F_SNDTICK, not yet
        .byte BANK_MAP, <map_strip, >map_strip
        .byte BANK_TIL, <draw_maprect, >draw_maprect
        .byte BANK_TIL, 0, 0
        .byte BANK_TIL, 0, 0
        .byte BANK_SPR, 0, 0
        .byte BANK_SPR, 0, 0
        .byte BANK_TIL, 0, 0
        .byte BANK_TIL, 0, 0
        .byte BANK_SPR, 0, 0

; ---------------------------------------------------------------- tables
; select_backbuf: point the ring tables, the fold and the CRTC base at curbuf
select_backbuf:
        lda curbuf
        beq @a
        lda #<RING_B
        sta ringbase
        lda #>RING_B
        sta ringbase+1
        lda #>RINGEND_B
        sta ringehi
        lda #<CRTCB_B
        sta crtcb
        lda #>CRTCB_B
        sta crtcb+1
        bra @tab
@a:     lda #<RING_A
        sta ringbase
        lda #>RING_A
        sta ringbase+1
        lda #>RINGEND_A
        sta ringehi
        lda #<CRTCB_A
        sta crtcb
        lda #>CRTCB_A
        sta crtcb+1
@tab:   lda crtcb                   ; the mirror redirect is the same add with the ring
        sec                         ; subtracted: crtcb - RINGCHARS
        sbc #<RINGCHARS
        sta crtcbm
        lda crtcb+1
        sbc #>RINGCHARS
        sta crtcbm+1
        lda ringbase
        sta w16
        lda ringbase+1
        sta w16+1
        ldx #0
@rt:    lda w16
        sta RINGLO,x
        lda w16+1
        sta RINGHI,x
        lda w16
        clc
        adc #<ROWBYTES
        sta w16
        lda w16+1
        adc #>ROWBYTES
        sta w16+1
        inx
        cpx #RINGROWS
        bne @rt
        rts

; calc_ring: ringS = ((wcy mod RINGROWS) * 80 + wcx) mod RINGCHARS ; barq = ringS / 80
calc_ring:
        ldx wcy
        lda RINGMODTAB,x
        tax
        lda mulrowlo,x
        clc
        adc wcx
        sta ringS
        lda mulrowhi,x
        adc wcx+1
        sta ringS+1
        cmp #>RINGCHARS
        bcc :++
        bne :+
        lda ringS
        cmp #<RINGCHARS
        bcc :++
:       lda ringS
        sec
        sbc #<RINGCHARS
        sta ringS
        lda ringS+1
        sbc #>RINGCHARS
        sta ringS+1
:       lda ringS                   ; q = S / 80 by repeated subtraction: 23 at most
        ldy ringS+1
        ldx #$FF
        sec
@div:   inx
        sbc #ROWCHARS
        bcs @div
        sec
        dey
        bpl @div
        stx barq
        rts

; ---------------------------------------------------------------- the chain
; entry i: R12n, R13n, R4, R9, R6, R7, T1lo, T1hi.  The shape is section i's; the
; address and duration are section i+1's, because R12/R13 latch at the next restart
; and the T1 latch takes effect one interrupt later.
build_sections:
        lda curbuf
        asl
        tax
        lda #>BARCRTC               ; section 0 is the bar: fixed address and length
        sta BUF_SEC0,x
        lda #<BARCRTC
        sta BUF_SEC0+1,x
        lda #<(BARROWS*8*LINE-2)
        sta BUF_SEC0T1,x
        lda #>(BARROWS*8*LINE-2)
        sta BUF_SEC0T1+1,x
        ldx curbuf
        beq :+
        ldx #48
:       lda #BARROWS-1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #BARROWS
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda wfine
        beq @coarse
        ; ---- f > 0: T -> A (the composed row) -> P.. -> P2 -> Q
        eor #7
        inca                        ; 8-f lines of it
        jsr @dur
        sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        lda ringS                   ; the composed row is the 80 chars above the window
        sec
        sbc #<ROWCHARS
        sta w16
        lda ringS+1
        sbc #0
        sta w16+1
        bpl :+
        lda w16
        clc
        adc #<RINGCHARS
        sta w16
        lda w16+1
        adc #>RINGCHARS
        sta w16+1
:       jsr @addr
        txa
        clc
        adc #8
        tax                         ; A's entry
        stz SECTAB+2,x
        lda wfine
        eor #7                      ; 7 - f
        sta SECTAB+3,x
        lda #2
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda ringS                   ; the run starts one row into the window
        clc
        adc #<ROWCHARS
        sta w16
        lda ringS+1
        adc #0
        sta w16+1
        jsr @wrap
        lda #VISROWS-1
        sta tmp4                    ; rows in the run
        ldy barq
        iny
        cpy #RINGROWS
        bcc :+
        ldy #0
:       sty tmp3
        bra @run
@coarse:                            ; ---- f = 0: T -> P.. -> Q
        lda ringS
        sta w16
        lda ringS+1
        sta w16+1
        lda #VISROWS
        sta tmp4
        lda barq
        sta tmp3
@run:   ; w16 = the run's ring offset, tmp4 = its rows, X = the entry before it
        jsr @nfull                  ; rows that end before the ring end
        cmp tmp4
        bcs @one                    ; the whole run fits
        cmp #0
        beq @one                    ; it starts inside the straddling row: all of it folds
        sta tmp2
        jsr @emit                   ; up to the ring end
        lda tmp2
        jsr @advance
        lda tmp4
        sec
        sbc tmp2
        sta tmp4
@one:   lda tmp4
        sta tmp2
        jsr @emit
        lda tmp4
        jsr @advance                ; now the row below the playfield
        lda wfine
        beq @setq
        ; --- P2: the top f lines of that row
        jsr @addr
        lda wfine
        jsr @dur
        sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax
        stza SECTAB+2, x
        lda wfine
        deca
        sta SECTAB+3,x
        lda #VISROWS
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda SECTAB-8,x              ; w16 has not moved: the address the P2 @addr left
        sta SECTAB,x                ; in the previous entry is this one's too
        lda SECTAB-8+1,x
        sta SECTAB+1,x
        bra @sq2
@setq:  jsr @addr                   ; Q starts on the row below the playfield
@sq2:   lda #<(40*LINE-2)
        sta SECTAB+6,x
        lda #>(40*LINE-2)
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax
        lda #>BARCRTC               ; and hands the chain back to the bar
        sta SECTAB,x
        lda #<BARCRTC
        sta SECTAB+1,x
        lda #QROWS-1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        stza SECTAB+4, x
        lda #QVSYNC
        sta SECTAB+5, x
        lda #<(40*LINE-2)
        sta SECTAB+6, x
        lda #>(40*LINE-2)
        sta SECTAB+7, x
        rts
; --- emit a run of tmp2 rows starting at ring offset w16, following entry X
@emit:  jsr @addr
        lda tmp2
        jsr @lines
        sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax
        lda tmp2
        deca
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #30
        sta SECTAB+4,x
        sta SECTAB+5,x
        rts
; --- SECTAB+0/1,x = the CRTC address of the row at ring offset w16.  A row starting
; past RINGCHARS-80 straddles the ring end and is read from the mirror below the base,
; which is exactly the address w16 - RINGCHARS names.
@addr:  lda w16
        ldy w16+1
        cpy #>(RINGCHARS-ROWCHARS+1)
        bcc :++
        bne :+
        cmp #<(RINGCHARS-ROWCHARS+1)
        bcc :++
:       clc
        adc crtcbm
        sta SECTAB+1,x
        tya
        adc crtcbm+1
        sta SECTAB,x
        rts
:       clc
        adc crtcb
        sta SECTAB+1,x
        tya
        adc crtcb+1
        sta SECTAB,x
        rts
        ; --- A = rows -> A/tmp3 = that many rows of lines, as a T1 count
@lines: asl
        asl
        asl
        jmp @dur
        ; --- A = rows: advance w16 by that many rows, folding into 0..RINGCHARS
@advance:
        tay
        clc
        lda w16
        adc mulrowlo,y
        sta w16
        lda w16+1
        adc mulrowhi,y
        sta w16+1
@wrap:  lda w16+1
        cmp #>RINGCHARS
        bcc :++
        bne :+
        lda w16
        cmp #<RINGCHARS
        bcc :++
:       lda w16
        sec
        sbc #<RINGCHARS
        sta w16
        lda w16+1
        sbc #>RINGCHARS
        sta w16+1
:       rts
        ; --- rows of the run that finish before the ring end.  The run starts on ring
        ; row tmp3; when r = ringS mod 80 is non-zero the last ring row straddles and
        ; @addr sends it to the mirror, so RINGROWS-1-tmp3 rows come first.
@nfull: ldy barq
        lda ringS
        sec
        sbc mulrowlo,y              ; r
        cmp #1                      ; C = 1 iff r > 0
        lda #RINGROWS-1
        bcs :+
        adc #0                      ; r == 0: C is clear here, so this adds 1
        adc #1
:       sec
        sbc tmp3
        rts
        ; --- A = lines -> A/tmp3 = the T1 count that lasts that long
@dur:   sta tmp3                    ; n*64 == (n*256)>>2
        lda #0
        lsr tmp3
        ror
        lsr tmp3
        ror
        sbc #1                      ; C = 0 out of the ror pair: A - 2
        bcs :+
        dec tmp3
:       rts

; ---------------------------------------------------------------- display
set_palette:                        ; MODE 1: logical 0..3 = black, cyan, magenta, yellow
        ldx #15                     ; a pixel's two bits land in index bits 3 and 1
:       txa
        and #8
        lsr
        lsr
        sta tmp
        txa
        and #2
        lsr
        ora tmp
        tay
        lda @cmyk,y
        sta tmp
        txa
        asl
        asl
        asl
        asl
        ora tmp
        sta ULA_PAL
        dex
        bpl :-
        rts
@cmyk:  .byte 0^7, 6^7, 5^7, 3^7    ; physical black, cyan, magenta, yellow, inverted

crtc_init:                          ; start the chain at the bar and let vsync re-phase
        ldx #9
        lda #7
        jsr @w
        ldx #4
        lda #BARROWS-1
        jsr @w
        ldx #6
        lda #BARROWS
        jsr @w
        ldx #7
        lda #30
        jsr @w
        ldx #12
        lda #>BARCRTC
        jsr @w
        ldx #13
        lda #<BARCRTC
@w:     stx CRTC_IDX
        sta CRTC_DAT
        rts

take_over:
        sei
        lda #<irq_handler
        sta IRQ1V
        lda #>irq_handler
        sta IRQ1V+1
        lda #$7F
        sta VIA_IER
        sta UVIA_IER
        lda VIA_ACR
        and #$3F
        ora #$40                    ; T1 continuous
        sta VIA_ACR
        lda #<(40*LINE)
        sta VIA_T1LL
        lda #>(40*LINE)
        sta VIA_T1CH
        lda #$C2                    ; CA1 (vsync) + T1
        sta VIA_IER
        lda #$7F
        sta VIA_IFR
        lda #30                     ; the chain stops when curR7 is Q's; start it at a
        sta curR7                   ; value that is not
        stz flipreq
        stz vsyncs
        stz flipvs
        cli
        rts

; ---------------------------------------------------------------- scaffolding
clear_screen:                       ; $0300-$7FFF: the bar, both mirrors and both rings
        lda #0
        sta w16
        lda #>BARADDR
        sta w16+1
        ldy #0
        ldx #$7D                    ; pages $03..$7F
:       sta (w16),y
        iny
        bne :-
        inc w16+1
        dex
        bne :-
        rts

; the whole window: 20 tiles across, 11 tile rows (22 char rows)
draw_window:
        lda wcx                     ; a tile is four chars and two char rows
        lsr
        lsr
        sta dt_tx
        lda wcy
        lsr
        sta dt_ty
        lda #20
        sta dt_nx
        lda #11
        sta dt_ny
        farjsr F_DRAWRECT
        rts

; A pattern that makes the geometry readable: each ring row is a band of one colour
; with its slot number written as a run of black chars at the left, so the order of
; the rows on screen, the wrap and the mirror can all be counted off.
test_pattern:
        ldx #0                      ; slot
@slot:  stx tmp2
        txa
        clc
        adc #1
        sta tmp                     ; colour 1..3 by slot
@c1:    cmp #4
        bcc :+
        sbc #3
        bra @c1
:       tay
        lda @cols,y
        sta tmp3                    ; the band's byte
        ldx tmp2
        lda RINGLO,x
        sta w16
        lda RINGHI,x
        sta w16+1
        ldy #0
        lda #0
        sta cnt                     ; char within the row
@char:  lda cnt
        cmp tmp2                    ; the first (slot+1) chars are black
        bcc @black
        beq @black
        lda tmp3
        bra @put
@black: lda #0
@put:   ldx #8
@st:    sta (w16),y
        iny
        bne :+
        inc w16+1
:       dex
        bne @st
        inc cnt
        lda cnt
        cmp #ROWCHARS
        bne @char
        ldx tmp2
        inx
        cpx #RINGROWS
        bne @slot
        rts
@cols:  .byte $00, $0F, $F0, $FF

bar_pattern:                        ; yellow with a black tick every eight chars
        lda #<BARADDR
        sta w16
        lda #>BARADDR
        sta w16+1
        ldy #0
        ldx #0
@b:     tya
        and #$38
        cmp #$38
        bne :+
        lda #0
        bra :++
:       lda #$FF
:       sta (w16),y
        iny
        bne @b
        inc w16+1
        inx
        cpx #5
        bne @b
        rts

; the mirror is a copy of the ring's last row, so a straddling row reads as one run
mirror_copy:
        ldx #RINGROWS-1
        lda RINGLO,x
        sta w16
        lda RINGHI,x
        sta w16+1
        lda ringbase
        sec
        sbc #<ROWBYTES
        sta w16b
        lda ringbase+1
        sbc #>ROWBYTES
        sta w16b+1
        ldy #0
        ldx #>ROWBYTES
:       lda (w16),y
        sta (w16b),y
        iny
        bne :-
        inc w16+1
        inc w16b+1
        dex
        bne :-
        ldx #<ROWBYTES              ; the odd half page
:       lda (w16),y
        sta (w16b),y
        iny
        dex
        bne :-
        rts

        .include "tables.inc"

        .segment "LGCBSS"
