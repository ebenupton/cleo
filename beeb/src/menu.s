; ============================================================================
; CLEO - menus, title, help, level select, win/lose, pause  (LOGIC segment: bank 7;
; Model B: bank 5's menu overlay, MNUCODE, loaded over the tiles for the menus)
; ============================================================================
        PLACE "LOGIC", "MNUCODE"

MENU_START = 0
MENU_HELP  = 1
MENU_EXIT  = 2

; ---------------------------------------------------------------- text
; drawtext: ptr -> 0-terminated string, A = x (px, even), X = y (px, multiple of 4)
drawtext:
        sta tx
        stx ty
        ldy #0
@ch:    lda (ptr),y
        beq @done
        sty tchar                   ; not phy: on a 6502 that is tya/pha, and the
        cmp #' '                    ; character is in A
        beq @space
        cmp #'_'
        bne :+
        stz GLYPHBUF+0              ; '_' = erase: draw an all-zero glyph
        stz GLYPHBUF+1
        stz GLYPHBUF+2
        stz GLYPHBUF+3
        stz GLYPHBUF+4
        stz GLYPHBUF+5
        stz GLYPHBUF+6
        stz GLYPHBUF+7
        jsr draw_glyph_rows
        bra @space
:       jsr glyph_index
        jsr draw_glyph
@space: lda tx
        clc
        adc #8
        sta tx
        ldy tchar
        iny
        bra @ch
@done:  rts

; A = ascii -> A = glyph index (0..39)
glyph_index:
        cmp #'A'
        bcc @notalpha
        cmp #'Z'+1
        bcs @notalpha
        sbc #('A'-1)                ; bcs not taken, so C = 0: subtracts 'A'-1+1 = 'A'
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
        sbc #('0'-30)               ; -'0'+30 folded into one subtraction
        rts

; draw glyph A at (tx, ty) : 8x8 px -> 4 chars x 2 char rows
draw_glyph:
        stza w16b+1
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
        jsr getglyph                ; main RAM: the font is in bank 4, this code in 7
draw_glyph_rows:
        lda tx
        lsr
        sta w16
        stz w16+1
        lda ty
        lsr
        lsr
        jsr m_ringaddr                ; sp = first char (row 0)
        ldx #0                      ; glyph row 0..7
@row:   cpx #4
        bne :++                     ; past the fold's own anonymous label
        lda sp                      ; second char row: one row on
        clc
        adc #<ROWBYTES
        sta sp
        lda sp+1
        adc #>ROWBYTES
        ringup sp
        sta sp+1
:
        lda GLYPHBUF,x
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
@pair:  lda #0                      ; shift the top two bits of tmp straight out of it
        asl tmp
        rol
        asl tmp
        rol
        tay
        lda pairtab,y
        ldy tmp2
        sta (sp),y
        iny
        sta (sp),y
        spnext
        dec tmp4
        bne @pair
        lda tp
        sta sp
        lda tp+1
        sta sp+1
        inx
        cpx #8
        beq :+
        jmp @row                    ; (the 6502 spellings put @row out of a branch's reach)
:       rts
  .if MODE1
pairtab: .byte $00, $33, $CC, $FF    ; logical 3 (yellow) on both dots of a game px
  .else
pairtab: .byte $00, $05, $0A, $0F
  .endif

; ---------------------------------------------------------------- menu screen helpers
; clear the current back buffer ring ($3000-$7FFF) to black
  .if MODELB
; Model B: the bar, both mirrors and both rings: all of main RAM from $0300
        .assert (<BARADDR) = 0 && (<RINGEND_B) = 0, error, "the clear is whole pages"
clear_ring:
        lda #>BARADDR               ; the bar, both mirrors and both rings: main RAM
        ldx #(>RINGEND_B - >BARADDR) ; from $0300 to the top, whole pages
        sta w16+1
        lda #0
        sta w16
        tay
@l:     sta (w16),y
        iny
        bne @l
        inc w16+1
        dex
        bne @l
        rts
  .else
clear_ring:
        stz w16
        lda #>BARADDR               ; from the bar, not the ring base: the bar sits below
        sta w16+1                   ; $3000 now and the menu still wants it black
        ldx #((RINGEND - BARADDR) >> 8)
        ldy #0
        tya
@l:     sta (w16),y
        iny
        bne @l
        inc w16+1
        dex
        bne @l
        rts
  .endif

; load the title pack into bank 6 unless it is still there (a level load replaces it);
; the palette goes black first so neither the disc load nor the screen build-up shows
load_title:
        jsr m_blank_palette
        lda title_res
        bne :+
  .if .not MODELB
        lda #FI_TITLE
  .endif
        jsr m_loadfile              ; (Model B: the overlay and the pack, disc.s)
        inc title_res
:       rts

; menu_begin: window at (0,0), buffer 0 as work buffer, cleared; screen blanked until
; menu_show has flipped the finished page in
menu_begin:
        jsr m_blank_palette
        jsr m_wait_flip               ; the game may still have a flip pending
        stza wx
        stza wx+1
        stza wy
        stza wy+1
        stza wcx
        stza wcx+1
        stza wcy
        stza wfine
        stza curbuf
        jsr m_select_backbuf
        jsr m_calc_ring
        jsr clear_ring
        lda #<menurec
        sta rp
        lda #>menurec
        sta rp+1
        lda #1
        sta BARDIRTY
        rts

; menu_show: display buffer 0 (build sections, flip)
menu_show:
        stza curbuf
  .if MODELB
        jsr m_build_sections        ; bank 7's
  .else
        jsr build_sections          ; both are in the bank now
        stz NEXTBUF
  .endif
        stz NEXTSECT
        lda #1
        sta flipreq
:       lda flipreq
        bne :-
        lda #1
        sta curbuf                  ; next game frame renders into the other buffer
        jmp m_set_palette             ; page is on display: colours back

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
        ldpbank lda, BANK_MAP       ; the title pack sits where the map goes (the
        sta spbank                  ; overlay comes off the disc: the loader cannot
        pla                         ; patch it, so the physical bank is read)
        jsr m_drawsprite
        ldpbank lda, BANK_SPR
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
        asl                         ; len*4
        eor #$FF                    ; WINPX/2 - A, without parking A in memory
        sec
        adc #(WINPX/2)
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
        lda msel
        jsr @cursor
        jsr menu_show
@loop:  jsr menu_keys
        sta tmp
        and #K_UP
        beq :+
        lda msel
        beq :+
        dec msel
        bra @move
:       lda tmp
        and #K_DOWN
        beq :+
        lda msel
        inca
        cmp mcount
        bcs :+
        sta msel
        bra @move
:       lda tmp
        and #(K_FIRE|K_RIGHT)
        beq @loop
        lda msel
        rts
        ; cursor moved: the buffer is on display, so touch only the cursor rows (right after
        ; the vsync menu_keys waited for) rather than clearing and redrawing every item
@move:  lda mlast
        ldx #<blank_str
        ldy #>blank_str
        jsr @curstr
        lda msel
        jsr @cursor
        bra @loop
@cursor:
        sta mlast
        ldx #<cursor_str
        ldy #>cursor_str
@curstr:
        stx ptr
        sty ptr+1
        jsr item_y
        tax
        lda #8
        jmp drawtext
item_y: tax
        lda mtop
        cpx #0
        beq :++
:       clc
        adc mstep
        dex
        bne :-
:       rts
cursor_str: .byte ">                 <", 0
blank_str:  .byte "_                 _", 0

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
        ldy #127
:       sta (w16),y
        dey
        bpl :-
        inx
  .if MODELB
        cpx #RINGROWS               ; the ring is 23 slots here: the tables end there
  .else
        cpx #28
  .endif
        bne @r
@done:  rts

; ---------------------------------------------------------------- screens
; title menu: returns 0 start, 1 help, 2 exit
title_menu:
        jsr load_title
        lda MUSON
        bne :+
        jsr m_music_start             ; only if not already playing (back from help)
:       jsr menu_begin
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
        lda #2
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
  .if MODELB                        ; 84 px of window: i*10+16, the last line at 66
        lda tmp3
        asl
        asl
        adc tmp3                    ; i*5
        adc #8
        asl                         ; (i*5+8)*2 = i*10+16
  .else
        lda tmp3
        asl
        adc tmp3                    ; i*3
        adc #5                      ; i*3+5
        asl
        asl                         ; (i*3+5)*4 = i*12+20
  .endif
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
        inca
        sta tmp
        ; top y = (108 - (n-1)*12 - 8)/2 rounded to multiple of 4
        deca
        asl
        asl
        sta tmp2
        asl
        clc
        adc tmp2                    ; (n-1)*12
        sta tmp2
        lda #(VISLINES/2 - 8)       ; (108 on the Master, 84 here)
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
        pla
        rts

; win/lose: A = 1 win, 0 lose ; score/hiscore shown
winlose:
        sta mtop                    ; the win/lose flag (tmp4 is the sprite prologue's
        jsr load_title              ; mask page: after the first draw the lose screen
                                    ; was cycling the WIN frames)
        jsr m_music_stop              ; the win/lose screen is silent
        jsr menu_begin
        lda mtop
        beq @lose
        mov16i spx, 36
        lda #4
        sta spy
        stz spy+1
        lda #TP_YOU
        jsr draw_piece
        lda #82
        sta spx
        stz spx+1
        lda #4
        sta spy
        stz spy+1
        lda #TP_WIN
        jsr draw_piece
        bra @scores
@lose:  lda #34
        sta spx
        stz spx+1
        lda #4
        sta spy
        stz spy+1
        lda #TP_YOU
        jsr draw_piece
        lda #80
        sta spx
        stz spx+1
        lda #4
        sta spy
        stz spy+1
        lda #TP_LOSE
        jsr draw_piece
@scores:
        lda #<str_score
        sta ptr
        lda #>str_score
        sta ptr+1
  .if MODELB
SCORE_Y = 64                        ; 84 px of window: under big Cleo (28..59)
HISCORE_Y = 76                      ; (a glyph row is a multiple of 4)
  .else
SCORE_Y = 84
HISCORE_Y = 96
  .endif
        lda #12
        ldx #SCORE_Y
        jsr drawtext
        mov16 t16, score
        lda #84                     ; align the score column with the hi-score below
        ldx #SCORE_Y
        jsr draw_number
        lda #<str_hiscore
        sta ptr
        lda #>str_hiscore
        sta ptr+1
        lda #12
        ldx #HISCORE_Y
        jsr drawtext
        mov16 t16, hiscore
        lda #84
        ldx #HISCORE_Y
        jsr draw_number
        lda #$FF
        sta lastkeys
        sta mcount                  ; last drawn frame   (menu_list's variables: this
        stz msel                    ; animation counter   screen never runs a list, and
@loop:  ; big cleo frame            ; tmp2/tmp3 are clobbered by menu_show's callees
        lda msel                    ; every pass, which froze big Cleo on one frame)
                                    ; the shift count is the same on both arms
        and #30
        tax
        lda mtop
        beq @lframe
        ; win: 4 + ((441 >> (n & 30)) & 3)
        lda #<441
        sta w16
        lda #>441
        sta w16+1
        jsr shr16x
        lda w16
        and #3
        ora #4
        bra @drawc
@lframe:
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
        cmp mcount
        beq @same
        sta mcount
        lda #66
        sta spx
        stz spx+1
        lda #28
        sta spy
        stz spy+1
        lda mcount
        jsr draw_piece
@same:  jsr menu_show
        inc msel
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
  .if MODELB
        jsr m_div10_16
  .else
        jsr div10_16
  .endif
        plx
        lda q1
        ora #'0'
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
menu1:      .word s_start, s_help
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

  .if .not MODELB                   ; (Model B: menuptr is in defs.inc, spbank and
        .zeropage                   ;  menurec in bank 5 with the prologue, title_res
menuptr:   .res 2                   ;  in low RAM)
spbank:    .res 1
        .segment "TABLES"
menurec:   .res 10
  .else
        .segment "MNUBSS"
  .endif
numbuf:    .res 8
mcount:    .res 1
mtop:      .res 1
mstep:     .res 1
msel:      .res 1
mclear:    .res 1
mlast:     .res 1                  ; item index the cursor was last drawn at
  .if .not MODELB
title_res: .res 1                  ; title pack resident in bank 6
  .endif
tx:        .res 1
ty:        .res 1
