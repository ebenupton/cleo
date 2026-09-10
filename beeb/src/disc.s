; ============================================================================
; disc.s -- polled sector reads on any of the three BBC floppy controllers,
; detected at run time.  Pure 6502, so it assembles for a Model B too.
;
;   Master 128        WD1770, control $FE24, registers $FE28..$FE2B
;   Model B + 1770    WD1770, control $FE80, registers $FE84..$FE87
;   Model B + 8271    Intel 8271 at $FE80..$FE84
;
; Both controllers hand over one byte at a time by NMI, so the transfer is a
; store instruction in the NMI handler whose address walks forward.  DFS single
; density: 10 sectors of 256 bytes per track, numbered from 0.
;
;   d_detect   -> d_type (0 none, 1 = 1770, 2 = 8271); installs the NMI handler
;   d_init     spin the drive up and set the controller's mode
;   d_read     d_sec (16-bit linear sector), d_n sectors, ptr = destination
;
; The caller supplies `ptr` in zero page.
; ============================================================================

W_CTRL  = $FE24                     ; Master addresses; patched for a Model B
W_STAT  = $FE28
W_TRK   = $FE29
W_SEC   = $FE2A
W_DATA  = $FE2B
I_STAT  = $FE80                     ; 8271: read status / write command
I_PARM  = $FE81                     ;       write parameter / read result
I_RESET = $FE82
I_DATA  = $FE84

DISC_NONE = 0
DISC_1770 = 1
DISC_8271 = 2

        .segment "DISCVARS"
d_type:  .res 1
d_sec:   .res 2
d_n:     .res 1
d_trk:   .res 1
d_sc:    .res 1
d_secs:  .res 1
d_done:  .res 1
d_cur:   .res 1

        .segment "DISCCODE"

; ---------------------------------------------------------------- NMI
d_nmi70:
        pha
d_n70s: lda W_STAT
        and #3
        cmp #3                      ; busy and DRQ: a byte is waiting
        bne d_n70e
d_n70d: lda W_DATA
d_n70p: sta $FFFF
        inc d_n70p+1
        bne d_n70x
        inc d_n70p+2
d_n70x: pla
        rti
d_n70e: and #1
        bne d_n70x
        inc d_done                  ; the command has finished
        pla
        rti

d_nmi82:
        pha
        lda I_STAT
        and #$04                    ; non-DMA data request
        beq d_n82e
        lda I_DATA
d_n82p: sta $FFFF
        inc d_n82p+1
        bne d_n82x
        inc d_n82p+2
d_n82x: pla
        rti
d_n82e: lda I_STAT
        and #$08                    ; interrupt request: command complete
        beq d_n82x
        lda I_PARM                  ; reading the result clears it
        inc d_done
        pla
        rti

; ---------------------------------------------------------------- detection
d_detect:
        lda #DISC_NONE
        sta d_type
        lda #$4C                    ; JMP at $0D00, the NMI entry
        sta $0D00
        lda #0
        ldx #1
        jsr $FFF4                   ; OSBYTE 0: X = MOS version, 3 on a Master
        cpx #3
        bcs d_dmast
        ; ---- Model B: aim the 1770 code at $FE80/$FE84 in case it is that board
        lda #$80
        sta d_ic1+1
        sta d_ic2+1
        lda #$84
        sta d_is1+1
        sta d_is2+1
        sta d_is3+1
        sta d_ic3+1
        sta d_ic4+1
        sta d_n70s+1
        lda #$85
        sta d_it1+1
        lda #$86
        sta d_ix1+1
        lda #$87
        sta d_id1+1
        sta d_n70d+1
        lda #$08                    ; and the control values this board wants
        sta d_iv1+1
        lda #$29
        sta d_iv2+1
        ; The 8271 lives at these addresses too and would need probing to tell
        ; the two boards apart; for now a Model B is assumed to have the 1770
        ; upgrade (d_nmi82 and the 8271 paths below are ready for that work).
        lda #DISC_1770
        sta d_type
        jmp d_d70
d_dmast:
        lda #DISC_1770
        sta d_type
d_d70:  lda #<d_nmi70
        sta $0D01
        lda #>d_nmi70
        sta $0D02
        rts

; ---------------------------------------------------------------- init
d_init:
        lda #$FF
        sta d_cur                   ; track unknown
        lda d_type
        cmp #DISC_8271
        beq d_i82
        ; The two boards spell the control register differently.  Master: bit 2 is
        ; reset (active low), bit 5 density, bit 4 side, bits 1..0 the drives.  The
        ; Acorn Model B board: bit 5 is reset, bit 3 density, bit 2 side, bits 1..0
        ; the drives.  Density is active low on both, so DFS wants the bit set.
d_iv1:  lda #$20                    ; reset asserted, no drive selected
d_ic1:  sta W_CTRL
d_iv2:  lda #$25                    ; drive 0, single density, reset released
d_ic2:  sta W_CTRL
        lda #$00                    ; restore, spin up
d_ic3:  sta W_STAT
        jmp d_wait
d_i82:  lda #0
        sta I_RESET
        ldx #0
d_i8w:  dex
        bne d_i8w
        lda #$35                    ; specify: initialisation
        sta I_STAT
        lda #$0D
        jsr d_par
        lda #$1D
        jsr d_par
        lda #$FF
        jsr d_par
        lda #$FF
        jmp d_par

d_par:  pha
d_parw: lda I_STAT
        and #$20                    ; parameter register full
        bne d_parw
        pla
        sta I_PARM
        rts

d_wait: ldx #20                     ; the 1770 needs a moment before it reads busy
d_wd:   dex
        bne d_wd
d_ww:
d_is1:  lda W_STAT
        and #1
        bne d_ww
        rts

; ---------------------------------------------------------------- read
d_read:
        lda #0                      ; linear sector -> track and sector
        sta d_trk
        lda d_sec
        sta d_sc
        lda d_sec+1
        beq d_rn
d_rb:   lda d_sc                    ; 256 sectors = 25 tracks and 6 sectors
        clc
        adc #6
        sta d_sc
        lda d_trk
        adc #25
        sta d_trk
        dec d_sec+1
        bne d_rb
d_rn:   lda d_sc
        cmp #10
        bcc d_rt
        sbc #10
        sta d_sc
        inc d_trk
        jmp d_rn
d_rt:   lda #10                     ; how many of them are on this track
        sec
        sbc d_sc
        cmp d_n
        bcc d_rt1
        lda d_n
d_rt1:  sta d_secs
        jsr d_dest
        lda #0
        sta d_done
        lda d_type
        cmp #DISC_8271
        beq d_r82
        ; ---- 1770
        lda d_trk
        cmp d_cur
        beq d_rsk
        sta d_cur
d_id1:  sta W_DATA
        lda #$10                    ; seek, no verify
d_ic4:  sta W_STAT
        jsr d_wait
d_rsk:  lda d_sc
d_ix1:  sta W_SEC
        lda d_trk
d_it1:  sta W_TRK
        lda d_secs
        cmp #1
        beq d_r1s
        lda #$94                    ; read multiple sectors
        bne d_rgo
d_r1s:  lda #$84                    ; read one sector
d_rgo:
d_is2:  sta W_STAT
        ldx #20
d_rgw:  dex
        bne d_rgw
d_rp:   lda d_done
        bne d_rf
d_is3:  lda W_STAT
        and #1
        bne d_rp
d_rf:   jsr d_wait
        jmp d_rnx
        ; ---- 8271
d_r82:  lda #$53                    ; read data, multi-record
        sta I_STAT
        lda d_trk
        jsr d_par
        lda d_sc
        jsr d_par
        lda d_secs
        ora #$20                    ; sector size code 1 (256 bytes) in bits 7..5
        jsr d_par
d_r8p:  lda d_done
        bne d_rnx
        lda I_STAT
        and #$80                    ; still busy?
        bne d_r8p
d_rnx:  lda ptr+1                   ; step the destination past what was read
        clc
        adc d_secs
        sta ptr+1
        lda d_n
        sec
        sbc d_secs
        sta d_n
        beq d_rdn
        lda #0
        sta d_sc
        inc d_trk
        jmp d_rt
d_rdn:  rts

d_dest: lda ptr                     ; both NMI handlers store through their own operand
        sta d_n70p+1
        sta d_n82p+1
        lda ptr+1
        sta d_n70p+2
        sta d_n82p+2
        rts
