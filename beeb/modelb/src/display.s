; ============================================================================
; The Model B's display driver: bank 7, with the logic.  The rupture chain the CRTC is driven by,
; the mirror the straddling row is read from, and the interrupt's work.  The Master
; needs none of this -- its ring is hardware wrapped -- so it is the one part of the
; renderer that is this target's own (DESIGN.md, "the display").
; ============================================================================
        .segment "LGCCODE"

; ---------------------------------------------------------------- the interrupt
; Reached from the stub in low RAM with this bank paged in and X, Y saved.
isr_body:
        bit VIA_IFR
        bvs @t1
        lda VIA_IFR
        and #$02
        beq @exit
        jmp vsync_tick
@t1:    ; A rupture step is a CRTC restart: R12/R13 were armed during the section
        ; before and latch at the boundary; R9 with R4 decide where the section ends
        ; and are compared at the start of its last scanline, and R6 from scanline 1
        ; on.  The chain is phased so the step fires ~60 cycles BEFORE the restart;
        ; the stub's bank switch carries the first write past it.
        ldx SECIDX
        lda #9
        sta CRTC_IDX
        lda SECTAB+3,x
        sta CRTC_DAT
        lda #4
        sta CRTC_IDX
        lda SECTAB+2,x
        sta CRTC_DAT
        lda #6
        sta CRTC_IDX
        ldy SECTAB+4,x
        sty CRTC_DAT
        lda #7
        sta CRTC_IDX
        lda SECTAB+5,x
        sta CRTC_DAT
        sta curR7                   ; the vsync handler re-phases the frame from this
        lda #12
        sta CRTC_IDX
        lda SECTAB,x
        sta CRTC_DAT
        lda #13
        sta CRTC_IDX
        lda SECTAB+1,x
        sta CRTC_DAT
        lda SECTAB+6,x
        sta VIA_T1LL
        lda SECTAB+7,x
        sta VIA_T1LH
        lda VIA_T1CL                ; clear the T1 flag
        lda curR7                   ; the chain stops at Q, the only section whose R7
        cmp #QVSYNC                 ; is the vsync row: a late vsync must not walk it
        beq @exit                   ; off the end of SECTAB
        txa
        clc
        adc #8
        sta SECIDX
@exit:  rts

; ---- vsync: restart T1 first (constant latency), counter = vsync -> the bar
vsync_tick:
        lda VS2T
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
        jsr scan_keys               ; the keyboard and the sound are the interrupt's,
        jmp sound_tick              ; as they are on the Master

; ---------------------------------------------------------------- the chain
; build_sections: fill SECTAB for the current buffer from ringS and wfine.
; entry i: R12n, R13n, R4, R9, R6, R7, T1lo, T1hi.  The shape is section i's; the
; address and duration are section i+1's, because R12/R13 latch at the next restart
; and the T1 latch takes effect one interrupt later.
;
;   T   bar          2 rows at $0300
;   A   composed row 8-f lines, the fine scroll                (only when f > 0)
;   P1  playfield    from the window's slot to the ring's end
;   M   playfield    the rest, from the mirror
;   P2  bottom       f lines                                   (only when f > 0)
;   Q   blanking     16 rows, vsync at row 8
;
; A row starting past RINGCHARS-80 straddles the ring end and is read from the mirror
; sitting immediately below the ring base, which is exactly the address c - RINGCHARS
; names; every row after it follows on contiguously.
build_sections:
        ldx curbuf                  ; the buffer's CRTC base, and the mirror redirect:
        lda @cbl,x                  ; the same add with the ring subtracted
        sta crtcb
        lda @cbh,x
        sta crtcb+1
        lda @cml,x
        sta crtcbm
        lda @cmh,x
        sta crtcbm+1
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
@cbl:   .byte <CRTCB_A, <CRTCB_B
@cbh:   .byte >CRTCB_A, >CRTCB_B
@cml:   .byte <(CRTCB_A-RINGCHARS), <(CRTCB_B-RINGCHARS)
@cmh:   .byte >(CRTCB_A-RINGCHARS), >(CRTCB_B-RINGCHARS)
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

; ---------------------------------------------------------------- the mirror
        .segment "TILCODE"          ; bank 5: render_core's last step
; A copy of the ring's last slot row sits immediately below the ring base, so the
; one displayed row that straddles the ring end can be read as a single run.  Only
; the chars that row takes from it -- wcxm..79 -- need to be right, and when the
; window is slot aligned no row straddles at all.  It is made only when its row
; has been written: the blitters note the range (mirdirty, bank 5).
mirror_copy:
        ldx curbuf
        lda wcxm
        cmp mirwcx,x                ; a move left uncovers chars the last copy never
        bcs :+                      ; reached, so the whole row has to be made again
        lda #1
        sta mirdty,x
        lda #0
        sta mirlo,x
        lda #ROWCHARS-1
        sta mirhi,x
:       lda mirdty,x                ; nothing has touched the ring's last row in this
        bne :+                      ; buffer since the mirror was last made
        rts
:       lda wcxm
        bne :+                      ; slot aligned: no row straddles, so the mirror is
        rts                         ; not read -- and the flag stays up for when it is
:       lda #0
        sta mirdty,x
        lda mirlo,x                 ; the copy starts at the first written char, or at
        cmp wcxm                    ; wcxm if the writing started left of it
        bcs :+
        lda wcxm
:       sta tmp4                    ; and runs to the last written one
        lda mirhi,x
        sta tmp3
        lda #$FF                    ; the written range is empty again
        sta mirlo,x
        lda #0
        sta mirhi,x
        lda wcxm                    ; the chars left of wcxm are not copied
        sta mirwcx,x
        lda tmp3                    ; the chars from the first written to the last
        sec
        sbc tmp4
        bcs :+                      ; nothing of it is in the window
        rts
:       clc
        adc #1
        sta tmp
        ; source: the last slot, base + (RINGROWS-1)*640 + tmp4*8; the mirror is one
        ; whole ring below it
        lda tmp4
        sta w16
        lda #0
        sta w16+1
        asl w16
        rol w16+1
        asl w16
        rol w16+1
        asl w16
        rol w16+1
        lda w16
        clc
        adc #<(RING_A + (RINGROWS-1)*ROWBYTES)
        sta w16
        lda w16+1
        adc ringbhi
        adc #>((RINGROWS-1)*ROWBYTES)
        sta w16+1
        lda w16
        sec
        sbc #<RINGBYTES
        sta w16b
        lda w16+1
        sbc #>RINGBYTES
        sta w16b+1
        ldy #0
@c:     .repeat 8
        lda (w16),y
        sta (w16b),y
        iny
        .endrepeat
        bne :+
        inc w16+1
        inc w16b+1
:       dec tmp
        bne @c
        rts

; ---------------------------------------------------------------- the CRTC
        .segment "LGCLO"
crtc_init:                          ; start the chain at the bar and let vsync re-phase
        ldx #10
        lda #$20                    ; the MOS's cursor off
        jsr @w
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

        .segment "LGCBSS"
crtcb:    .res 2                    ; the buffer being built: its CRTC base, and the
crtcbm:   .res 2                    ; mirror redirect (base - RINGCHARS)
