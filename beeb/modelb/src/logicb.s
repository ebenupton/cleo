; ============================================================================
; The game, such as it is on this target: Cleo, the level's objects, a camera
; and the scroll validation that keeps the ring honest.  Bank 7.
; ============================================================================
K_LEFT  = 1
K_RIGHT = 2
K_UP    = 4
K_FIRE  = 16
VIA_ORB   = $FE40
VIA_DDRA  = $FE43
VIA_ORANH = $FE4F

        .segment "LGCCODE"
scan_keys:
        lda #$7F
        sta VIA_DDRA
        lda #3
        sta VIA_ORB                 ; autoscan off: the matrix is read directly
        lda #0
        sta tmp
        ldx #6
@k:     lda keytab,x
        sta VIA_ORANH
        lda VIA_ORANH
        bpl :+
        lda keybits,x
        ora tmp                     ; no tsb on a 6502
        sta tmp
:       dex
        bpl @k
        lda tmp
        sta keys
        rts
keytab:  .byte $61,$19, $42,$79, $48,$39,$49
keybits: .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE

; ---------------------------------------------------------------- the player
; px, py are the J2ME anchor in game pixels, which is what the level's spawn, the
; object coordinates and every sprite's reference point are in: her feet are FEET
; pixels below it (the Master samples the ground at py+16 for the same reason, and
; every one of her frames has its reference 15 pixels above its bottom row).
; vy is 1/256 px a step, as on the Master.
FEET    = 16
player_step:
        jsr scan_keys
        lda #0                      ; horizontal: a step is two pixels, and the
        sta dx                      ; original's acceleration is not missed here
        lda keys
        and #K_LEFT
        beq :+
        lda #$FE
        sta dx
        lda #1
        sta facing
:       lda keys
        and #K_RIGHT
        beq :+
        lda #2
        sta dx
        lda #0
        sta facing
:       lda keys                    ; jump, if there is ground under her
        and #K_UP
        beq @nojump
        lda onground
        beq @nojump
        lda #0
        sta vy
        lda #>(-1280)
        sta vy+1
        lda #0
        sta onground
@nojump:
        ; ---- gravity: vy = (vy + 80) * 31/32
        lda vy
        clc
        adc #80
        sta vy
        lda vy+1
        adc #0
        sta vy+1
        sec                         ; t16 = -vy
        lda #0
        sbc vy
        sta t16
        lda #0
        sbc vy+1
        .repeat 5                   ; >> 5, arithmetic
        cmp #$80
        ror a
        ror t16
        .endrepeat
        sta t16+1
        lda vy                      ; vy += -vy/32
        clc
        adc t16
        sta vy
        lda vy+1
        adc t16+1
        sta vy+1
        ; ---- dy = (vy + 128) >> 8, clamped when falling
        lda vy
        clc
        adc #128
        lda vy+1
        adc #0
        sta dy
        bpl :+
        cmp #$F8                    ; rising faster than 8 px a step is fine
        bcs :+
        lda #$F8
        sta dy
:       lda dy
        cmp #MAXDWY+1
        bcc :+
        bmi :+
        lda #MAXDWY
        sta dy
:
        ; ---- horizontal: a step up of four pixels or less is walkable, more is a wall
        lda dx
        beq @novx
        clc
        adc px
        sta w16b
        lda px+1
        adc #0
        bne @novx                   ; off either edge: the map is 256 px wide, and
        sta w16b+1                  ; ground_at only ever looks at the low byte
        lda py                      ; her feet, and a look from eight pixels above
        clc                         ; them, so a step up is found as well as the floor
        adc #FEET
        sta t16
        sec
        sbc #8
        sta ga_py
        lda w16b
        jsr ground_at
        lda tmp4
        cmp #255
        beq @movex                  ; nothing there: walk off the edge
        clc
        adc #4                      ; surface + 4 < her feet: it rises too steeply
        cmp t16
        bcc @novx
@movex: lda w16b
        sta px
        lda w16b+1
        sta px+1
        lda onground                ; on the ground, follow the surface
        beq @novx
        lda tmp4
        cmp #255
        beq @novx
        sec
        sbc #FEET                   ; the anchor is FEET above where her feet land
        sta py
        lda #0
        sta py+1
@novx:
        ; ---- the floor under her, before she moves down it
        lda py
        clc
        adc #FEET
        sta ga_py
        lda px
        jsr ground_at
        lda tmp4
        sta floor
        ; ---- vertical move
        lda dy
        beq @noy
        bmi @up
        clc
        adc py
        sta py
        lda py+1
        adc #0
        sta py+1
        bra @noy
@up:    clc
        adc py
        sta py
        lda py+1
        adc #$FF
        sta py+1
@noy:   lda py                      ; where her feet are after the move
        clc
        adc #FEET
        sta t16
        bcs @air                    ; below the map: nothing to land on
        lda floor
        cmp #255
        beq @air
        cmp t16                     ; her feet have reached the floor
        beq @landit
        bcc @landit
        lda #0                      ; still above it
        sta onground
        bra @anim
@landit: sec
        sbc #FEET
        sta py
        lda #0
        sta py+1
        sta vy
        sta vy+1
        lda #1
        sta onground
        bra @anim
@air:   lda #0
        sta onground
@anim:  inc anim
        rts

; ground_at: A = x in map pixels -> tmp4 = the surface y at or below her feet in
; that pixel column, or 255 if there is none within two tiles.
ground_at:
        sta ga_x
        lsr
        lsr
        lsr
        sta ga_tx
        lda ga_py
        lsr
        lsr
        lsr
        sta ga_ty
        ldx #0
        stx ga_k
@try:   lda ga_ty
        clc
        adc ga_k
        cmp #MAPH
        bcs @none
        sta tmp2                    ; map_strip wants the tile in tmp/tmp2
        sta ga_row
        lda ga_tx
        sta tmp
        lda #1
        sta cnt
        farjsr F_MAPSTRIP
        lda MAPBUF
        sta tmp2                    ; the tile id, for its altitude class
        farjsr F_ALTROW
        lda ga_x
        and #7
        tay
        lda MAPBUF,y
        lsr
        lsr
        lsr
        lsr
        cmp #8
        bcs @next                   ; no ground in this pixel column
        sta tmp4
        lda ga_row
        asl
        asl
        asl
        clc
        adc tmp4
        sta tmp4                    ; surface = tile row * 8 + the altitude
        cmp ga_py
        bcc @next                   ; above the starting point: look further down
        rts
@next:  inc ga_k
        lda ga_k
        cmp #3
        bne @try
@none:  lda #255
        sta tmp4
        rts

; ---------------------------------------------------------------- camera
camera:
        lda px                      ; wx = clamp(px - 80, 0, MAPW*8 - 160)
        sec
        sbc #80
        sta wx
        lda px+1
        sbc #0
        sta wx+1
        bpl :+
        lda #0
        sta wx
        sta wx+1
:       lda wx+1
        cmp #>(MAPW*8-160)
        bcc :++
        bne :+
        lda wx
        cmp #<(MAPW*8-160)
        bcc :++
:       lda #<(MAPW*8-160)
        sta wx
        lda #>(MAPW*8-160)
        sta wx+1
:       lda py                      ; wy = clamp(py - 42, 0, MAPH*8 - VISROWS*4)
        sec
        sbc #42
        sta wy
        lda py+1
        sbc #0
        sta wy+1
        bpl :+
        lda #0
        sta wy
        sta wy+1
:       lda wy+1
        cmp #>(MAPH*8-VISROWS*4)
        bcc :++
        bne :+
        lda wy
        cmp #<(MAPH*8-VISROWS*4)
        bcc :++
:       lda #<(MAPH*8-VISROWS*4)
        sta wy
        lda #>(MAPH*8-VISROWS*4)
        sta wy+1
:       lda wx+1                    ; wcx = wx >> 1 (a char is two game pixels)
        lsr
        sta wcx+1
        lda wx
        ror
        sta wcx
        lda wy                      ; wfine = (wy & 3) * 2
        and #3
        asl
        sta wfine
        lda wy+1                    ; wcy = wy >> 2 (a char row is four)
        lsr
        sta tmp
        lda wy
        ror
        lsr tmp
        ror
        sta wcy
        rts

; ---------------------------------------------------------------- scrolling
; The ring holds the window's rows wherever the map says they go, so what a move
; costs is the strip that has just come into view.
; scroll_validate: make every char of the window valid in this buffer, redrawing
; only what the window has moved over since this buffer was last drawn.  The window
; is 80 chars by BUFROWS char rows, and what is tracked per buffer is its char
; origin: a move of one char needs new chars in either axis, whatever the tiles do.
scroll_validate:
        jmp @sv
@tofull:jmp @full                   ; within reach of the tests below
@sv:    ldx curbuf
        lda bvalid,x
        bne @inc
        lda #1                      ; this buffer has never been drawn
        sta bvalid,x
        jmp @full
@inc:   lda wcy                     ; ---- vertical, in char rows
        sec
        sbc bpty,x
        beq @dx
        bmi @up
        cmp #BUFROWS
        bcs @tofull
        sta dt_ncy                  ; new rows are bpty+BUFROWS .. wcy+BUFROWS-1
        lda bpty,x
        clc
        adc #BUFROWS
        sta dt_cy
        bra @vdraw
@up:    eor #$FF
        clc
        adc #1                      ; new rows are wcy .. bpty-1
        cmp #BUFROWS
        bcs @tofull
        sta dt_ncy
        lda wcy
        sta dt_cy
@vdraw: lda wcx
        sta dt_cx
        lda #ROWCHARS
        sta dt_ncx
        farjsr F_DRAWRECT
@dx:    ldx curbuf
        lda wcx                     ; ---- horizontal, in chars
        sec
        sbc bptx,x
        beq @save
        bmi @left
        cmp #ROWCHARS
        bcs @tofull2
        sta dt_ncx                  ; new chars are bptx+80 .. wcx+79
        lda bptx,x
        clc
        adc #ROWCHARS
        sta dt_cx
        bra @hdraw
@left:  eor #$FF
        clc
        adc #1                      ; new chars are wcx .. bptx-1
        cmp #ROWCHARS
        bcs @tofull2
        sta dt_ncx
        lda wcx
        sta dt_cx
@hdraw: lda wcy
        sta dt_cy
        lda #BUFROWS
        sta dt_ncy
        farjsr F_DRAWRECT
        bra @save
@tofull2:                           ; in reach of the horizontal tests above
@full:  lda wcx
        sta dt_cx
        lda #ROWCHARS
        sta dt_ncx
        lda wcy
        sta dt_cy
        lda #BUFROWS
        sta dt_ncy
        farjsr F_DRAWRECT
@save:  ldx curbuf
        lda wcx
        sta bptx,x
        lda wcy
        sta bpty,x
        rts

; ---------------------------------------------------------------- sprites
; the level's objects, copied out of bank 6 once, then drawn where they stand
fetch_objs:
        lda #0
        sta tmp3
@l:     lda #<LV_OBJS
        clc
        adc tmp3
        sta w16b
        lda #>LV_OBJS
        adc #0
        sta w16b+1
        lda #40
        sta cnt
        farjsr F_MAPCOPY
        ldy #0
:       lda MAPBUF,y
        sty tmp4
        ldx tmp3
        sta OBJS,x
        inc tmp3
        ldy tmp4
        iny
        cpy #40
        bne :-
        lda tmp3
        cmp #NOBJS*6
        bcc @l
        rts

queue_sprites:
        lda #0                      ; the objects first, so Cleo is drawn over them
        sta tmp3
@o:     ldx tmp3
        lda OBJS,x                  ; type
        cmp #2
        bcs @next                   ; only stars and trampolines are drawn here
        jsr @pos
        jsr @onscreen               ; queueing what cannot be seen costs an erase
        bcc @next                   ; rectangle a frame, which is most of the budget
        ldx tmp3
        lda OBJS,x
        cmp #0
        bne @notstar
        lda anim                    ; the star spins
        lsr
        lsr
        and #3
        clc
        adc #34
        bra @add
@notstar:
        lda #43                     ; a trampoline
@add:   farjsr F_ADDSPR
@next:  lda tmp3
        clc
        adc #6
        sta tmp3
        cmp #NOBJS*6
        bcc @o
        ; ---- Cleo
        lda px
        sta spx
        lda px+1
        sta spx+1
        lda py
        sta spy
        lda py+1
        sta spy+1
        lda onground
        beq @jump
        lda dx
        beq @stand
        lda anim                    ; a four frame run
        lsr
        lsr
        and #3
        asl
        clc
        adc #0
        bra @face
@stand: lda #8
        bra @face
@jump:  lda #16
@face:  clc
        adc facing
        farjsr F_ADDSPR
        rts
; C = 1 if spx/spy is close enough to the window to be worth drawing
@onscreen:
        lda spx+1
        bne @off                    ; past 255: this map is 256 pixels wide
        lda spx
        sec
        sbc wx
        bcc @off                    ; left of the window
        cmp #160+24
        bcs @off
        lda spy+1
        bne @off
        lda spy
        sec
        sbc wy
        bcc @off
        cmp #VISROWS*4+24
        bcs @off
        sec
        rts
@off:   clc
        rts

@pos:   ldx tmp3                    ; the object's tile position, in pixels
        lda OBJS+1,x
        sta tmp4
        lda #0
        sta spx+1
        lda tmp4
        asl
        rol spx+1
        asl
        rol spx+1
        asl
        rol spx+1
        sta spx
        ldx tmp3
        lda OBJS+2,x
        sta tmp4
        lda #0
        sta spy+1
        lda tmp4
        asl
        rol spy+1
        asl
        rol spy+1
        asl
        rol spy+1
        sta spy
        rts

        .segment "LGCBSS"
OBJS:     .res NOBJS*6 + 40
bptx:     .res 2                    ; per buffer: the tile window its ring holds
bpty:     .res 2
bvalid:   .res 2
