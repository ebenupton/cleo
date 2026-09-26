; ============================================================================
; CLEO - the game: level loading, the camera clamp, the level and frame loops,
; the sound effects.  Shared by the Master (main.s) and the Model B
; (modelb/src/main.s); what differs between them is under MODELB.
; ============================================================================
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with the logic it drives
; ---------------------------------------------------------------- level loading
; X = level index 0..15 (even = main, odd = bonus)
load_level:
  .if MODELB
        jsr load_level_b            ; the disc: bank 7's loader (modelb/src/disc.s)
  .else
        ; file order is L0A, L0B, L1A, ..., two files each, and level index 0 is the
        ; main level, which is the 'B' one: file = FI_L0A + (i eor 1) * 2
        txa
        eor #1
        asl                         ; two pieces: map, bank-7 tables (C = 0: X < 128)
        adc #FI_L0A
        sta tmp2
        inca                        ; the tables first: unpack_map reads the header
        jsr loadfile
        lda tmp2                    ; the map piece, staged in screen RAM
        jsr loadfile
        jsr unpack_map              ; to bank 6: its head as it is, the map unpacked
        jsr load_tiles              ; the level's tiles, from the tile set's files, to bank 5
        ; geometry
        setbank BANK_LVL
  .endif
        lda #8                      ; mapw = 8 << lw ; maph = 8 << lh
        sta mapw
        sta maph
  .if MODELB
        lda #0
        sta mapw+1
        sta maph+1
  .else
        stz mapw+1
        stz maph+1
  .endif
        ldx LV_HDR
        stx maplw
:       asl mapw
        rol mapw+1
        dex
        bne :-
        ldx LV_HDR+1
        stx maplh
:       asl maph
        rol maph+1
        dex
        bne :-
        lda mapw                    ; C = 0: the last rol shifted out maph's bit 15
        sbc #WINPX-1
        sta maxwx
        lda mapw+1
        sbc #0
        sta maxwx+1
        lda maph                    ; C = 1: mapw >= WINPX
        sbc #VISLINES/2
        sta maxwy
        lda maph+1
        sbc #0
        sta maxwy+1
  .if MODELB
        jsr lvreset                 ; the records (bank 7) and the buffers' state (main RAM)
        sta NSPR                    ; A = 0: lvreset ends with a stz
  .else
        lda #$80                    ; both buffers invalid: an unreachable window x
        sta BUF_CX+1                ; (scroll_validate redraws them whole)
        sta BUF_CX+3
        stza RECCNT
        stza RECCNT+1
        stza DIRTYCNT
        stza DIRTYCNT+1
        stza NSPR
  .endif
        rts

  .if .not MODELB                   ; the disc: the Model B loads its four bank images
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
        FILE F_TILES0_SEC, F_TILES0_N, 0, SCREEN     ; the tile set: outdoor, shared (staged
        FILE F_TILES1_SEC, F_TILES1_N, 0, SCREEN     ; in screen RAM: load_tiles) ...
        FILE F_LOGIC_SEC, <((__LOGIC_LAST__ - __LOGIC_START__ + 255) / 256), BANK_LVL, LOGIC_ADDR
        FILE F_BOX_SEC,   F_BOX_N,   BANK_TIL1, BOX_BASE
        FILE F_MUSIC_SEC, F_MUSIC_N, BANK_LVL,  MUSIC_ADDR
        FILE F_ALT_SEC,   F_ALT_N,   BANK_LVL,  LV_ALTTAB
        FILE F_TITLE_SEC, F_TITLE_N, BANK_MAP,  TITLE_ADDR
        FILE F_L0A_SEC, LM_L0A, 0, SCREEN
        FILE F_L0A_SEC + LM_L0A, F_L0A_N - LM_L0A, BANK_LVL, LV_HDR
        FILE F_L0B_SEC, LM_L0B, 0, SCREEN
        FILE F_L0B_SEC + LM_L0B, F_L0B_N - LM_L0B, BANK_LVL, LV_HDR
        FILE F_L1A_SEC, LM_L1A, 0, SCREEN
        FILE F_L1A_SEC + LM_L1A, F_L1A_N - LM_L1A, BANK_LVL, LV_HDR
        FILE F_L1B_SEC, LM_L1B, 0, SCREEN
        FILE F_L1B_SEC + LM_L1B, F_L1B_N - LM_L1B, BANK_LVL, LV_HDR
        FILE F_L2A_SEC, LM_L2A, 0, SCREEN
        FILE F_L2A_SEC + LM_L2A, F_L2A_N - LM_L2A, BANK_LVL, LV_HDR
        FILE F_L2B_SEC, LM_L2B, 0, SCREEN
        FILE F_L2B_SEC + LM_L2B, F_L2B_N - LM_L2B, BANK_LVL, LV_HDR
        FILE F_L3A_SEC, LM_L3A, 0, SCREEN
        FILE F_L3A_SEC + LM_L3A, F_L3A_N - LM_L3A, BANK_LVL, LV_HDR
        FILE F_L3B_SEC, LM_L3B, 0, SCREEN
        FILE F_L3B_SEC + LM_L3B, F_L3B_N - LM_L3B, BANK_LVL, LV_HDR
        FILE F_L4A_SEC, LM_L4A, 0, SCREEN
        FILE F_L4A_SEC + LM_L4A, F_L4A_N - LM_L4A, BANK_LVL, LV_HDR
        FILE F_L4B_SEC, LM_L4B, 0, SCREEN
        FILE F_L4B_SEC + LM_L4B, F_L4B_N - LM_L4B, BANK_LVL, LV_HDR
        FILE F_L5A_SEC, LM_L5A, 0, SCREEN
        FILE F_L5A_SEC + LM_L5A, F_L5A_N - LM_L5A, BANK_LVL, LV_HDR
        FILE F_L5B_SEC, LM_L5B, 0, SCREEN
        FILE F_L5B_SEC + LM_L5B, F_L5B_N - LM_L5B, BANK_LVL, LV_HDR
        FILE F_L6A_SEC, LM_L6A, 0, SCREEN
        FILE F_L6A_SEC + LM_L6A, F_L6A_N - LM_L6A, BANK_LVL, LV_HDR
        FILE F_L6B_SEC, LM_L6B, 0, SCREEN
        FILE F_L6B_SEC + LM_L6B, F_L6B_N - LM_L6B, BANK_LVL, LV_HDR
        FILE F_L7A_SEC, LM_L7A, 0, SCREEN
        FILE F_L7A_SEC + LM_L7A, F_L7A_N - LM_L7A, BANK_LVL, LV_HDR
        FILE F_L7B_SEC, LM_L7B, 0, SCREEN
        FILE F_L7B_SEC + LM_L7B, F_L7B_N - LM_L7B, BANK_LVL, LV_HDR
        FILE F_SPRAND_SEC, F_SPRAND_N, BANK_SPR|$80, $8000   ; -> ANDY (ROMSEL bit7)
        FILE F_TABLES_SEC, F_TABLES_N, 0, $0400             ; main RAM: bank 0 selects none
        FILE F_TILES2_SEC, F_TILES2_N, 0, SCREEN     ; ... and indoor
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
FI_TILES0 = 1                     ; the tile set's files (convert.py TSET)
FI_TILES1 = 2
FI_LOGIC = 3
FI_BOX = 4
FI_MUSIC = 5
FI_ALT = 6
FI_TITLE = 7
FI_L0A = 8                        ; two pieces per level: map, bank-7 tables
FI_SPRAND = 40
FI_TABLES = 41
FI_TILES2 = 42

  .endif

; ---------------------------------------------------------------- camera clamp
; clamp wx to [0, maxwx] (and even), wy to [0, maxwy]
clamp_window:
        lda wx+1
        bmi @wx0
        lda wx
        cmp maxwx
        lda wx+1
        sbc maxwx+1
        bmi @wxok
  .if MODELB
        lda maxwx+1
        sta wx+1
        lda maxwx
        bcs @wxev                   ; C = 1: wx >= maxwx >= 0, no borrow
@wx0:   lda #0
        sta wx+1
        beq @wxev                   ; A = 0
@wxok:  lda wx
@wxev:  and #$FE
        sta wx
  .else
        lda maxwx
        sta wx
        lda maxwx+1
        sta wx+1
        bra @wxok
@wx0:   stz wx
        stz wx+1
@wxok:
        lda #1
        trb wx                      ; wx &= ~1 : the 65C02 does this in one RMW
  .endif
        lda wy+1
        bmi @wy0
        lda wy
        cmp maxwy
        lda wy+1
        sbc maxwy+1
        bmi @wyok
        lda maxwy
        sta wy
        lda maxwy+1
        sta wy+1
        rts
  .if MODELB
@wy0:   lda #0                      ; A dead: the caller's setbank reloads it
        sta wy
        sta wy+1
  .else
@wy0:   stza wy
        stza wy+1
  .endif
@wyok:  rts

; ---------------------------------------------------------------- game
game_main:
  .if MODELB
        lda #0                      ; A dead: ensure_menu loads title_res first
        sta hiscore
        sta hiscore+1
        sta maxlevel
        sta title_res
  .else
        stza hiscore
        stza hiscore+1
        stza maxlevel
        stza title_res
  .endif
title_loop:
  .if MODELB
        jsr ensure_menu             ; the menus are bank 5's overlay: in place first
  .endif
        jsr t_title_menu
        cmp #MENU_HELP
        bne new_game
        jsr t_help_screen
        bra title_loop
new_game:
        stz level
  .if MODELB
        sta score                   ; A = 0 (the stz)
        sta score+1
  .else
        stz score
        stz score+1
  .endif
        lda #3
        sta lives
        sta health
        lda maxlevel
        beq level_loop
        jsr t_level_select
        asl
        sta level
level_loop:
        jsr blank_palette           ; hide the loading and the first-frame build-up
  .if .not MODELB
        jsr load_begin              ; and stop the chain at a frame boundary (engine.s;
  .endif                            ; the Model B's loader does it itself)
        stz title_res               ; the level's map replaces the title pack
  .if .not MODELB
        lda #FI_BOX                  ; and the title pack replaced the box stars
        jsr loadfile
  .endif
        ldx level
        jsr load_level
  .if .not MODELB
        jsr load_end                ; the next vsync starts the chain again (the Model
  .endif                            ; B's loader does this itself, before its cli)
        jsr t_level_init
        lda #1                      ; the digits on the first render (the bar's template is
        sta BARDIRTY                ; in place already: bar_bg)
        ; initial camera; render both buffers before the palette comes back
        jsr t_game_frame
        jsr render_frame

        jsr t_game_frame
        jsr render_frame
        jsr set_palette

        lda vsyncs
        sta logicvs

frame_loop:
        ; The peg is three vsyncs -- 16.7Hz of render -- and the logic takes two
        ; steps for each one, so the player, every animation and every enemy move
        ; twice as far per frame as they used to.  Two steps is a fixed pairing,
        ; not catching up: time lost to a long frame is still dropped, so the
        ; window never moves more in a frame than these two steps ask for.
        lda vsyncs
        sec
        sbc logicvs
        cmp #VSPEG
        bcc fl_wait
        lda vsyncs
        sta logicvs
frame_top:                          ; exactly once per rendered frame, before the two
                                    ; logic steps read 'keys': the test harness breaks
                                    ; here so every wait and every input it applies is
                                    ; quantised to a frame boundary (tools/harness.mjs)
        jsr t_game_frame            ; (NSPR is 0 here: render_frame and load_level clear it)
        lda exiting
        bne fl_over
        sta NSPR                    ; A = 0: exiting, just tested
        jsr t_game_frame
        lda exiting
        bne fl_over
        jsr render_frame
        bra frame_loop
fl_wait:  ; nothing to do yet: wait for the next vsync
        lda vsyncs
:       cmp vsyncs
        beq :-
        bne frame_loop              ; Z = 0: the vsync ticked
fl_over:
        ; level over
        ldx lives                   ; (X = lives: the Master's winlose flag below)
        beq game_over
        lda stars
        beq @next1
        lda level
        ora #1                      ; a star: on to the next odd level (+2 from even)
        sta level
@next1: inc level
        lda level
        cmp #16
        beq game_won
        lsr
        cmp maxlevel
        bcc :+
        sta maxlevel
:       jmp level_loop
  .if MODELB
game_over:
        jsr update_hiscore
        jsr ensure_menu
        lda #0
        jsr t_winlose
        jmp title_loop
game_won:
        jsr update_hiscore
        jsr ensure_menu
        lda #1
        jsr t_winlose
        jmp title_loop
  .else
game_over:                          ; X = lives: 0 lost, else won (winlose tests its flag
game_won:                           ; only for zero; update_hiscore keeps X)
        jsr update_hiscore
        txa
        jsr t_winlose
        jmp title_loop
  .endif
  .if MODELB
; the menu overlay and the title pack, unless they are still in (menu.s's load_title
; does the same from inside the overlay, for the screens reached from the title)
ensure_menu:
        lda title_res
        bne :+
        jsr blank_palette
        jsr load_title_b
        inc title_res
:       rts
  .endif
update_hiscore:
        lda hiscore
        cmp score
        lda hiscore+1
        sbc score+1
        bcs :+
        mov16 hiscore, score
:       rts

; ---------------------------------------------------------------- sound data
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with sound_tick
; sfx steps: byte0 = channel/period latch ($80 | ch<<5 | lo4), byte1 = period hi (data byte), byte2 = volume ($90|ch<<5|att), duration
sfxtab: .word sfx_jump, sfx_star, sfx_throw, sfx_hit, sfx_kill, sfx_power, sfx_die
sfx_jump:  .byte $C0|8, 12, $D0, 2,  $C0|4, 9, $D2, 2,  $C0|0, 7, $D4, 2,  $C0|8, 5, $D6, 3, $FF
sfx_star:  .byte $C0|0, 4, $D0, 2,  $C0|0, 3, $D0, 3,  $C0|0, 3, $D6, 3, $FF
sfx_throw: .byte $E0|4, 0, $F2, 2,  $E0|5, 0, $F5, 3,  $E0|5, 0, $F9, 3, $FF
sfx_hit:   .byte $C0|0, 40, $D0, 4, $C0|0, 48, $D2, 4, $C0|0, 60, $D5, 5, $FF
sfx_kill:  .byte $C0|0, 6, $D0, 2,  $C0|0, 9, $D1, 2,  $C0|0, 12, $D3, 3, $C0|0, 16, $D6, 3, $FF
sfx_power: .byte $C0|0, 6, $D0, 3,  $C0|0, 5, $D0, 3,  $C0|0, 4, $D0, 3,  $C0|0, 3, $D0, 6, $FF
sfx_die:   .byte $C0|0, 12, $D0, 6, $C0|0, 16, $D1, 6, $C0|0, 22, $D2, 8, $C0|0, 30, $D4, 10, $C0|0, 40, $D7, 12, $FF

