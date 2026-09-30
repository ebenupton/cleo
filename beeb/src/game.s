; ============================================================================
; CLEO - the game: level loading, the camera clamp, the level and frame loops,
; the sound effects.  Bank 7 on both machines; what differs between them is
; under BHW (the Model B's hardware).
; ============================================================================
        .segment "GAMECODE"         ; bank 7, with the logic it drives
VSPEG     = 3                       ; vsyncs a rendered frame: 16.7 Hz of render
; ---------------------------------------------------------------- level loading
; X = level index 0..15 (even = main, odd = bonus)
load_level:
        jsr load_level_b            ; the disc: everything into the banks (disc.s)
        lda #8                      ; mapw = 8 << lw ; maph = 8 << lh
        sta mapw
        sta maph
  .if BHW
        lda #0
        sta mapw+1
        sta maph+1
  .else
        stz mapw+1
        stz maph+1
  .endif
        ldx LV_HDR+HDR_LW
        stx maplw
:       asl mapw
        rol mapw+1
        dex
        bne :-
        ldx LV_HDR+HDR_LH
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
        jsr lvreset                 ; the records (bank 7) and the buffers' state (main RAM)
        sta NSPR                    ; A = 0: lvreset ends with a stz
        rts


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
  .if BHW
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
        jmp @wxok
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
  .if BHW
@wy0:   lda #0                      ; A dead: the caller's setbank reloads it
        sta wy
        sta wy+1
  .else
@wy0:   stz wy
        stz wy+1
  .endif
@wyok:  rts

; ---------------------------------------------------------------- game
; The game's image comes in at level_loop (disc.s go_game, from the menus' image,
; which has set level, score, lives and health), and goes back to the menus' when the
; game ends (go_menu).
level_loop:
        jsr blank_palette           ; hide the loading and the first-frame build-up
        ldx level
        jsr load_level
        jsr level_init
        lda #1                      ; the digits on the first render (the bar's template is
        sta BARDIRTY                ; in place already: bar_bg)
        ; initial camera; render both buffers before the palette comes back
        jsr game_frame
        jsr render_frame

        jsr game_frame
        jsr render_frame
        jsr set_palette

        lda vsyncs
        sta logicvs

frame_loop:
        ; The peg is three vsyncs -- 16.7Hz of render -- and the logic takes two
        ; steps for each one, so the player, every animation and every enemy move
        ; two of the original's steps per rendered frame.  Two steps is a fixed
        ; pairing, not catching up: time lost to a long frame is dropped, so the
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
                                    ; quantised to a frame boundary (test/harness.mjs)
        jsr game_frame            ; (NSPR is 0 here: render_frame and load_level clear it)
        lda exiting
        bne fl_over
        sta NSPR                    ; A = 0: exiting, just tested
        jsr game_frame
        lda exiting
        bne fl_over
        jsr render_frame
        jmp frame_loop
fl_wait:  ; nothing to do yet: wait for the next vsync
        lda vsyncs
:       cmp vsyncs
        beq :-
        bne frame_loop              ; Z = 0: the vsync ticked
fl_over:
        ; level over
        ldx lives
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
game_over:
        lda #0                      ; lost
        .byte $2C                   ; (bit abs: skips the lda #1)
game_won:
        lda #1
        pha
        jsr update_hiscore
        pla
        jmp go_menu                 ; the menus' image, and its win/lose screen (disc.s)
update_hiscore:
        lda hiscore
        cmp score
        lda hiscore+1
        sbc score+1
        bcs :+
        mov16 hiscore, score
:       rts

; ---------------------------------------------------------------- sound data
        PLACEH "CODE", "KRNCODE"    ; with sound_tick: bank 7 on the Model B, main RAM on the Master
; sfx steps: byte0 = channel/period latch ($80 | ch<<5 | lo4), byte1 = period hi (data byte), byte2 = volume ($90|ch<<5|att), duration
sfxtab: .word sfx_jump, sfx_star, sfx_throw, sfx_hit, sfx_kill, sfx_power, sfx_die
sfx_jump:  .byte $C0|8, 12, $D0, 2,  $C0|4, 9, $D2, 2,  $C0|0, 7, $D4, 2,  $C0|8, 5, $D6, 3, $FF
sfx_star:  .byte $C0|0, 4, $D0, 2,  $C0|0, 3, $D0, 3,  $C0|0, 3, $D6, 3, $FF
sfx_throw: .byte $E0|4, 0, $F2, 2,  $E0|5, 0, $F5, 3,  $E0|5, 0, $F9, 3, $FF
sfx_hit:   .byte $C0|0, 40, $D0, 4, $C0|0, 48, $D2, 4, $C0|0, 60, $D5, 5, $FF
sfx_kill:  .byte $C0|0, 6, $D0, 2,  $C0|0, 9, $D1, 2,  $C0|0, 12, $D3, 3, $C0|0, 16, $D6, 3, $FF
sfx_power: .byte $C0|0, 6, $D0, 3,  $C0|0, 5, $D0, 3,  $C0|0, 4, $D0, 3,  $C0|0, 3, $D0, 6, $FF
sfx_die:   .byte $C0|0, 12, $D0, 6, $C0|0, 16, $D1, 6, $C0|0, 22, $D2, 8, $C0|0, 30, $D4, 10, $C0|0, 40, $D7, 12, $FF

