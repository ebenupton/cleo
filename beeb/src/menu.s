; ============================================================================
; CLEO - menus, title, help, level select, win/lose, pause  (HAZEL segment)
; ============================================================================
        .segment "HAZEL"

MENU_START = 0
MENU_HELP  = 1
MENU_EXIT  = 2

; ---------------------------------------------------------------- text
; drawtext: ptr -> 0-terminated string, A = x (px, even), X = y (px, multiple of 4)
drawtext:
        sta tx
        stx ty
        setbank BANK_SPR
        ldy #0
@ch:    lda (ptr),y
        beq @done
        phy
        cmp #' '
        beq @space
        jsr glyph_index
        jsr draw_glyph
@space: lda tx
        clc
        adc #8
        sta tx
        ply
        iny
        bra @ch
@done:  rts

; A = ascii -> A = glyph index (0..39)
glyph_index:
        cmp #'A'
        bcc @notalpha
        cmp #'Z'+1
        bcs @notalpha
        sec
        sbc #'A'
        rts
@notalpha:
        cmp #'>'
        bne :+
        lda #26
        rts
:       cmp #'<'
        bne :+
        lda #27
        rts
:       cmp #'/'
        bne :+
        lda #28
        rts
:       cmp #'.'
        bne :+
        lda #29
        rts
:       sec
        sbc #'0'
        clc
        adc #30
        rts

; draw glyph A at (tx, ty) : 8x8 px -> 4 chars x 2 char rows
draw_glyph:
        stz w16b+1
        asl
        asl
        asl
        rol w16b+1
        clc
        adc #<SPR_FONT
        sta w16b
        lda w16b+1
        adc #>SPR_FONT
        sta w16b+1                  ; glyph rows
        lda tx
        lsr
        sta w16
        stz w16+1
        lda ty
        lsr
        lsr
        jsr ringaddr                ; sp = first char (row 0)
        ldx #0                      ; glyph row 0..7
@row:   cpx #4
        bne :+
        lda sp                      ; second char row: +640
        clc
        adc #<640
        sta sp
        lda sp+1
        adc #>640
        bpl :+
        sec
        sbc #$50
:       sta sp+1
        txa
        tay
        lda (w16b),y
        sta tmp                     ; row bits
        txa
        asl
        and #7
        sta tmp2                    ; ra
        lda sp
        sta tp
        lda sp+1
        sta tp+1                    ; remember row start
        lda #4
        sta tmp4
@pair:  lda tmp
        rol
        rol
        rol
        and #3
        tay
        lda pairtab,y
        ldy tmp2
        sta (sp),y
        iny
        sta (sp),y
        asl tmp
        asl tmp
        spnext
        dec tmp4
        bne @pair
        lda tp
        sta sp
        lda tp+1
        sta sp+1
        inx
        cpx #8
        bne @row
        rts
pairtab: .byte $00, $05, $0A, $0F

; ---------------------------------------------------------------- menu screen helpers
; clear the current back buffer ring ($3000-$7FFF) to black
clear_ring:
        stz w16
        lda #$30
        sta w16+1
        ldx #$50
        ldy #0
        tya
@l:     sta (w16),y
        iny
        bne @l
        inc w16+1
        dex
        bne @l
        rts

; menu_begin: window at (0,0), buffer 0 as work buffer, cleared
menu_begin:
        stz wx
        stz wx+1
        stz wy
        stz wy+1
        stz wcx
        stz wcx+1
        stz wcy
        stz wfine
        stz curbuf
        jsr select_backbuf
        jsr calc_ring
        jsr clear_ring
        lda #<menurec
        sta rp
        lda #>menurec
        sta rp+1
        lda #1
        sta BARDIRTY
        sta BARDIRTY+1
        rts

; menu_show: display buffer 0 (build sections, flip)
menu_show:
        stz curbuf
        jsr build_sections
        stz NEXTBUF
        stz NEXTSECT
        lda #1
        sta flipreq
:       lda flipreq
        bne :-
        lda #1
        sta curbuf                  ; next game frame renders into the other buffer
        rts

; wait one vsync and return new key edges in A (keys pressed now but not last time)
menu_keys:
        lda vsyncs
:       cmp vsyncs
        beq :-
        lda keys
        tax
        eor lastkeys
        and keys
        stx lastkeys
        rts

; draw a title piece: A = piece index, spx/spy = position (top-left)
draw_piece:
        pha
        lda #BANK_LVL
        sta spbank
        pla
        jsr drawsprite
        lda #BANK_SPR
        sta spbank
        rts

; centred text: ptr -> string, X = y  (x = (160 - len*8)/2)
text_centred:
        ldy #0
:       lda (ptr),y
        beq :+
        iny
        bra :-
:       tya
        asl
        asl
        asl                         ; len*8
        sta tmp
        lda #160
        sec
        sbc tmp
        lsr
        and #$FE
        jmp drawtext

; ---------------------------------------------------------------- generic list menu
; menu_list: menuptr -> table of string pointers (word), A = count, X = first y, tmp4 = row step
; returns A = selected index
menu_list:
        sta mcount
        stx mtop
        stz msel
        lda #$FF
        sta lastkeys
@redraw:
        jsr clear_items
        ; items
        ldx #0
@it:    stx tmp3
        txa
        asl
        tay
        lda (menuptr),y
        sta ptr
        iny
        lda (menuptr),y
        sta ptr+1
        lda tmp3
        jsr item_y
        tax
        jsr text_centred
        ldx tmp3
        inx
        cpx mcount
        bne @it
        ; cursor
        lda msel
        jsr item_y
        tax
        lda #<cursor_str
        sta ptr
        lda #>cursor_str
        sta ptr+1
        lda #8
        jsr drawtext
        jsr menu_show
@loop:  jsr menu_keys
        sta tmp
        and #K_UP
        beq :+
        lda msel
        beq :+
        dec msel
        bra @redraw
:       lda tmp
        and #K_DOWN
        beq :+
        lda msel
        inc
        cmp mcount
        bcs :+
        sta msel
        bra @redraw
:       lda tmp
        and #(K_FIRE|K_RIGHT)
        beq @loop
        lda msel
        rts
item_y: sta tmp2
        lda mtop
        ldx tmp2
        beq :++
:       clc
        adc mstep
        dex
        bne :-
:       rts
cursor_str: .byte ">                 <", 0

; clear the item area rows (below the logo): rows from mtop to bottom -> just clear everything below y=36
clear_items:
        lda mclear
        beq @done
        ; clear ring rows (mtop/4) .. 27 : 640 bytes each
        lda mtop
        lsr
        lsr
        tax
@r:     lda RINGLO,x
        sta w16
        lda RINGHI,x
        sta w16+1
        ldy #0
        lda #0
:       sta (w16),y
        iny
        bne :-
        inc w16+1
:       sta (w16),y
        iny
        bne :-
        inc w16+1
        ldy #0
:       sta (w16),y
        iny
        cpy #128
        bne :-
        inx
        cpx #28
        bne @r
@done:  rts

; ---------------------------------------------------------------- screens
; title menu: returns 0 start, 1 help, 2 exit
title_menu:
        lda #FI_TITLE
        jsr loadfile
        jsr music_start
        jsr menu_begin
        mov16i spx, 40
        mov16i spy, 4
        lda #TP_LOGO
        jsr draw_piece
        lda #<menu1
        sta menuptr
        lda #>menu1
        sta menuptr+1
        lda #14
        sta mstep
        lda #1
        sta mclear
        lda #3
        ldx #48
        jmp menu_list

help_screen:
        jsr menu_begin
        ldx #0
@l:     stx tmp3
        txa
        asl
        tay
        lda helptab,y
        sta ptr
        lda helptab+1,y
        sta ptr+1
        lda tmp3
        asl
        asl
        sta tmp
        asl
        clc
        adc tmp                     ; i*12
        adc #20
        tax
        jsr text_centred
        ldx tmp3
        inx
        cpx #6
        bne @l
        jsr menu_show
        lda #$FF
        sta lastkeys
:       jsr menu_keys
        and #(K_FIRE|K_RIGHT|K_MENU)
        beq :-
        rts

; level select: A = max level index (0..7) -> returns chosen level (0..max)
level_select:
        pha
        jsr menu_begin
        lda #<levelnames
        sta menuptr
        lda #>levelnames
        sta menuptr+1
        lda #12
        sta mstep
        lda #1
        sta mclear
        pla
        inc
        sta tmp
        ; top y = (108 - (n-1)*12 - 8)/2 rounded to multiple of 4
        dec
        asl
        asl
        sta tmp2
        asl
        clc
        adc tmp2                    ; (n-1)*12
        sta tmp2
        lda #100
        sec
        sbc tmp2
        lsr
        and #$FC
        tax
        lda tmp
        jmp menu_list

; pause menu: returns 0 resume, 1 exit
pause_menu:
        jsr menu_begin
        lda #<menu2
        sta menuptr
        lda #>menu2
        sta menuptr+1
        lda #14
        sta mstep
        stz mclear
        lda #2
        ldx #40
        jsr menu_list
        pha
        ; invalidate game buffers
        stz BUF_VALID
        stz BUF_VALID+1
        stz RECCNT
        stz RECCNT+1
        lda #1
        sta BARDIRTY
        sta BARDIRTY+1
        pla
        rts

; win/lose: A = 1 win, 0 lose ; score/hiscore shown
winlose:
        sta tmp4
        lda #FI_TITLE
        jsr loadfile
        jsr music_start
        jsr menu_begin
        lda tmp4
        beq @lose
        mov16i spx, 36
        mov16i spy, 4
        lda #TP_YOU
        jsr draw_piece
        mov16i spx, 82
        mov16i spy, 4
        lda #TP_WIN
        jsr draw_piece
        bra @scores
@lose:  mov16i spx, 34
        mov16i spy, 4
        lda #TP_YOU
        jsr draw_piece
        mov16i spx, 80
        mov16i spy, 4
        lda #TP_LOSE
        jsr draw_piece
@scores:
        lda #<str_score
        sta ptr
        lda #>str_score
        sta ptr+1
        lda #12
        ldx #84
        jsr drawtext
        mov16 t16, score
        lda #68
        ldx #84
        jsr draw_number
        lda #<str_hiscore
        sta ptr
        lda #>str_hiscore
        sta ptr+1
        lda #12
        ldx #96
        jsr drawtext
        mov16 t16, hiscore
        lda #84
        ldx #96
        jsr draw_number
        lda #$FF
        sta lastkeys
        stz tmp3                    ; animation counter
        lda #$FF
        sta tmp2                    ; last drawn frame
@loop:  ; big cleo frame
        lda tmp4
        beq @lframe
        ; win: 4 + ((441 >> (n & 30)) & 3)
        lda tmp3
        and #30
        tax
        lda #<441
        sta w16
        lda #>441
        sta w16+1
        jsr shr16x
        lda w16
        and #3
        clc
        adc #4
        bra @drawc
@lframe:
        lda tmp3
        and #30
        tax
        lda #$79
        sta w16
        lda #$9E
        sta w16+1
        lda #$E7
        sta w16b
        jsr shr24x
        lda w16
        and #3
@drawc: clc
        adc #TP_CLEO0
        cmp tmp2
        beq @same
        sta tmp2
        mov16i spx, 66
        mov16i spy, 28
        lda tmp2
        jsr draw_piece              ; frames are opaque: no clearing needed
@same:  jsr menu_show
        inc tmp3
        jsr menu_keys
        and #(K_FIRE|K_RIGHT)
        bne :+
        jmp @loop
:       rts

; w16 >>= X
shr16x: cpx #0
        beq :++
:       lsr w16+1
        ror w16
        dex
        bne :-
:       rts
; w16b:w16 (24 bit) >>= X
shr24x: cpx #0
        beq :++
:       lsr w16b
        ror w16+1
        ror w16
        dex
        bne :-
:       rts

; draw_number: t16 = value, prints value*100 as digits at (A = x, X = y) : up to 6 digits + "00"
draw_number:
        sta tx
        stx ty
        ; convert t16 to decimal (5 digits, leading zeros suppressed) into numbuf
        ldx #4
@d:     phx
        jsr div10_16
        plx
        lda q1
        clc
        adc #'0'
        sta numbuf,x
        dex
        bpl @d
        ; suppress leading zeros (keep at least one)
        ldx #0
:       lda numbuf,x
        cmp #'0'
        bne :+
        lda #' '
        sta numbuf,x
        inx
        cpx #4
        bne :-
:       lda #'0'
        sta numbuf+5
        sta numbuf+6
        stz numbuf+7
        lda #<numbuf
        sta ptr
        lda #>numbuf
        sta ptr+1
        lda tx
        ldx ty
        jmp drawtext

; ---------------------------------------------------------------- strings
menu1:      .word s_start, s_help, s_exit
menu2:      .word s_resume, s_exit
s_start:    .byte "START GAME", 0
s_help:     .byte "HELP", 0
s_exit:     .byte "EXIT", 0
s_resume:   .byte "RESUME GAME", 0
helptab:    .word h1, h2, h3, h4, h5, h6
h1:         .byte "Z X TO RUN", 0
h2:         .byte "RETURN TO JUMP", 0
h3:         .byte "SLASH TO THROW", 0
h4:         .byte "COLLECT ALL", 0
h5:         .byte "STARS TO OPEN", 0
h6:         .byte "BONUS LEVEL", 0
levelnames: .word l0, l1, l2, l3, l4, l5, l6, l7
l0:         .byte "CITY GATES", 0
l1:         .byte "CHEOPS", 0
l2:         .byte "VINEYARDS", 0
l3:         .byte "CHEFREN", 0
l4:         .byte "CITADELS", 0
l5:         .byte "TUTANKHAMUN", 0
l6:         .byte "ALEXANDRIA", 0
l7:         .byte "NEFERTITI", 0
str_score:  .byte "SCORE", 0
str_hiscore:.byte "HISCORE", 0

        .zeropage
menuptr:   .res 2
spbank:    .res 1
        .segment "TABLES"
menurec:   .res 10
numbuf:    .res 8
mcount:    .res 1
mtop:      .res 1
mstep:     .res 1
msel:      .res 1
mclear:    .res 1
tx:        .res 1
ty:        .res 1
