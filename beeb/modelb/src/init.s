; ============================================================================
; Start-up, in main RAM: the BOOT piece (BANKS puts it at BOOTRAM, display RAM
; nothing has drawn in yet) with the low-RAM image behind it.  The loader jumps to
; `boot` with bank 7 paged.  Code in main RAM pages any bank it likes and carries
; on, so none of this needs a place in a bank: once play starts the display
; overwrites it.  The tables it builds on the Master are static here (banks.s).
; ============================================================================
        .segment "BOOT"
        .import __LOWCODE_LOAD__: absolute, __LOWCODE_RUN__: absolute, __LOWCODE_SIZE__: absolute
        .import __TILBSS_RUN__: absolute, __TILBSS_SIZE__: absolute
boot:   sei
        ldx #$3F                    ; the stack is 64 bytes: $0100-$013F
        txs
        lda #0                      ; zero page ($F0-$FF is the MOS's: $F4 is the
        ldx #$F0                    ; bank the loader selected, and the OS IRQ still
:       sta $FF,x                   ; restores from it until take_over): $00-$EF, zp,x
        sta $0113,x                 ; wrapping; and $0114-$0203, the low RAM and the
        dex                         ; stack above $0113 (nothing is on it yet)
        bne :-
        .assert __LOWCODE_SIZE__ < 256, error, "the low-RAM image is copied a byte at a time"
@lc:    lda __LOWCODE_LOAD__,x      ; (X = 0) exactly its length: the bar starts at $0300
        sta __LOWCODE_RUN__,x
        inx
        cpx #<__LOWCODE_SIZE__
        bne @lc
        bankimm lda, BANK_LVL, BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_LVL, BANK_LVL
        .assert dsk_board = dsk_banks + 4 && PBOARD = PBANK + 4, error, "the board byte follows the banks"
        ldx #4                      ; the physical banks and the board, from where the
@pb:    lda dsk_banks,x             ; loader put them (the loop above has just zeroed
        sta PBANK,x                 ; the low BSS)
        dex
        bpl @pb
        jsr lvreset                 ; the records, the buffers' state
        ; MUSON and SFXREQ: the zeros above (low BSS, zero page)
        ; (music_init: an rts on the Model B, whose period table is static)
        lda #$34
        sta seed
        lda #$12
        sta seed+1
        jsr blank_palette           ; nothing on the screen is a picture until the title
  .if .not BHW                      ; the converged Master: its handler's state in main RAM
        .import __TABLES_RUN__: absolute, __TABLES_SIZE__: absolute
        .assert __TABLES_SIZE__ < 256, error, "boot zeroes TABLES with an 8-bit index"
        ldx #<__TABLES_SIZE__       ; (LOADREQ above all: a load is not under way)
        lda #0
:       dex
        sta __TABLES_RUN__,x
        bne :-
  .endif
        jsr crtc_init
  .if .not BHW
        jsr calc_ring               ; the Master's chain wants the ring's state (zeros here)
  .endif
        ; both buffers' chains, for a blank window at the origin (ringS, barq, wfine
        ; are the zeros above), before the interrupt can walk one
        jsr build_sections
        inc curbuf
        jsr build_sections
        dec curbuf                  ; (1 -> 0: build_sections only reads it)
        ; bank 6's state: the ring work's, zero as the Master's tables; spbank
        bankimm lda, BANK_TILES, BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_TILES, BANK_LVL
        .assert __TILBSS_SIZE__ < 256, error, "boot zeroes TILBSS with an 8-bit index"
        ldx #<__TILBSS_SIZE__
        lda #0
:       dex
        sta __TILBSS_RUN__,x
        bne :-
        bankimm lda, BANK_SPR, BANK_LVL
        sta spbank
        jsr take_over               ; the interrupt: bank 6 still paged, as it was
        jsr pagelogic               ; bank 7 (low RAM's, the image copied above)
        jsr disc_init               ; a 1770 board: reset, and the head found
        jmp game_main               ; the title menu loads its overlay and starts the tune
; the loader's: the physical bank of each of banks 4..7 and the board -- read once,
; above, into PBANK and PBOARD
dsk_banks: .res 4
dsk_board: .res 1
