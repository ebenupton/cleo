; ============================================================================
; LOADER -- runs at $1900 from !BOOT, fills the four sideways banks and jumps
; into the game.  DFS will not load into a sideways bank (it pages itself in to
; do the transfer), so each image is staged at $2000 in main RAM and copied.
; ============================================================================
        .setcpu "6502"
BANKCODE = $8100
OSFILE  = $FFDD
OSWRCH  = $FFEE
ROMSEL  = $FE30
ROMSELC = $F4
zsrc    = $70
zdst    = $72

        .segment "CODE"
start:
        lda ROMSELC
        sta oldbank
        ldx #0
@bank:  stx idx
        txa
        clc
        adc #'4'                    ; BANK4 .. BANK7
        sta fname+4
        lda #$00                    ; OSFILE fills the block in with the file's own
        sta block+2                 ; load address on the way out, so set ours again
        sta block+6                 ; every time (+6 = 0 means "use the block's")
        lda #$20
        sta block+3
        lda #$FF
        sta block+4
        sta block+5
        lda #$FF                    ; OSFILE 255: load, address from the block
        ldx #<block
        ldy #>block
        jsr OSFILE
        lda #0
        sta zsrc
        sta zdst
        lda #$20
        sta zsrc+1
        lda #$80
        sta zdst+1
        lda idx
        clc
        adc #4
        sei                         ; both copies: an interrupt that pages a ROM in
        sta ROMSELC                 ; restores from $F4, and would otherwise take ours out
        sta ROMSEL
        ldx #64                     ; 64 pages = 16K
        ldy #0
@cp:    lda (zsrc),y
        sta (zdst),y
        iny
        bne @cp
        inc zsrc+1
        inc zdst+1
        dex
        bne @cp
        lda oldbank
        sta ROMSELC
        sta ROMSEL
        cli
        ldx idx
        inx
        cpx #4
        bne @bank
        lda #22                     ; MODE 1: the OS sets the ULA and the screen size
        jsr OSWRCH                  ; latch; the game reprograms only the CRTC
        lda #1
        jsr OSWRCH
        sei
        lda #7
        sta ROMSELC
        sta ROMSEL
        jmp BANKCODE                ; bank 7's entry vector

idx:      .byte 0
oldbank:  .byte 0
fname:    .byte "BANK4", 13
block:    .word fname
          .dword $FFFF2000          ; load address: the $FFFF names the I/O
                                    ; processor, and DFS wants it even with no tube
          .dword $00000000          ; exec address: 0 here means "use the one above"
          .dword $00000000
          .dword $00000000
