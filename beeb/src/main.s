; ============================================================================
; CLEO - main program: init, loading, game
; ============================================================================
        .setcpu "65C02"
        .code
        jmp start
        .import __MAIN_LAST__
        .include "engine.s"
        .include "logic.s"
        .include "menu.s"

        .code
; ---------------------------------------------------------------- entry
start:
        sei
        ; NMI handler: jump to ours (1770 DRQ/INTRQ driven sector transfer)
        lda #$4C
        sta $0D00
        lda #<nmi_handler
        sta $0D01
        lda #>nmi_handler
        sta $0D02
        ; page HAZEL in and copy the logic overlay there (before MODE 2 clears the screen area)
        lda ACCCON
        ora #$08
        sta ACCCON
        lda #<__MAIN_LAST__
        sta ptr
        lda #>__MAIN_LAST__
        sta ptr+1
        stz w16
        lda #$C0
        sta w16+1
        ldx #$20
@hz:    ldy #0
:       lda (ptr),y
        sta (w16),y
        iny
        bne :-
        inc ptr+1
        inc w16+1
        dex
        bne @hz
        lda ACCCON
        and #$F7
        sta ACCCON
        cli
        lda #22
        jsr OSWRCH
        lda #2
        jsr OSWRCH
        sei
        lda ACCCON
        ora #$08
        sta ACCCON
        jsr init_tables
        jsr blank_palette
        jsr disc_init
        lda #FI_SPR
        jsr loadfile
        lda #FI_TIL0
        jsr loadfile
        lda #FI_TIL1
        jsr loadfile
        lda #FI_ALT
        jsr loadfile
        lda #FI_MUSIC
        jsr loadfile
        lda #$34
        sta seed
        lda #$12
        sta seed+1
        jsr crtc_init
        stz wx
        stz wx+1
        stz wy
        stz wy+1
        stz wcx
        stz wcx+1
        stz wcy
        stz wfine
        stz curbuf
        jsr calc_ring
        jsr build_sections
        inc curbuf
        jsr build_sections
        stz curbuf
        stz DISPSECT
        jsr take_over
        jsr set_palette
        jmp game_main

; ---------------------------------------------------------------- level loading
; X = level index 0..15 (even = main, odd = bonus)
load_level:
        txa
        clc
        adc #FI_L0B                 ; file order: L0A, L0B, L1A, ... but index 0 = main = 'B'
        ; level index i: file = FI_L0A + (i>>1)*2 + (1 - (i&1))
        txa
        eor #1
        clc
        adc #FI_L0A
        jsr loadfile
        ; geometry
        setbank BANK_LVL
        lda LV_HDR
        sta maplw
        lda LV_HDR+1
        sta maplh
        ; mapw = 8 << lw ; maph = 8 << lh
        lda #8
        sta mapw
        stz mapw+1
        ldx maplw
:       asl mapw
        rol mapw+1
        dex
        bne :-
        lda #8
        sta maph
        stz maph+1
        ldx maplh
:       asl maph
        rol maph+1
        dex
        bne :-
        lda mapw
        sec
        sbc #160
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
        stz BUF_VALID
        stz BUF_VALID+1
        stz RECCNT
        stz RECCNT+1
        stz DIRTYCNT
        stz DIRTYCNT+1
        stz NSPR
        rts

; file table: sector lo, hi, nsectors, bank, dest hi
        .include "files.inc"
.macro FILE sec, n, bank, dest
        .byte <(sec), >(sec), n, bank, >(dest)
.endmacro
filetab:
        FILE F_SPR_SEC,   F_SPR_N,   BANK_SPR,  $8000
        FILE F_TIL0_SEC,  F_TIL0_N,  BANK_TIL0, $8000
        FILE F_TIL1_SEC,  F_TIL1_N,  BANK_TIL1, $8000
        FILE F_ALT_SEC,   F_ALT_N,   BANK_LVL,  LV_ALTCLS
        FILE F_TITLE_SEC, F_TITLE_N, BANK_LVL,  $8000
        FILE F_MUSIC_SEC, F_MUSIC_N, BANK_TIL1, MUSIC_DATA
        FILE F_L0A_SEC, F_L0A_N, BANK_LVL, $8000
        FILE F_L0B_SEC, F_L0B_N, BANK_LVL, $8000
        FILE F_L1A_SEC, F_L1A_N, BANK_LVL, $8000
        FILE F_L1B_SEC, F_L1B_N, BANK_LVL, $8000
        FILE F_L2A_SEC, F_L2A_N, BANK_LVL, $8000
        FILE F_L2B_SEC, F_L2B_N, BANK_LVL, $8000
        FILE F_L3A_SEC, F_L3A_N, BANK_LVL, $8000
        FILE F_L3B_SEC, F_L3B_N, BANK_LVL, $8000
        FILE F_L4A_SEC, F_L4A_N, BANK_LVL, $8000
        FILE F_L4B_SEC, F_L4B_N, BANK_LVL, $8000
        FILE F_L5A_SEC, F_L5A_N, BANK_LVL, $8000
        FILE F_L5B_SEC, F_L5B_N, BANK_LVL, $8000
        FILE F_L6A_SEC, F_L6A_N, BANK_LVL, $8000
        FILE F_L6B_SEC, F_L6B_N, BANK_LVL, $8000
        FILE F_L7A_SEC, F_L7A_N, BANK_LVL, $8000
        FILE F_L7B_SEC, F_L7B_N, BANK_LVL, $8000
FI_SPR = 0
FI_TIL0 = 1
FI_TIL1 = 2
FI_ALT = 3
FI_TITLE = 4
FI_MUSIC = 5
FI_L0A = 6
FI_L0B = 7

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
@wy0:   stz wy
        stz wy+1
@wyok:  rts

; ---------------------------------------------------------------- game
game_main:
        stz hiscore
        stz hiscore+1
        stz maxlevel
title_loop:
        jsr title_menu
        cmp #MENU_HELP
        bne :+
        jsr help_screen
        bra title_loop
:       cmp #MENU_EXIT
        bne new_game
        jmp ($FFFC)
new_game:
        stz level
        lda #3
        sta lives
        sta health
        stz score
        stz score+1
        lda maxlevel
        beq level_loop
        jsr level_select
        asl
        sta level
level_loop:
        ldx level
        jsr load_level
        jsr level_init
        jsr draw_lives
        jsr draw_health
        jsr draw_stars
        jsr draw_score
        ; initial camera + full draw
        jsr game_frame
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
        jsr pause_menu
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
:       ; fixed 25Hz logic: run one step per 2 vsyncs elapsed (max 3), render once
        lda vsyncs
        sec
        sbc logicvs
        lsr
        beq @wait
        cmp #3
        bcc :+
        lda #3
:       sta lsteps
        asl
        clc
        adc logicvs
        sta logicvs
@steps: stz NSPR
        jsr game_frame
        lda exiting
        bne @over
        dec lsteps
        bne @steps
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
        jsr winlose
        jmp title_loop
game_won:
        jsr update_hiscore
        lda #1
        jsr winlose
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
