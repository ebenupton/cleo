; ============================================================================
; Start-up.  The loader leaves bank 7 paged in and jumps to $8100.  The low-RAM
; image lives in bank 6 (the only bank with a corner free below the mask tables),
; so the copy runs there; the rest is the Master's start (src/main.s) less the
; disc: the tables it builds are static here (banks.s) and the bank-5 part is
; init5.
; ============================================================================
        .segment "LGCENT"           ; bank 7, $8100: the entry vector
        .assert * = BANKCODE, error, "the loader jumps to BANKCODE"
; A bank cannot page itself out and carry on: the instruction after the switch is
; read from the new bank.  So the switch runs from main RAM -- the bottom of the
; stack page, which nothing has used yet.
entry:  ldx #@stubend-@stub-1
:       lda @stub,x
        sta $0100,x
        dex
        bpl :-
        jmp $0100
@stub:  lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        jmp start6
@stubend:

        .segment "MAPLO"            ; bank 6
        .import __LOWCODE_LOAD__: absolute, __LOWCODE_RUN__: absolute
        .import __LOWCODE_SIZE__: absolute
start6:
        sei
        ldx #$3F                    ; the stack is 64 bytes: $0100-$013F
        txs
        lda #0                      ; zero page ($F0-$FF is the MOS's: $F4 is the
        ldx #0                      ; bank the loader selected, and the OS IRQ still
:       sta $00,x                   ; restores from it until take_over) and the low RAM
        inx
        cpx #$F0
        bne :-
        ldx #0
:       sta $0140,x
        inx
        cpx #$C4
        bne :-
        ; the low-RAM image is copied down to $0206
        lda #<__LOWCODE_LOAD__
        sta w16
        lda #>__LOWCODE_LOAD__
        sta w16+1
        lda #<__LOWCODE_RUN__
        sta w16b
        lda #>__LOWCODE_RUN__
        sta w16b+1
        .assert __LOWCODE_SIZE__ < 256, error, "the low-RAM image is copied a byte at a time"
        ldy #0                      ; exactly its length: the bar starts at $0300
@lc:    lda (w16),y
        sta (w16b),y
        iny
        cpy #<__LOWCODE_SIZE__
        bne @lc
        jmp to7                     ; the switch to bank 7 runs from low RAM (low.s)

        .segment "LGCCODE"
start7:
        farjsr F_INIT5              ; bank 5's records, spbank, the tile address table
        ; what the Master's init_tables sets that is this bank's or the zero page's
        stz MUSON
        stz SFXREQ
        lda #<VS2T_DEFAULT
        sta VS2T
        lda #>VS2T_DEFAULT
        sta VS2T+1
        jsr music_init
        lda #$34
        sta seed
        lda #$12
        sta seed+1
        jsr crtc_init
        ; both buffers' chains, for a blank window at the origin (ringS, barq, wfine
        ; are the zeros above), before the interrupt can walk one
        jsr build_sections
        inc curbuf
        jsr build_sections
        stz curbuf
        jsr take_over
        jsr music_start             ; the title menu would have
        jmp game_main
