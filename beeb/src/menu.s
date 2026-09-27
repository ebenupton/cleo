; ============================================================================
; CLEO - the menus: title, help, level select, win/lose.  Bank 6's menu overlay
; (MNUCODE/MNUBSS; the font and the tune in banks.s's MNUDATA), loaded from the disc
; over the tiles with the title pack into bank 5; what it calls in bank 7 goes through
; the XCALL stubs (engine.s)
; ============================================================================
        .segment "MNUCODE"      

MENU_START = 0                      ; title_menu's result (game.s)
MENU_HELP  = 1

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
        lda #<font_blank            ; '_' = erase: draw the all-zero glyph (A is dead:
        sta w16b                    ;  draw_glyph_rows starts with lda tx)
        lda #>font_blank
        sta w16b+1
        jsr draw_glyph_rows
        beq @space                  ; Z = 1: draw_glyph_rows returns from its cpx #8
:       jsr glyph_index
        jsr draw_glyph
@space: lda tx
        adc #7                      ; C = 1 on every way in: cmp #' ' equal, or the cpx #8
                                    ; draw_glyph_rows returns from
        sta tx
        ldy tchar
        iny
        bne @ch                     ; Y > 0: no string is 256 characters
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
:       cmp #'0'                    ; past '>' and '<' only '/', '.' and digits come here
        bcs :+
        eor #$33                    ; '/' -> 28, '.' -> 29
        rts
:       sbc #('0'-30)               ; C = 1 from the bcs: -'0'+30 in one subtraction
        rts

; draw glyph A at (tx, ty) : 8x8 px -> 4 chars x 2 char rows.  The font is in the
; overlay beside this code (font_art, banks.s), so the rows are read in place
; through w16b.
draw_glyph:
        stza w16b+1
        asl
        asl
        asl
        rol w16b+1                  ; C = 0: the byte it shifts out was 0
        adc #<font_art
        sta w16b
        lda w16b+1
        adc #>font_art
        sta w16b+1                  ; glyph rows
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
        adc #(<ROWBYTES) - 1        ; C = 1: cpx #4 found X = 4
        .assert (<ROWBYTES) <> 0, error, "the carry-in add needs a nonzero low byte"
        sta sp
        lda sp+1
        adc #>ROWBYTES
        ringup sp
        sta sp+1
:
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
font_blank: .res 8, 0               ; the erase glyph ('_' in a string)
pairtab: .byte $00, $33, $CC, $FF    ; logical 3 (yellow) on both dots of a game px

; ---------------------------------------------------------------- menu screen helpers
; clear the ring to black.  The bar is left alone: the menus' frame does not show it
; (menu_sections, engine.s)
  .if BHW
        .assert (<MIRR_A) = 0 && (<RINGEND_B) = 0, error, "the clear is whole pages"
clear_ring:
        lda #>MIRR_A                ; both mirrors and both rings: main RAM from $0800
        sta w16+1                   ; to the top ($8000), whole pages
        lda #0
        sta w16
        tay
@l:     sta (w16),y
        iny
        bne @l
        inc w16+1
        bpl @l                      ; RINGEND_B = $8000 (engine.s asserts it)
        rts
  .else
clear_ring:
        stz w16
        lda #>RINGBASE              ; buffer 0's ring, $3000 to the top (the bar is
        sta w16+1                   ; below it)
        ldy #0
        tya
@l:     sta (w16),y
        iny
        bne @l
        inc w16+1
        bpl @l                      ; to $8000: RINGEND (asserted below)
        .assert RINGEND = $8000, error, "clear_ring stops at $8000"
        rts
  .endif

; menu_begin: window at (0,0), buffer 0 as work buffer, cleared; screen blanked until
; menu_show has flipped the finished page in
menu_begin:
        jsr m_blank_palette
        jsr m_wait_flip               ; the game may still have a flip pending
  .if BHW
        sta wx                      ; A = 0: m_wait_flip spun until flipreq was 0
        sta wx+1
        sta wy
        sta wy+1
        sta wcx
        sta wcx+1
        sta wcy
        sta wfine
        sta curbuf
  .else
        stza wx
        stza wx+1
        stza wy
        stza wy+1
        stza wcx
        stza wcx+1
        stza wcy
        stza wfine
        stza curbuf
  .endif
        jsr m_select_backbuf
        jsr m_calc_ring
        jsr clear_ring
        lda #<menurec
        sta rp
        lda #>menurec
        sta rp+1
        rts

; menu_show: display buffer 0 (build sections, flip)
menu_show:
        stz curbuf                  ; (A is dead: build_sections loads it)
        jsr m_build_sections        ; bank 7's menu_sections (engine.s)
    .if .not BHW
        stz NEXTBUF                 ; (the Master: its handler's flip reads it)
    .endif
        stz NEXTSECT
        inc flipreq                 ; 0 -> 1: every way in has waited for it to clear
:       lda flipreq
        bne :-
        inc curbuf                  ; 0 -> 1: next game frame renders into the other buffer
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
        ldpbank ldx, BANK_MAP       ; the title pack is in the map's bank (the overlay
        stx spbank                  ; comes off the disc after the boot loader's
                                    ; patches, so the physical bank is read: PBANK)
        jsr m_drawsprite
        ldpbank lda, BANK_SPR
        sta spbank
        rts

; centred text: ptr -> string, X = y  (x = (160 - len*8)/2)
text_centred:
        ldy #$FF
:       iny
        lda (ptr),y
        bne :-
        tya
        asl
        asl                         ; len*4
        eor #$FF                    ; WINPX/2 - A, without parking A in memory
        adc #(WINPX/2)+1            ; C = 0 from the second asl: len < 64
        jmp drawtext

; ---------------------------------------------------------------- generic list menu
; menu_list: menuptr -> table of string pointers (word), A = count, X = first y,
; mstep = row step, mclear = clear the items' area first; returns A = selected index
menu_list:
        ldy menuptr                 ; the table's address into the two loads below: the
        sty @mt0+1                  ; overlay is in sideways RAM, so the pointer needs
        sty @mt1+1                  ; no zero page
        ldy menuptr+1
        sty @mt0+2
        sty @mt1+2
        sta mcount
        stx mtop
        stz msel
        lda #$FF
        sta lastkeys
        jsr clear_items
        ldx #0
@it:    stx tmp3
        txa
        asl
        tay
@mt0:   lda $FFFF,y                 ; (menuptr, patched in above)
        sta ptr
        iny
@mt1:   lda $FFFF,y
        sta ptr+1
        jsr item_y                  ; X = the index still: A = X = its y
        jsr text_centred
        ldx tmp3
        inx
        cpx mcount
        bne @it
        jsr @cursor                 ; A = 0 = msel: drawtext returns A = 0
        jsr menu_show
@loop:  jsr menu_keys
        sta tmp
        and #K_UP
        beq :+
        lda msel
        beq :+
        dec msel
        bpl @move                   ; always: msel < mcount <= 8
:       lda tmp
        and #K_DOWN
        beq :+
        ldx msel
        inx
        cpx mcount
        bcs :+
        stx msel
        bcc @move                   ; always: bcs not taken
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
        beq @loop                   ; always: drawtext returns Z = 1
@cursor:
        sta mlast
        ldx #<cursor_str
        ldy #>cursor_str
@curstr:
        stx ptr
        sty ptr+1
        tax
        jsr item_y
        lda #8
        jmp drawtext
item_y: lda mtop                    ; X = item index -> A = X = its y
        cpx #0
        beq :++
:       clc
        adc mstep
        dex
        bne :-
:       tax
        rts
cursor_str: .byte ">                 <", 0
blank_str:  .byte "_                 _", 0

; if mclear: clear the items' area below the logo, char row mtop/4 to the last (640
; bytes each, buffer 0's rows)
clear_items:
        lda mclear
        beq @done
        lda mtop
        lsr
        lsr
        tax
@r:     lda RINGLO,x
        sta w16
        lda RINGHI,x
        sta w16+1
        lda #0
        tay
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
  .if BHW
        cpx #RINGROWS               ; the ring is 23 slots here: the tables end there
  .else
        cpx #28
  .endif
        bne @r
@done:  rts

; ---------------------------------------------------------------- screens
; title menu: returns 0 start, 1 help, 2 exit
title_menu:
        lda MUSON
        bne :+
        jsr m_music_start             ; only if not already playing (back from help)
:       jsr menu_begin
        lda #40
        sta spx
        lda #4
        sta spy
        lda #TP_LOGO                ; = 0: both high bytes
        .assert TP_LOGO = 0, error, "title_menu: TP_LOGO doubles as the zero high bytes"
        sta spx+1
        sta spy+1
        jsr draw_piece
        lda #<menu1
        sta menuptr
        lda #>menu1
        sta menuptr+1
        lda #14
        sta mstep
        lda #1
        sta mclear
        asl                         ; A = 2 items
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
  .if BHW                        ; 84 px of window: i*10+16, the last line at 66
        tya                         ; Y = 2i (C=0 from the asl above)
        asl
        adc tmp3                    ; i*5
        adc #8
        asl                         ; (i*5+8)*2 = i*10+16
  .else
        tya                         ; Y = 2i = i*2 (C=0 from the asl above)
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
        and #(K_FIRE|K_RIGHT)
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
        pla                         ; max = n-1
        tax
        inx
        stx tmp                     ; n
        ; top y = (VISLINES/2 - 8 - (n-1)*12)/2, down to a multiple of 4
        asl
        asl
        sta tmp2
        asl
        adc tmp2                    ; (n-1)*12 (C=0: (n-1)*8 <= 56)
        eor #$FF
        adc #(VISLINES/2 - 8 + 1)   ; K - (n-1)*12 (C=0 from the adc)
        lsr
        and #$FC
        tax
        lda tmp
        jmp menu_list

; win/lose: A = 1 win, 0 lose; score and hi-score shown
winlose:
        sta mtop                    ; the win/lose flag (not tmp4: the sprite prologue
                                    ; uses it, and the lose screen cycled the WIN frames)
        jsr m_music_stop              ; the win/lose screen is silent
        jsr menu_begin
        .assert TP_WIN = TP_LOSE - 1, error, "winlose picks the piece as TP_LOSE - mtop"
  .if BHW
        lda #0
        sta spx+1
        sta spy+1
  .else
        stz spx+1
        stz spy+1
  .endif
        lda #4
        sta spy
        lda mtop                    ; 1 win, 0 lose
        asl                         ; (C = 0)
        adc #34                     ; YOU at 36 / 34
        sta spx
        lda #TP_YOU
        jsr draw_piece              ; (leaves spx, spx+1, spy, spy+1 alone)
        lda spx
        clc
        adc #80-34                  ; WIN at 82 / LOSE at 80; C = 0
        sta spx
        lda #TP_LOSE+1
        sbc mtop                    ; C = 0: TP_LOSE - mtop = TP_WIN / TP_LOSE
        jsr draw_piece
@scores:
        lda #<str_score
        sta ptr
        lda #>str_score
        sta ptr+1
  .if BHW
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
        sta mcount                  ; the frame last drawn  (menu_list's variables: this
        stz msel                    ; animation counter      screen runs no list, and
                                    ; tmp2/tmp3 do not survive menu_show's callees)
        lda #66                     ; big Cleo's place, once: nothing in the loop moves
        sta spx                     ; spx/spy (spx+1, spy+1 are 0 from the pieces above)
        lda #28
        sta spy
@loop:                              ; big Cleo's frame: the shift count is the same on
        lda msel                    ; both arms
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
        bne @drawc                  ; (always)
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
        jsr draw_piece
@same:  jsr menu_show
        inc msel
        jsr menu_keys
        and #(K_FIRE|K_RIGHT)
        beq @loop
        rts

; w16 >>= X
shr16x: txa                         ; Z from X (A dead at both callers)
        beq :++
:       lsr w16+1
        ror w16
        dex
        bne :-
:       rts
; w16b:w16 (24 bit) >>= X
shr24x: txa                         ; Z from X (A dead at the caller)
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
        ldy #4
@d:
        jsr m_div10_16
        ora #'0'                    ; A = the remainder (= q1); Y survives the call
        sta numbuf,y
        dey
        bpl @d
        ; suppress leading zeros (keep at least one)
:       iny                         ; (Y = $FF from the loop above)
        lda numbuf,y
        cmp #'0'
        bne :+
        lda #' '
        sta numbuf,y
        cpy #3
        bne :-
:       lda #'0'
        sta numbuf+5
        sta numbuf+6
        stz numbuf+7
        lda #<numbuf
        sta ptr
        lda #>numbuf
        sta ptr+1
        jmp drawtext+6              ; past its sta tx/stx ty: tx, ty hold A, X already

; ---------------------------------------------------------------- strings
menu1:      .word s_start, s_help
s_start:    .byte "START GAME", 0
s_help:     .byte "HELP", 0
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

        .segment "MNUBSS"
numbuf:    .res 8
menuptr:   .res 2                  ; menu_list's table (read through its own operands)
tchar:     .res 1                  ; drawtext's place in the string
mcount:    .res 1
mtop:      .res 1
mstep:     .res 1
msel:      .res 1
mclear:    .res 1
mlast:     .res 1                  ; item index the cursor was last drawn at
tx:        .res 1
ty:        .res 1
