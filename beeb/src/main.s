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
.ifdef MODELB
        .include "reloc.s"          ; the file loads clear of the DFS and moves down
.endif

        .code
; ---------------------------------------------------------------- entry
start:
        jsr disc_detect             ; first, while the MOS is still whole: it calls
                                    ; OSBYTE, and the LOW2 overlay below lands on
                                    ; BYTEV.  Nothing may touch the controller until
                                    ; this has run -- on a Model B the Master's
                                    ; control register is the video ULA.
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
        lda #<__MAIN_LAST__
        sta ptr
        lda #>__MAIN_LAST__
        sta ptr+1
        ldy #0
:       lda (ptr),y
        sta __LOW_START__,y
        iny
        cpy #<(__LOW_LAST__ - __LOW_START__)
        bne :-
        ; LOW2 follows LOW in the file; its home ($0300) is VDU workspace until MODE 2 has
        ; been selected and the screen clear wipes the file image, so stage it in SPRREC
        lda #<(__MAIN_LAST__ + __LOW_LAST__ - __LOW_START__)
        sta ptr
        lda #>(__MAIN_LAST__ + __LOW_LAST__ - __LOW_START__)
        sta ptr+1
        ldy #0                      ; two whole pages (SPRREC is 640 bytes; the overrun
:       lda (ptr),y                 ; past LOW2's end lands in MASKTAB, rebuilt below)
        sta SPRREC,y
        iny
        bne :-
        inc ptr+1
:       lda (ptr),y
        sta SPRREC+256,y
        iny
        bne :-
        cli
        lda #22
        jsr OSWRCH
        lda #2
        jsr OSWRCH
        sei
        ldy #0
:       lda SPRREC,y
        sta __LOW2_START__,y
        lda SPRREC+256,y
        sta __LOW2_START__+256,y
        iny
        bne :-
        ; The tables are bss and nothing has zeroed them.  A Master happens to hand
        ; them over clear; a Model B leaves the filing system's function key buffer
        ; and the rest of its workspace lying in $0400..$0CFF, and SECIDX picking up
        ; a stray value walks the rupture chain off the end of SECTAB.
        lda #<$0400
        sta ptr
        lda #>$0400
        sta ptr+1
        lda #0
:       sta (ptr),y                 ; (Y is 0 from the loop above and stays there)
        iny
        bne :-
        inc ptr+1
        ldx ptr+1
        cpx #$0D
        bne :-
        jsr blank_palette
        jsr disc_init
        lda #FI_LOGIC               ; the game logic lives in bank 7 above the level
        jsr loadfile                ; tables, so it has to come in before init_tables
        jsr t_init_tables
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

; ---------------------------------------------------------------- level loading
; X = level index 0..15 (even = main, odd = bonus)
load_level:
        ; file order is L0A, L0B, L1A, ..., two files each, and level index 0 is the
        ; main level, which is the 'B' one: file = FI_L0A + (i eor 1) * 2
        txa
        eor #1
        sta tmp2                    ; three pieces: page tables, map, bank-7 tables
        asl
        clc
        adc tmp2
        adc #FI_L0A
        sta tmp2
        jsr loadfile
        lda tmp2
        inca
        sta tmp2
        jsr loadfile
        lda tmp2
        inca
        jsr loadfile
        jsr load_tiles              ; only the tiles this level's page tables name
        ; geometry
        setbank BANK_LVL
        lda LV_HDR
        sta maplw
        lda LV_HDR+1
        sta maplh
        ; mapw = 8 << lw ; maph = 8 << lh
        lda #8
        sta mapw
        stza mapw+1
        ldx maplw
:       asl mapw
        rol mapw+1
        dex
        bne :-
        lda #8
        sta maph
        stza maph+1
        ldx maplh
:       asl maph
        rol maph+1
        dex
        bne :-
        lda mapw
        sec
        sbc #WINPX
        sta maxwx
        lda mapw+1
        sbc #0
        sta maxwx+1
        lda maph
        sec
        sbc #VISLINES/2
        sta maxwy
        lda maph+1
        sbc #0
        sta maxwy+1
        stza BUF_VALID
        stza BUF_VALID+1
        stza RECCNT
        stza RECCNT+1
        stza DIRTYCNT
        stza DIRTYCNT+1
        stza NSPR
        rts

; File table.  Five parallel arrays rather than five-byte records: there are more
; than fifty files now and index * 5 does not fit in a byte.
        .include "files.inc"
FTMODE .set 0
.macro FILE sec, n, bank, dest
.if FTMODE = 0
        .byte <(sec)
.elseif FTMODE = 1
        .byte >(sec)
.elseif FTMODE = 2
        .byte n
.elseif FTMODE = 3
        .byte bank
.else
        .byte >(dest)
.endif
.endmacro
.macro FILE_LIST
        FILE F_SPR_SEC,   F_SPR_N,   BANK_SPR,  $8000
        FILE F_TILESO_SEC, F_TILESO_N, BANK_TIL0, $8000
        FILE F_TILESI_SEC, F_TILESI_N, BANK_TIL0, $8000
        FILE F_LOGIC_SEC, <((__LOGIC_LAST__ - __LOGIC_START__ + 255) / 256), BANK_LVL, LOGIC_ADDR
        FILE F_BOX_SEC,   F_BOX_N,   BANK_TIL1, BOX_BASE
        FILE F_MUSIC_SEC, F_MUSIC_N, BANK_TIL1, MUSIC_ADDR
        FILE F_ALT_SEC,   F_ALT_N,   BANK_LVL,  LV_ALTTAB
        FILE F_TITLE_SEC, F_TITLE_N, BANK_MAP,  TITLE_ADDR
        FILE F_L0A_SEC, LP_L0A, BANK_MAP, LV_ROWPAGE
        FILE F_L0A_SEC + LP_L0A, LM_L0A, BANK_MAP, LV_MAP
        FILE F_L0A_SEC + LP_L0A + LM_L0A, F_L0A_N - LP_L0A - LM_L0A, BANK_LVL, LV_HDR
        FILE F_L0B_SEC, LP_L0B, BANK_MAP, LV_ROWPAGE
        FILE F_L0B_SEC + LP_L0B, LM_L0B, BANK_MAP, LV_MAP
        FILE F_L0B_SEC + LP_L0B + LM_L0B, F_L0B_N - LP_L0B - LM_L0B, BANK_LVL, LV_HDR
        FILE F_L1A_SEC, LP_L1A, BANK_MAP, LV_ROWPAGE
        FILE F_L1A_SEC + LP_L1A, LM_L1A, BANK_MAP, LV_MAP
        FILE F_L1A_SEC + LP_L1A + LM_L1A, F_L1A_N - LP_L1A - LM_L1A, BANK_LVL, LV_HDR
        FILE F_L1B_SEC, LP_L1B, BANK_MAP, LV_ROWPAGE
        FILE F_L1B_SEC + LP_L1B, LM_L1B, BANK_MAP, LV_MAP
        FILE F_L1B_SEC + LP_L1B + LM_L1B, F_L1B_N - LP_L1B - LM_L1B, BANK_LVL, LV_HDR
        FILE F_L2A_SEC, LP_L2A, BANK_MAP, LV_ROWPAGE
        FILE F_L2A_SEC + LP_L2A, LM_L2A, BANK_MAP, LV_MAP
        FILE F_L2A_SEC + LP_L2A + LM_L2A, F_L2A_N - LP_L2A - LM_L2A, BANK_LVL, LV_HDR
        FILE F_L2B_SEC, LP_L2B, BANK_MAP, LV_ROWPAGE
        FILE F_L2B_SEC + LP_L2B, LM_L2B, BANK_MAP, LV_MAP
        FILE F_L2B_SEC + LP_L2B + LM_L2B, F_L2B_N - LP_L2B - LM_L2B, BANK_LVL, LV_HDR
        FILE F_L3A_SEC, LP_L3A, BANK_MAP, LV_ROWPAGE
        FILE F_L3A_SEC + LP_L3A, LM_L3A, BANK_MAP, LV_MAP
        FILE F_L3A_SEC + LP_L3A + LM_L3A, F_L3A_N - LP_L3A - LM_L3A, BANK_LVL, LV_HDR
        FILE F_L3B_SEC, LP_L3B, BANK_MAP, LV_ROWPAGE
        FILE F_L3B_SEC + LP_L3B, LM_L3B, BANK_MAP, LV_MAP
        FILE F_L3B_SEC + LP_L3B + LM_L3B, F_L3B_N - LP_L3B - LM_L3B, BANK_LVL, LV_HDR
        FILE F_L4A_SEC, LP_L4A, BANK_MAP, LV_ROWPAGE
        FILE F_L4A_SEC + LP_L4A, LM_L4A, BANK_MAP, LV_MAP
        FILE F_L4A_SEC + LP_L4A + LM_L4A, F_L4A_N - LP_L4A - LM_L4A, BANK_LVL, LV_HDR
        FILE F_L4B_SEC, LP_L4B, BANK_MAP, LV_ROWPAGE
        FILE F_L4B_SEC + LP_L4B, LM_L4B, BANK_MAP, LV_MAP
        FILE F_L4B_SEC + LP_L4B + LM_L4B, F_L4B_N - LP_L4B - LM_L4B, BANK_LVL, LV_HDR
        FILE F_L5A_SEC, LP_L5A, BANK_MAP, LV_ROWPAGE
        FILE F_L5A_SEC + LP_L5A, LM_L5A, BANK_MAP, LV_MAP
        FILE F_L5A_SEC + LP_L5A + LM_L5A, F_L5A_N - LP_L5A - LM_L5A, BANK_LVL, LV_HDR
        FILE F_L5B_SEC, LP_L5B, BANK_MAP, LV_ROWPAGE
        FILE F_L5B_SEC + LP_L5B, LM_L5B, BANK_MAP, LV_MAP
        FILE F_L5B_SEC + LP_L5B + LM_L5B, F_L5B_N - LP_L5B - LM_L5B, BANK_LVL, LV_HDR
        FILE F_L6A_SEC, LP_L6A, BANK_MAP, LV_ROWPAGE
        FILE F_L6A_SEC + LP_L6A, LM_L6A, BANK_MAP, LV_MAP
        FILE F_L6A_SEC + LP_L6A + LM_L6A, F_L6A_N - LP_L6A - LM_L6A, BANK_LVL, LV_HDR
        FILE F_L6B_SEC, LP_L6B, BANK_MAP, LV_ROWPAGE
        FILE F_L6B_SEC + LP_L6B, LM_L6B, BANK_MAP, LV_MAP
        FILE F_L6B_SEC + LP_L6B + LM_L6B, F_L6B_N - LP_L6B - LM_L6B, BANK_LVL, LV_HDR
        FILE F_L7A_SEC, LP_L7A, BANK_MAP, LV_ROWPAGE
        FILE F_L7A_SEC + LP_L7A, LM_L7A, BANK_MAP, LV_MAP
        FILE F_L7A_SEC + LP_L7A + LM_L7A, F_L7A_N - LP_L7A - LM_L7A, BANK_LVL, LV_HDR
        FILE F_L7B_SEC, LP_L7B, BANK_MAP, LV_ROWPAGE
        FILE F_L7B_SEC + LP_L7B, LM_L7B, BANK_MAP, LV_MAP
        FILE F_L7B_SEC + LP_L7B + LM_L7B, F_L7B_N - LP_L7B - LM_L7B, BANK_LVL, LV_HDR
        FILE F_SPRAND_SEC, F_SPRAND_N, BANK_SPR|$80, $8000   ; -> ANDY (ROMSEL bit7)
.endmacro
FTMODE .set 0
ft_seclo: FILE_LIST
FTMODE .set 1
ft_sechi: FILE_LIST
FTMODE .set 2
ft_n:     FILE_LIST
FTMODE .set 3
ft_bank:  FILE_LIST
FTMODE .set 4
ft_dest:  FILE_LIST

FI_SPR = 0
FI_TILESO = 1                     ; the two tile sets, outdoors and indoors
FI_TILESI = 2
FI_LOGIC = 3
FI_BOX = 4
FI_MUSIC = 5
FI_ALT = 6
FI_TITLE = 7
FI_L0A = 8                        ; three pieces per level: pages, map, tables
FI_SPRAND = 56

; ---------------------------------------------------------------- camera clamp
; clamp wx to [0, maxwx] (and even), wy to [0, maxwy]
clamp_window:
        lda wx+1
        bmi @wx0
        lda wx
        sec
        sbc maxwx
        lda wx+1
        sbc maxwx+1
        bmi @wxok
        lda maxwx
        sta wx
        lda maxwx+1
        sta wx+1
        bra @wxok
@wx0:   stz wx
        stz wx+1
@wxok:  lda wx
        and #$FE
        sta wx
        lda wy+1
        bmi @wy0
        lda wy
        sec
        sbc maxwy
        lda wy+1
        sbc maxwy+1
        bmi @wyok
        lda maxwy
        sta wy
        lda maxwy+1
        sta wy+1
        rts
@wy0:   stza wy
        stza wy+1
@wyok:  rts

; ---------------------------------------------------------------- game
game_main:
        stza hiscore
        stza hiscore+1
        stza maxlevel
        stza title_res
title_loop:
        jsr t_title_menu
        cmp #MENU_HELP
        bne new_game
        jsr t_help_screen
        bra title_loop
new_game:
        stz level
        lda #3
        sta lives
        sta health
        stz score
        stz score+1
        lda maxlevel
        beq level_loop
        jsr t_level_select
        asl
        sta level
level_loop:
        jsr blank_palette           ; hide the loading and the first-frame build-up
        stza title_res               ; the level's map replaces the title pack
        ldx level
        jsr load_level
        jsr t_level_init
        lda #1                      ; lay the bar template + digits into both buffers on
        sta BARBG                   ; the first two renders (drawing now would hit the
        sta BARBG+1                 ; wrong buffer -- this is before the flip)
        sta BARDIRTY
        sta BARDIRTY+1
        ; initial camera; render both buffers before the palette comes back
        jsr t_game_frame
        jsr render_frame
        stza NSPR
        jsr t_game_frame
        jsr render_frame
        jsr set_palette
        stz NSPR
        lda vsyncs
        sta logicvs
        stz pausing
frame_loop:
        ; pause?
        lda keys
        and #K_MENU
        beq @nopause
        lda pausing
        bne @nopause
        jsr t_pause_menu
        cmp #0
        beq :+
        jmp title_loop
:       lda #1
        sta pausing
        lda vsyncs
        sta logicvs
        bra frame_loop
@nopause:
        lda keys
        and #K_MENU
        bne :+
        stz pausing
:       ; 25Hz logic: exactly one step per render, and any time lost to a long
        ; frame is dropped rather than caught up.  Catching up ran two or three
        ; steps in a row, which moved the window several char rows in one frame;
        ; the two buffers share a ring on a Model B and have only two rows of
        ; slack between them, so a frame is a frame.
        lda vsyncs
        sec
        sbc logicvs
        cmp #2
        bcc @wait
        lda vsyncs
        sta logicvs
        stza NSPR
        jsr t_game_frame
        lda exiting
        bne @over
        jsr render_frame
        bra frame_loop
@wait:  ; nothing to do yet: wait for the next vsync
        lda vsyncs
:       cmp vsyncs
        beq :-
        bra frame_loop
@over:
        ; level over
        lda lives
        beq game_over
        lda stars
        beq @next1
        lda level
        and #1
        bne @next1
        inc level
@next1: inc level
        lda level
        cmp #16
        beq game_won
        lsr
        cmp maxlevel
        bcc :+
        sta maxlevel
:       jmp level_loop
game_over:
        jsr update_hiscore
        lda #0
        jsr t_winlose
        jmp title_loop
game_won:
        jsr update_hiscore
        lda #1
        jsr t_winlose
        jmp title_loop
update_hiscore:
        lda hiscore
        cmp score
        lda hiscore+1
        sbc score+1
        bcs :+
        mov16 hiscore, score
:       rts

; ---------------------------------------------------------------- sound data
; sfx steps: byte0 = channel/period latch ($80 | ch<<5 | lo4), byte1 = period hi (data byte), byte2 = volume ($90|ch<<5|att), duration
sfxtab: .word sfx_jump, sfx_star, sfx_throw, sfx_hit, sfx_kill, sfx_power, sfx_die
sfx_jump:  .byte $C0|8, 12, $D0, 2,  $C0|4, 9, $D2, 2,  $C0|0, 7, $D4, 2,  $C0|8, 5, $D6, 3, $FF
sfx_star:  .byte $C0|0, 4, $D0, 2,  $C0|0, 3, $D0, 3,  $C0|0, 3, $D6, 3, $FF
sfx_throw: .byte $E0|4, 0, $F2, 2,  $E0|5, 0, $F5, 3,  $E0|5, 0, $F9, 3, $FF
sfx_hit:   .byte $C0|0, 40, $D0, 4, $C0|0, 48, $D2, 4, $C0|0, 60, $D5, 5, $FF
sfx_kill:  .byte $C0|0, 6, $D0, 2,  $C0|0, 9, $D1, 2,  $C0|0, 12, $D3, 3, $C0|0, 16, $D6, 3, $FF
sfx_power: .byte $C0|0, 6, $D0, 3,  $C0|0, 5, $D0, 3,  $C0|0, 4, $D0, 3,  $C0|0, 3, $D0, 6, $FF
sfx_die:   .byte $C0|0, 12, $D0, 6, $C0|0, 16, $D1, 6, $C0|0, 22, $D2, 8, $C0|0, 30, $D4, 10, $C0|0, 40, $D7, 12, $FF

; ---------------------------------------------------------------- sprite directory (main RAM)
        .code
SPR_TABLE:
        .incbin "build/SPRTAB"
