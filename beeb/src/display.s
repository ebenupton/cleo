; ============================================================================
; The Model B's display driver (BHW=1 only): bank 7, with the logic.  The rupture
; chain the CRTC is driven by, the mirror the straddling row is read from, and the
; interrupt's work.  The Master's ring is hardware wrapped and its handler and chain
; are in main RAM (engine.s), so none of this is assembled for it.
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
        lda #<VS2T                  ; (an immediate: VS2T allows for its timing)
        sta VIA_T1LL
        lda #>VS2T
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


; ---------------------------------------------------------------- the mirror
        .segment "LGCCODE"          ; bank 7: render_core's last step
; A copy of the ring's last slot row sits immediately below the ring base, so the
; one displayed row that straddles the ring end can be read as a single run.  Only
; the chars that row takes from it -- wcxm..79 -- need to be right, and when the
; window is slot aligned no row straddles at all.  It is made only when its row
; has been written: its writers note the range (banks.s mirdirty6, mirdirty).
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
        .segment "LGCBSS"
crtcbm:   .res 2                    ; the buffer being built: its mirror redirect (base -
                                    ; RINGCHARS; its CRTC base, crtcb, is zero page's)
