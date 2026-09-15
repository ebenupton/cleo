; ============================================================================
; Main RAM, $0140-$02FF.  Everything here is visible whatever bank is paged in:
; the interrupt handler, the section table it reads, the far-call thunk, and the
; buffer a bank copies a strip of its data into for another bank to read.
; ============================================================================
        .segment "LOWCODE"

; ---------------------------------------------------------------- far calls
; X = the index of a (bank, address) entry.  The caller's bank comes back from the
; stack, so a bank may call one that replaces it, and a call may nest.
; X = the index of a (bank, address-1) entry.  The target address goes on the
; stack rather than into a patched jsr: the interrupt handler far-calls too, and
; a step landing between the patch and the jump sent the foreground wherever the
; handler was going.  Everything here is on the stack, so it nests and re-enters.
;
;   caller's return
;   caller's bank          <- fcret pulls this
;   fcret-1                <- the target's rts lands here
;   target-1               <- this rts goes there
farcall:
        sta fc_a
        lda ROMSEL_CPY
        pha
        lda #>(fcret-1)
        pha
        lda #<(fcret-1)
        pha
        lda FARTAB+2,x
        pha
        lda FARTAB+1,x
        pha
        lda FARTAB,x
        sta ROMSEL_CPY
        sta ROMSEL
        lda fc_a
        rts
fcret:  sta fc_a
        pla
        sta ROMSEL_CPY
        sta ROMSEL
        lda fc_a
        rts

; ---------------------------------------------------------------- map peek
; The logic reads single map bytes with this: ptr/Y address the map in bank 6 and
; the routine is in main RAM, so only the data is far away.  31 cycles.
mapbyte:
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        lda (w16b),y
        ldx #BANK_LGC
        stx ROMSEL_CPY
        stx ROMSEL
        rts

; ---------------------------------------------------------------- interrupts
irq_handler:
        stx irq_x
        sty irq_y
        bit VIA_IFR
        bvs @t1arm
        jmp @notT1
@t1arm: ; A rupture step is a CRTC restart: R12/R13 were armed during the section
        ; before and latch at the boundary; R9 with R4 decide where the section ends
        ; and are compared at the start of its last scanline, and R6 from scanline 1
        ; on.  The chain is phased so the step fires ~60 cycles BEFORE the restart,
        ; and the hold below carries the first write past it.
        ldx SECIDX
        ldy #5
@hold:  dey
        bne @hold
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
        lda SECTAB+4,x
        sta CRTC_DAT
        lda #7
        sta CRTC_IDX
        lda SECTAB+5,x
        sta CRTC_DAT
        sta curR7
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
        beq @stay                   ; off the end of SECTAB
        txa
        clc
        adc #8
        sta SECIDX
@stay:  ldy irq_y
        ldx irq_x
        lda $FC
        rti

@notT1:
        lda VIA_IFR
        and #$02
        beq @exit
        ; ---- vsync.  The T1 re-phase, the flip and section 0 all have the 64 lines
        ; between the vsync and the bar to happen in, so they live in bank 7 and this
        ; pays 63 cycles to reach them -- main RAM is 448 bytes and the step above is
        ; the only part of the chain that cannot afford to be anywhere else.
        farjsr F_VSYNC
@exit:
        ldy irq_y
        ldx irq_x
        lda $FC
        rti

        .segment "LOWBSS"
SECTAB:     .res 2*48               ; per buffer: 6 sections x 8 bytes
FARTAB:     .res 3*NFAR             ; (bank, lo, hi) per far entry point
; the mirror's bookkeeping: every bank writes it, and zero page is full
mirdty:     .res 2                  ; per buffer: the ring's last row has been written
mirwcx:     .res 2                  ; since the mirror was made, and the wcx it used
