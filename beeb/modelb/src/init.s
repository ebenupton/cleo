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
; read from the new bank.  So each switch lands on its continuation: entry's, at
; $8040 in bank 7, on start6 at $8047 in bank 6; bank 6's to7, the same seven bytes
; at $8040 there, on the jmp start7 at $8047 in bank 7.
entry:  bankimm lda, BANK_MAP, BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL                  ; the next fetch is bank 6's start6
        .assert * = BANKCODE + 7, error, "entry's switch must end where start6 begins"
        jmp start7                  ; bank 6's to7 lands here, in bank 7

        .segment "MAPLO"            ; bank 6
        .import __LOWCODE_SIZE__: absolute   ; (LOAD and RUN: cpu.inc, for the bank patches)
to7:    bankimm lda, BANK_LVL, BANK_MAP ; start6's way out: the next fetch is bank 7's
        sta ROMSEL_CPY              ; jmp start7, at the same address
        sta ROMSEL
start6:
        .assert * = BANKCODE + 7, error, "start6 must follow entry's switch"
        sei
        ldx #$3F                    ; the stack is 64 bytes: $0100-$013F
        txs
        lda #0                      ; zero page ($F0-$FF is the MOS's: $F4 is the
        ldx #$F0                    ; bank the loader selected, and the OS IRQ still
:       sta $FF,x                   ; restores from it until take_over): $00-$EF, zp,x
        sta $0113,x                 ; wrapping; and $0114-$0203, the low RAM and the
        dex                         ; stack above $0113 (nothing is on it yet)
        bne :-
        ; the low-RAM image is copied down to $0206 -- absolute indexed, the image being
        ; under a page (14 bytes shorter than two pointers: this bank's corner is full)
        .assert __LOWCODE_SIZE__ < 256, error, "the low-RAM image is copied a byte at a time"
@lc:    lda __LOWCODE_LOAD__,x      ; (X = 0) exactly its length: the bar starts at $0300
        sta __LOWCODE_RUN__,x
        inx
        cpx #<__LOWCODE_SIZE__
        bne @lc
        ldx #@to7end-@to7-1         ; the switch to bank 7 runs from the stack page,
:       lda @to7,x                  ; as the entry's did: a bank cannot page itself out
        sta $0100,x
        dex
        bpl :-
        jmp $0100
@to7:   bankimm lda, BANK_LVL, BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        jmp start7
@to7end:

        .segment "LGCCODE"
start7:
        wrsel BANK_LVL, BANK_LVL    ; (A = the bank from the stub: the write bank too)
        .assert dsk_board = dsk_banks + 4 && PBOARD = PBANK + 4, error, "the board byte follows the banks"
        ldx #4                      ; the physical banks and the board, from where the
@pb:    lda dsk_banks,x             ; loader put them (start6 has just zeroed the low BSS)
        sta PBANK,x
        dex
        bpl @pb
        jsr lvreset                 ; the records, the buffers' state
        ; MUSON and SFXREQ: the zeros start6 left (low BSS, zero page)
        lda #<VS2T_DEFAULT
        sta VS2T
        lda #>VS2T_DEFAULT
        sta VS2T+1
        ; (music_init: an rts on the Model B, whose period table is static)
        lda #$34
        sta seed
        lda #$12
        sta seed+1
        jsr blank_palette           ; nothing on the screen is a picture until the title
        jsr crtc_init
        ; both buffers' chains, for a blank window at the origin (ringS, barq, wfine
        ; are the zeros above), before the interrupt can walk one
        jsr build_sections
        inc curbuf
        jsr build_sections
        dec curbuf                  ; (1 -> 0: build_sections only reads it)
        farjsr F_INIT5              ; bank 5's state, spbank, then the interrupt takeover
        jsr disc_init               ; a 1770 board: reset, and the head found
        jmp game_main               ; the title menu loads its overlay and starts the tune
