; ============================================================================
; The Model B's mirror (BHW=1 only): bank 7, render_core's last step.  Its rings are
; software, so the one displayed row that straddles a ring's end is read from a copy
; below the ring's base; the Master's CRTC folds its ring itself.
; ============================================================================
        .segment "LGCCODE"
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
        ; both pointers page aligned in the reads' favour: the source's low byte goes
        ; to Y (Y0, a multiple of 8, so the page step still falls between chars), w16
        ; keeps the page, and the mirror's pointer comes down by Y0 -- its low byte is
        ; then $80 (L - (L ^ $80) = +-$80), a page lower when L < $80.  No read crosses
        ; a page (a store's cycles do not care)
        lda tmp4
        asl
        asl
        asl                         ; L, the char's offset in the row's page
        eor #<(RING_A + (RINGROWS-1)*ROWBYTES)   ; +$80, its carry taken above: Y0
        tay
        bpl :+
        dec w16b+1                  ; L < $80
:       lda #0
        sta w16
        lda #$80
        sta w16b
@c:     .repeat 8
        lda (w16),y
        sta (w16b),y
        iny
        .endrepeat
        beq @pg                     ; Z: Y = 0, a page done (out of line: 1 char in 32)
@cb:    dec tmp
        bne @c
        rts
@pg:    inc w16+1
        inc w16b+1
        jmp @cb

; ---------------------------------------------------------------- the CRTC
        .segment "LGCHW"            ; (after the shared)
crtcbm:   .res 2                    ; the buffer being built: its mirror redirect (base -
                                    ; RINGCHARS; its CRTC base, crtcb, is zero page's)
