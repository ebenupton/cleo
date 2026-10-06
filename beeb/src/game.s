; ============================================================================
; Cleo's game loop: the camera clamp, the level loop (the engine's hook_play),
; the frame loop pegged to the vsync, the end of a game, and the sound effects'
; data.  GAMECODE (bank 7, the game's image) on both machines, the same code for
; both; the sound effects go where the engine's sound_tick runs (PLACEH: the
; kernel on the Model B, main RAM on the Master).
;   clamp_window   wx into [0, maxwx] and even, wy into [0, maxwy] (game_frame)
;   level_loop     hook_play: load the level, set it up, run its frames (main.s)
;   sfx_tab        the sound effects by SFX_ id (logic.s), for sound_tick
; Labels the test harness holds to (test/harness.mjs and the tools on it):
; level_loop must start with its `ldx level` within 24 bytes; frame_top is the
; once-a-frame break; fl_wait is the idle spin the cycle counts leave out
; (test/linecyc.mjs).
; ============================================================================
        .segment "GAMECODE"
VSPEG     = 3                      ; vsyncs a rendered frame: 50/3 = 16.7 Hz of render

; ----------------------------------------------------------------------------
; clamp_window: the camera inside the map -- wx into [0, maxwx] and even, wy
;   into [0, maxwy]
;   In:    wx, wy (16-bit, signed: the camera's unclamped place), maxwx, maxwy
;   Out:   wx, wy clamped; wx even
;   Uses:  A X (both dead at the one caller: game_frame's setbank and tax
;          follow)
; The compares are 16-bit subtractions read by N (every value is under 32768);
; wx is even because the window moves by chars, two game pixels each
; (render_frame: wcx = wx >> 1).  One flow for both machines: the 6502 form
; costs the Master the same in range (7 cycles) and less on the clamps (17 for
; 22, 12 for 13).
; ----------------------------------------------------------------------------
clamp_window:
        lda wx+1
        bmi @wx0
        ldx wx                     ; X = wx for @wxok
        cpx maxwx                  ; (A = wx+1 still, from the bmi's load)
        sbc maxwx+1
        bmi @wxok                  ; wx < maxwx: in range
        lda maxwx+1
        sta wx+1
        lda maxwx
        bcs @wxev                  ; always: wx >= maxwx >= 0 left no borrow
@wx0:   ldx #0
        stx wx+1
@wxok:  txa                        ; A = wx, or 0 from @wx0
@wxev:  and #<~1                   ; wx &= ~1: even
        sta wx
        lda wy+1
        bmi @wy0
        ldx wy                     ; X dead: A keeps wy+1 for the sbc
        cpx maxwy
        sbc maxwy+1
        bmi @wyok                  ; wy < maxwy: in range
        lda maxwy
        sta wy
        lda maxwy+1
        sta wy+1
        rts
@wy0:   zero wy, wy+1
@wyok:  rts

; ----------------------------------------------------------------------------
; level_loop: hook_play -- a game's levels, from the one in `level` until the
;   lives or the levels run out
;   In:    level = the level index (0..NLEVELS-1: even a main level, odd its
;          bonus); score, lives, health set by the menus (new_game) and kept in
;          zero page across the image swap
;   Out:   does not return: go_menu with A = 0 lost or 1 won (game_over)
;   Uses:  everything
;   Pre:   the game's image in bank 7.  Jumped to by go_game's load with
;          interrupts off and the disc still open: the first load_level_b goes
;          straight on and ends by turning them on, so nothing before it may
;          wait on a vsync.
; The map's size, and the camera's range from it, are set here for the engine
; (mapw, maph, maxwx, maxwy, maplw); both buffers are rendered dark
; before the palette comes back, then the frame loop runs until the logic sets
; `exiting`.
; ----------------------------------------------------------------------------
level_loop:
        jsr blank_palette          ; dark for the load (the first time, it is already)
        ldx level                  ; (the harness patches this to ldx #n: keep it here)
        jsr load_level_b           ; the disc: the level into the banks (disc.s)
        ; ---- the map's size: mapw = TILEPX << lw, maph = TILEPX << lh
        lda #TILEPX
        sta mapw
        sta maph
        zero mapw+1, maph+1
        ldx LV_HDR+HDR_LW
        stx maplw
:       asl mapw
        rol mapw+1
        dex
        bne :-
        ldx LV_HDR+HDR_LH
:       asl maph
        rol maph+1
        dex
        bne :-
        ; ---- the camera's range: maxwx = mapw - WINPX, maxwy = maph - VISLINES/2
        lda mapw                   ; C = 0: the last rol shifted out maph's bit 15
        sbc #WINPX-1
        sta maxwx
        lda mapw+1
        sbc #0
        sta maxwx+1
        lda maph                   ; C = 1: mapw >= WINPX, no borrow
        sbc #VISLINES/2
        sta maxwy
        lda maph+1
        sbc #0
        sta maxwy+1
        ; ---- the engine's records and the level's state
        jsr lv_reset               ; the records (bank 7), the buffers' state (main RAM)
        sta nspr                   ; A = 0: lv_reset's last store
        jsr level_init
        sty bar_dirty              ; Y = 1 (level_init's exit): the digits on the first
                                    ; render (the bar's template is in place: bar_bg)
        ; ---- both buffers rendered before the palette comes back
        jsr game_frame
        jsr render_frame
        jsr game_frame
        jsr render_frame
        jsr set_palette
        lda vsyncs
        sta logicvs
; ---- fl_wait: nothing to do yet -- wait for the next vsync, then test the
;      peg.  The first frame starts here too: logicvs = vsyncs is never at the
;      peg.
fl_wait:
        lda vsyncs
:       cmp vsyncs
        beq :-
; ---- frame_loop: the peg.  A rendered frame every VSPEG vsyncs, and the logic
;      takes one step a frame, at twice the original's rates (logic.s
;      game_frame).  No catching up: time lost to a long frame is dropped, so
;      the window never moves more in a frame than one step asks for.
frame_loop:
        lda vsyncs
        sec
        sbc logicvs
        cmp #VSPEG
        bcc fl_wait
        lda vsyncs
        sta logicvs
; ---- frame_top: exactly once a rendered frame, before the step reads `keys`.
;      The test harness breaks here, so every wait and every input it applies
;      lands on a frame boundary (test/harness.mjs).
frame_top:
        jsr game_frame             ; (nspr is 0 here: render_frame and this loop's
                                    ;  lv_reset leave it so)
        lda exiting
        bne fl_over
        jsr render_frame
        jmp frame_loop
; ---- fl_over: the level is over -- the exit reached, or no lives left
fl_over:
        ldx lives
        beq game_over              ; X = 0: lost
  .if .not ALLLEVELS               ; (a test build plays every bonus level)
        lda stars                  ; stars left uncollected: skip the bonus level --
        beq @next1                 ;  level |= 1 (odd), then +1 is the next main level
        lsr level
        sec
        rol level
  .endif
@next1: inc level                  ; all collected: the next level, bonus or main
        lda level
        cmp #NLEVELS
        beq game_won
        lsr                        ; the main level reached: the chooser's reach
        cmp max_level
        bcc :+
        sta max_level
:       jmp level_loop

; ----------------------------------------------------------------------------
; game_won, game_over: the game has ended -- the hi-score, then the menus
;   In:    game_won: nothing; game_over: X = 0 (fl_over's lives)
;   Out:   does not return: go_menu with A = 0 lost, 1 won; hi_score =
;          max(hi_score, score)
;   Uses:  A X
; The scores are BCD, three bytes little-endian: a byte compare orders them as
; binary does.
; ----------------------------------------------------------------------------
game_won:
        ldx #1                     ; won
game_over:
        lda hi_score
        cmp score
        lda hi_score+1
        sbc score+1
        lda hi_score+2
        sbc score+2
        bcs :+                     ; hi_score >= score: stands
        mov16 hi_score, score
        lda score+2
        sta hi_score+2
:       jsr blank_palette          ; dark for the load (keeps X)
        txa                        ; A = 0 lost, 1 won
        jmp go_menu                ; the menus' image, then hook_over (disc.s)

; ---------------------------------------------------------------- the sound effects
        PLACEH "MRAMCODE", "KRNCODE"    ; with sound_tick: bank 7 on the Model B, main
                                        ; RAM on the Master (hardware: its interrupt)
; A sound effect (kernel.s sound_tick) is SFX steps, then SFX_END.  A step is
; SFXSTEP_LEN bytes: the chip's three bytes -- the channel's tone latch with the
; period's low 4 bits, the period's high 6 bits as a data byte, the channel's
; volume latch with the attenuation (hw.inc SN_*) -- and the frames to hold
; them.  sound_tick's end mark silences channel 2 and the noise channel, so
; every effect plays on SFX_CH or, the throw, on the noise channel (SN_NOISE,
; whose latch's low 3 bits pick the noise).  The data byte that follows a latch
; replaces the noise control on the noise channel, so there it repeats lo4 (a 0
; there turned the throw's white noise periodic).
.macro SFX ch, lo4, hi, att, dur
  .if ch = SN_NOISE
        .assert hi = 0, error, "SFX: a noise step has no period high bits"
        .byte SN_LATCH | (ch << SN_CHSHIFT) | lo4, lo4
  .else
        .byte SN_LATCH | (ch << SN_CHSHIFT) | lo4, hi
  .endif
        .byte SN_LATCH | SN_VOL | (ch << SN_CHSHIFT) | att, dur
.endmacro
SFX_CH = 2                         ; the effects' tone channel
sfx_tab:   .word sfx_jump, sfx_star, sfx_throw, sfx_hit, sfx_kill, sfx_power, sfx_die
sfx_jump:  SFX SFX_CH, 8, 12, 0, 2
           SFX SFX_CH, 4, 9, 2, 2
           SFX SFX_CH, 0, 7, 4, 2
           SFX SFX_CH, 8, 5, 6, 3
           .byte SFX_END
sfx_star:  SFX SFX_CH, 0, 4, 0, 2
           SFX SFX_CH, 0, 3, 0, 3
           SFX SFX_CH, 0, 3, 6, 3
           .byte SFX_END
sfx_throw: SFX SN_NOISE, SN_WHITE | 0, 0, 2, 2   ; white noise, the fastest rate,
           SFX SN_NOISE, SN_WHITE | 1, 0, 5, 3   ;  then the next, fading
           SFX SN_NOISE, SN_WHITE | 1, 0, 9, 3
           .byte SFX_END
sfx_hit:   SFX SFX_CH, 0, 40, 0, 4
           SFX SFX_CH, 0, 48, 2, 4
           SFX SFX_CH, 0, 60, 5, 5
           .byte SFX_END
sfx_kill:  SFX SFX_CH, 0, 6, 0, 2
           SFX SFX_CH, 0, 9, 1, 2
           SFX SFX_CH, 0, 12, 3, 3
           SFX SFX_CH, 0, 16, 6, 3
           .byte SFX_END
sfx_power: SFX SFX_CH, 0, 6, 0, 3
           SFX SFX_CH, 0, 5, 0, 3
           SFX SFX_CH, 0, 4, 0, 3
           SFX SFX_CH, 0, 3, 0, 6
           .byte SFX_END
sfx_die:   SFX SFX_CH, 0, 12, 0, 6
           SFX SFX_CH, 0, 16, 1, 6
           SFX SFX_CH, 0, 22, 2, 8
           SFX SFX_CH, 0, 30, 4, 10
           SFX SFX_CH, 0, 40, 7, 12
           .byte SFX_END
        .assert sfx_star - sfx_jump = 4*SFXSTEP_LEN + 1, error, "an sfx step is SFXSTEP_LEN bytes"
        .assert SFX_JUMP = 1 && SFX_DIE = 7, error, "sfx_tab is indexed by the 1-based SFX_ ids"
