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
        lda VIA_IFR                 ; T1 only when its interrupt is enabled: a load turns
        and VIA_IER                 ; it off (@ldsw) and T1 runs on, so its flag can be
        asl                         ; set at the vsync that arms it again
        bmi @t1
        lda VIA_IFR
        and #$02
        beq @exit
        jmp vsync_tick
@t1:    ; A rupture step is a CRTC restart: R12/R13 were armed during the section
        ; before and latch at the boundary; R9 with R4 decide where the section ends
        ; and are compared at the start of its last scanline, and R6 from scanline 1
        ; on.  The chain is phased so the step fires ~60 cycles BEFORE the restart;
        ; the stub's bank switch carries the first write past it.
        lda LOADREQ
        bne @ldsw                   ; a load has asked for the chain to stop
@chain: ldx SECIDX
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
        lda SECTAB+6,x
        sta VIA_T1LL
        lda SECTAB+7,x
        sta VIA_T1LH
        lda VIA_T1CL                ; clear the T1 flag
        lda curR7                   ; the chain stops at Q, the only section whose R7
        cmp #QVSYNC                 ; is the vsync row: a late vsync must not walk it
        beq :+                      ; off the end of SECTAB
        txa
        clc
        adc #8
        sta SECIDX                  ; (X still indexes this entry for R12/R13 below)
:       lda #12                     ; the next section's address LAST, so it lands on
        sta CRTC_IDX                ; scanline 1: written straight after R7 it fell
        lda SECTAB,x                ; across the end of scanline 0, where a 6845 that
        sta CRTC_DAT                ; ends a partial (R4 = 0 on row 0) at once -- the
        lda #13                     ; VL6845 -- reloads its start address and lost the
        sta CRTC_IDX                ; R12 write (engine.s @t1arm has the story)
        lda SECTAB+1,x
        sta CRTC_DAT
@exit:  rts
@ldsw:  ldx SECIDX                  ; only the bar step, a frame boundary, makes the switch
        cpx DISPSECT                ; (engine.s load_begin has the story)
        beq @sw
        jmp @chain
@sw:    lda #4                      ; this restart is a standard frame, not the bar (R9
        sta CRTC_IDX                ; and R6 are the vsync's pre-arm, R12/R13 the bar's)
        lda #LDR4
        sta CRTC_DAT
        lda #7
        sta CRTC_IDX
        lda #LDR7
        sta CRTC_DAT
        sta curR7                   ; the first vsync after the load re-phases from this
        lda #$40
        sta VIA_IER                 ; T1's interrupt off: the chain is stopped
        lda VIA_T1CL
        lda #2
        sta LOADREQ
        rts

; ---- vsync: restart T1 first (constant latency), counter = vsync -> the bar
vsync_tick:
        lda VS2T
        sta VIA_T1LL
        lda VS2T+1
        sta VIA_T1CH                ; (clears T1's flag)
        lda #$02
        sta VIA_IFR
        lda LOADREQ                 ; (after the restart: it sets the chain's phase)
        cmp #2
        bne @vsrun
        jmp @ldvsync                ; stopped for a load: T1 stays off
@vsrun: cmp #3
        bne @vson
        lda #0
        sta LOADREQ                 ; resume: T1's interrupt on again, below
@vson:  lda #$C0
        sta VIA_IER
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
        ldx #0                      ; X = 0: the bar's pair below, and flipreq's clear
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
        stx flipreq
@noflip:
        ldy DISPSECT                ; section 0 is the bar: its address and length come
        beq :+                      ; from the buffer about to be displayed
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
@tail:  jsr scan_keys               ; the keyboard and the sound are the interrupt's,
        jmp sound_tick              ; as they are on the Master
@ldvsync:                           ; stopped: the standard frame free-runs; count the
        inc vsyncs                  ; vsync and keep the keys and the sound alive
        jmp @tail


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
        txa                         ; X = curbuf still (ldx curbuf above)
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
        txa                         ; Z from X = curbuf*2
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
        lda ringS                   ; the composed row is the 80 chars above the window
        sec
        sbc #<ROWCHARS
        sta w16
        lda ringS+1
        sbc #0
        bpl :+                      ; negative: C = 0 (the borrow), A = $FF
        lda w16                     ; + RINGCHARS
        adc #<RINGCHARS
        sta w16
        lda #>(RINGCHARS-$100)      ; $FF + >RINGCHARS + C
        adc #0
:       sta w16+1
        jsr @addr
        lda wfine
        eor #7                      ; 7 - f: A's R9
        sta SECTAB+8+3,x
        clc
        adc #1                      ; 8-f lines of it
        jsr @dur                    ; X = A's entry
        stz SECTAB+2,x
        lda #2
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda ringS                   ; the run starts one row into the window (C = 0: @dur's adc #8)
        adc #<ROWCHARS
        sta w16
        lda ringS+1
        adc #0
        sta w16+1
        jsr @wrap
        ldy barq
        iny
        cpy #RINGROWS
        bcc :+
        ldy #0
:       sty tmp3
        lda #VISROWS-1
        sta tmp4                    ; rows in the run
        bne @run                    ; always: A = VISROWS-1
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
        ; rows of the run that end before the ring end (was @nfull): the run starts on
        ; ring row tmp3; r = ringS mod 80 non-zero -> the last ring row straddles
        ldy barq
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
        cmp tmp4
        bcs @one                    ; the whole run fits
        tay                         ; Z from A (Y is dead: @emit's @addr reloads it)
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
        jsr @addr                   ; the row below the playfield: P2's start, or Q's
        lda wfine
        beq @sq2
        ; --- P2: the top f lines of that row (A = wfine)
        jsr @dur                    ; X = P2's entry
        stz SECTAB+2,x              ; A dead: reloaded next
        lda wfine
        sbc #0                      ; C = 0 from @dur's adc #8: f - 1
        sta SECTAB+3,x
        lda #VISROWS
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda SECTAB-8,x              ; w16 has not moved: the address the P2 @addr left
        sta SECTAB,x                ; in the previous entry is this one's too
        lda SECTAB-8+1,x
        sta SECTAB+1,x
@sq2:   txa
        clc
        adc #8
        tax
        lda #<(40*LINE-2)           ; the previous section's T1 and Q's
        sta SECTAB-8+6,x
        sta SECTAB+6,x
        lda #>(40*LINE-2)
        sta SECTAB-8+7,x
        sta SECTAB+7,x
        .assert >BARCRTC = 0, error, "Q's R12 and R6 share the zero"
        lda #0                      ; >BARCRTC, and Q's R6
        sta SECTAB,x                ; hands the chain back to the bar
        sta SECTAB+4,x
        lda #<BARCRTC
        sta SECTAB+1,x
        lda #QROWS-1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #QVSYNC
        sta SECTAB+5,x
        rts
@cbl:   .byte <CRTCB_A, <CRTCB_B
@cbh:   .byte >CRTCB_A, >CRTCB_B
@cml:   .byte <(CRTCB_A-RINGCHARS), <(CRTCB_B-RINGCHARS)
@cmh:   .byte >(CRTCB_A-RINGCHARS), >(CRTCB_B-RINGCHARS)
; --- emit a run of tmp2 rows starting at ring offset w16, following entry X
@emit:  jsr @addr
        lda tmp2
        jsr @lines                  ; X = the run's entry
        lda tmp2
        sbc #0                      ; C = 0 out of the adc: tmp2 - 1
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
:       adc crtcb                   ; C = 0: both ways here are a bcc
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
@wrap:                              ; A = w16+1: both ways in have just stored it
        cmp #>RINGCHARS
        bcc :++
        bne :+
        lda w16
        cmp #<RINGCHARS
        bcc :++
:       lda w16                     ; C = 1: both ways here
        sbc #<RINGCHARS
        sta w16
        lda w16+1
        sbc #>RINGCHARS
        sta w16+1
:       rts
        ; --- A = lines, X = an entry -> its T1lo/T1hi (SECTAB+6/7,x) = the T1 count
        ; that lasts that long (tmp3 = the high byte); then X = the next entry (C = 0)
@dur:   lsr                         ; n*64 == (n*256)>>2
        sta tmp3
        lda #0
        ror
        lsr tmp3
        ror
        sbc #1                      ; C = 0 out of the ror pair: A - 2
        bcs :+
        dec tmp3
:       sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax
        rts

; ---------------------------------------------------------------- the mirror
        .segment "LGCCODE"          ; bank 7: render_core's last step
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
        lda #0
        sta mirlo,x
        lda #ROWCHARS-1
        sta mirhi,x
        sta mirdty,x                ; non-zero: dirty
:       lda mirdty,x                ; nothing has touched the ring's last row in this
        bne :+                      ; buffer since the mirror was last made
        rts
:       lda wcxm
        bne :+                      ; slot aligned: no row straddles, so the mirror is
        rts                         ; not read -- and the flag stays up for when it is
:       lda #0
        sta mirdty,x
        ldy mirhi,x                 ; the last written char
        sta mirhi,x                 ; the written range is empty again (mirlo below)
        lda mirlo,x                 ; the copy starts at the first written char, or at
        cmp wcxm                    ; wcxm if the writing started left of it
        bcs :+
        lda wcxm
:       sta tmp4                    ; and runs to the last written one
        lda #$FF
        sta mirlo,x
        lda wcxm                    ; the chars left of wcxm are not copied
        sta mirwcx,x
        tya                         ; the chars from the first written to the last
        sec
        sbc tmp4
        bcs :+                      ; nothing of it is in the window
        rts
:       adc #0                      ; C = 1 from the bcs: +1
        sta tmp
        ; source: the last slot, base + (RINGROWS-1)*640 + tmp4*8; the mirror is one
        ; whole ring below it
        .assert (RINGEND_A >> 8) - 3 = (RING_A >> 8) + (((RINGROWS-1)*ROWBYTES) >> 8) && (RINGEND_B >> 8) - 3 = (RING_B >> 8) + (((RINGROWS-1)*ROWBYTES) >> 8), error, "ringe3 is the last slot's page less the base's"
        .assert <(RING_A + (RINGROWS-1)*ROWBYTES) = $80 && <RING_A = <RING_B, error, "the last slot is at xx80"
        .assert (RING_A & $FF) + (RINGROWS-1)*ROWBYTES - RINGBYTES = -$200, error, "the mirror is 2 pages below the base page"
        lda tmp4                    ; T = tmp4*8: A = its high byte, C = bit 7 of its low
        lsr                         ; byte -- the carry out of the +$80 below
        lsr
        lsr
        lsr
        lsr
        tax
        adc ringe3                  ; ringbhi + >((RINGROWS-1)*ROWBYTES); C = 0 after
        sta w16+1
        txa
        adc ringbhi                 ; C = 0 in and out
        sbc #1                      ; C = 0: -2, the mirror's page
        sta w16b+1
        lda tmp4
        asl
        asl
        asl
        sta w16b
        eor #<(RING_A + (RINGROWS-1)*ROWBYTES)   ; +$80, its carry taken above
        sta w16
        ldy #0
@c:     ldx #8
@b:     lda (w16),y
        sta (w16b),y
        iny
        dex
        bne @b
        tya                         ; Z: Y = 0 (A is dead: reloaded at @b, and after the rts)
        bne :+
        inc w16+1
        inc w16b+1
:       dec tmp
        bne @c
        rts

; ---------------------------------------------------------------- the CRTC
        .segment "LGCLO"
crtc_init:                          ; start the chain at the bar and let vsync re-phase
        ldx #7                      ; written from the end of the tables: R8 = 0 first (no
@w:     lda @reg,x                  ; interlace: the MOS's MODE 1 leaves interlace sync on,
        sta CRTC_IDX                ; which puts every other field's vsync half a scanline
        lda @val,x                  ; later; the Master's crtc_init writes 0 too), R10 = $20
        sta CRTC_DAT                ; (the MOS's cursor off), ... R12/R13 last
        dex
        bpl @w
        rts
@reg:   .byte 13, 12, 7, 6, 4, 9, 10, 8
@val:   .byte <BARCRTC, >BARCRTC, 30, BARROWS, BARROWS-1, 7, $20, 0

        .segment "LGCBSS"
crtcb:    .res 2                    ; the buffer being built: its CRTC base, and the
crtcbm:   .res 2                    ; mirror redirect (base - RINGCHARS)
