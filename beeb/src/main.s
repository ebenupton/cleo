; ============================================================================
; CLEO - main program: init, loading, game
; ============================================================================
        .include "cpu.inc"
        .code
        jmp start
        .import __LOGIC_START__, __LOGIC_LAST__
        .import __MAIN_LAST__, __LOW_START__, __LOW_LAST__, __LOW2_START__, __LOW2_LAST__
        .include "engine.s"
        .include "logic.s"
        .include "menu.s"

        .code
; ---------------------------------------------------------------- entry
start:
        jsr disc_drive              ; which drive we came from, while DFS can still say
        sei
        ; NMI handler: jump to ours (1770 DRQ/INTRQ driven sector transfer)
        lda #$4C
        sta $0D00
        lda #<nmi_handler
        sta $0D01
        lda #>nmi_handler
        sta $0D02
        ; the LOW overlay (render helpers) comes first in the file after the main code:
        ; copy it into the NMI page after our JMP at $0D00
        ldy #<(__LOW_LAST__ - __LOW_START__)
:       lda __MAIN_LAST__-1,y       ; top down, so Y leaves at 0
        sta __LOW_START__-1,y
        dey
        bne :-
        ; LOW2 follows LOW in the file; its home ($0300) is VDU workspace until MODE 1 has
        ; been selected and the screen clear wipes the file image, so stage it in SPRREC:
        ; two whole pages (SPRREC is 640 bytes; the overrun past LOW2's end lands in
        ; MASKTAB, rebuilt below)
:       lda __MAIN_LAST__ + __LOW_LAST__ - __LOW_START__,y
        sta SPRREC,y
        lda __MAIN_LAST__ + __LOW_LAST__ - __LOW_START__ + 256,y
        sta SPRREC+256,y
        iny
        bne :-
        cli
        lda #22
        jsr OSWRCH
        lda #1
        jsr OSWRCH
        sei

:       lda SPRREC,y
        sta __LOW2_START__,y
        lda SPRREC+256,y
        sta __LOW2_START__+256,y
        iny
        bne :-
        ; The tables are bss and nothing has zeroed them.  A Master happens to hand
        ; them over clear, but SECIDX picking up a stray value walks the rupture
        ; chain off the end of SECTAB, so they are cleared rather than trusted.
        stz ptr                     ; <$0400 is 0
        lda #>$0400
        sta ptr+1
        ldx #$0D - >$0400           ; pages $04..$0C
        tya                         ; Y = 0 from the copy above
:       sta (ptr),y
        iny
        bne :-
        inc ptr+1
        dex
        bne :-
        jsr blank_palette
        jsr disc_init
        lda #FI_LOGIC               ; the game logic lives in bank 7 above the level
        jsr loadfile                ; tables, so it has to come in before init_tables
        jsr t_init_tables
        jsr build_tileaddr          ; tile id -> address, constant for every level
        lda #FI_SPR
        jsr loadfile
        lda #FI_SPRAND
        jsr loadfile
        lda #FI_BOX
        jsr loadfile
        lda #FI_MUSIC
        jsr loadfile
        lda #FI_ALT
        jsr loadfile
        jsr music_init              ; period table out of the tile bits into RAM
        lda #$34
        sta seed
        lda #$12
        sta seed+1
        jsr crtc_init
        stza wx
        stza wx+1
        stza wy
        stza wy+1
        stza wcx
        stza wcx+1
        stza wcy
        stza wfine
        stza curbuf
        jsr calc_ring
        jsr t_build_sections
        inc curbuf
        jsr t_build_sections
        stza curbuf
        stza DISPSECT
        jsr take_over
        jsr set_palette
        jmp game_main

        .include "game.s"

; ---------------------------------------------------------------- sprite directory
; It lived in main RAM so drawsprite could read it whatever bank was selected.  That
; cost 944 bytes of the only RAM the CRTC can scan, and the status bar needs 1280 of
; it below $3000.  In bank 7 instead: drawsprite selects BANK_LVL for the whole
; prologue (nothing there reads sprite DATA) and selects the data bank afterwards.
        .segment "LOGIC"
SPR_TABLE:
        .incbin "build/SPRTAB"
SPRMASK:                            ; mask plane address by sprite id (MODE 1)
        .incbin "build/SPRMASK"
        .code
