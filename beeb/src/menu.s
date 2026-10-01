; ============================================================================
; CLEO - the menus: title, help, level select, win/lose, and the top of the game
; loop.  The menus' image of bank 7 (MNUCODE/MNUBSS; the font, the tune and the title
; pieces in banks.s's MNUDATA), which the game's image replaces for play and which
; replaces it again after (disc.s go_game, go_menu).  What they call in bank 7 is the
; kernel's, which neither image covers: a plain call.
; ============================================================================
        .segment "MNUCODE"      

MENU_START = 0                      ; title_menu's result
MENU_HELP  = 1

; ---------------------------------------------------------------- the game loop's top
; start-up comes here (disc.s go_title), and the game's image comes back to menu_over when a game ends (A = 0 lost, 1 won), with the stack
; reset: every way out of here is go_game.
game_main:
        lda #$34                    ; rnd's seed
        sta seed
        lda #$12
        sta seed+1
  .if BHW
        lda #0
        sta hiscore
        sta hiscore+1
        sta maxlevel
  .else
        stz hiscore
        stz hiscore+1
        stz maxlevel
  .endif
  .if ALLLEVELS
        lda #7                      ; (a test build: every main level on the chooser)
        sta maxlevel
  .endif
title_loop:
        jsr title_menu
        cmp #MENU_HELP
        bne new_game
        jsr help_screen
        jmp title_loop
new_game:
        stz level
  .if BHW
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
        beq :+
        jsr level_select
        asl
        sta level
:       pha                         ; (A: go_game's)
        jsr blank_palette           ; the load is dark: the menu's screen is overwritten
        pla
        jmp go_game                 ; the game's image, and its level loop (disc.s)
menu_over:
        jsr winlose
        jmp title_loop

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
        clc                         ; (ringaddr7 adds the carry in: ty's bit 1 is out)
        jsr ringaddr7               ; sp = first char (row 0)
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
        .assert <CLEAR0 = 0, error, "the clear is whole pages"
clear_ring:
        lda #>CLEAR0                ; to the top ($8000), whole pages: the Model B's
        sta w16+1                   ; mirrors and rings, the Master's buffer 0 ring
        lda #0                      ; (the bar is below either)
        sta w16
        tay
@l:     sta (w16),y
        iny
        bne @l
        inc w16+1
        bpl @l                      ; to $8000 (engine.s asserts the ring ends)
        rts

; menu_begin: window at (0,0), buffer 0 as work buffer, cleared; screen blanked until
; menu_show has flipped the finished page in
menu_begin:
        jsr blank_palette
:       lda flipreq                 ; the game may still have a flip pending
        bne :-
        sta wx                      ; A = 0: flipreq was
        sta wx+1
        sta wy
        sta wy+1
        sta wcx
        sta wcx+1
        sta wcy
        sta wfine
        sta curbuf
        jsr selbb                   ; (bank 6's select_backbuf, through low RAM)
        jsr calc_ring
        jmp clear_ring

; menu_show: display buffer 0 (build sections, flip)
menu_show:
        stz curbuf                  ; (A is dead: build_sections loads it)
        jsr menu_sections           ; the kernel's (engine.s)
    .if .not BHW
        stz NEXTBUF                 ; (the Master: its handler's flip reads it)
    .endif
        stz NEXTSECT
        inc flipreq                 ; 0 -> 1: every way in has waited for it to clear
:       lda flipreq
        bne :-
        inc curbuf                  ; 0 -> 1: next game frame renders into the other buffer
        jmp set_palette             ; page is on display: colours back

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

; ---------------------------------------------------------------- the title pieces
; Everything the menus show is on black, so a piece is drawn opaque: no mask.  A piece
; is a run-length stream (title.bin, convert.py) of its screen bytes in the screen's
; own order -- a char row at a time, each a column of eight lines after another -- so
; it unpacks into TBUF as a straight run and goes to the screen a char row at a time.
; Big Cleo's frames are unpacked a frame ahead (winlose), so what reaches the screen
; after the vsync is the copy alone, which stays ahead of the beam.

; draw a title piece: A = piece index, spx/spy = position (top-left: char aligned,
; spx a multiple of 2, spy of 4)
draw_piece:
        jsr unpack                  ; (leaves spx, spy alone)
; TBUF -> the screen: prows char rows of pspan bytes, from char column spx/2 of char
; row spy/4 on
blit:   lda #<TBUF
        sta w16b
        lda #>TBUF
        sta w16b+1
        lda spy
        lsr
        lsr
        sta prow
        lda prows
        sta pleft
@row:   lda spx
        lsr
        sta w16
        lda #0
        sta w16+1
        lda prow                    ; (C = 0: spx is even -- ringaddr7 adds the carry in)
        jsr ringaddr7               ; sp = the row's first byte (Y untouched)
        lda pspan
        sta tmp
        lda pspan+1
        sta tmp2
@chunk: lda tmp2                    ; 128 bytes at most at a time: the copy counts Y
        bne @full                   ; down to 0 with bpl
        lda tmp
        cmp #129
        bcc @part
@full:  lda #128
@part:  sta tmp3
        tay
        dey
@c:     lda (w16b),y
        sta (sp),y
        dey
        bpl @c
        lda w16b                    ; (C = 0: dey leaves the carry of the cmp or the
        clc                         ;  lda, which is not known on the @full way)
        adc tmp3
        sta w16b
        bcc :+
        inc w16b+1
:       lda sp                      ; within a row: the ring folds only between rows
        clc
        adc tmp3
        sta sp
        bcc :+
        inc sp+1
:       lda tmp
        sec
        sbc tmp3
        sta tmp
        bcs :+
        dec tmp2
:       ora tmp2
        bne @chunk
        inc prow
        dec pleft
        bne @row
        rts

; piece A -> TBUF: its char rows in prows, a row's bytes in pspan.  The stream: a
; byte n < $80 is n+1 literal bytes after it, $80..$FE a run of n-$7D copies of the
; byte after it, $FF the end.
unpack: tax
        lda tp_lo,x
        sta w16b
        lda tp_hi,x
        sta w16b+1
        lda tp_rows,x
        sta prows
        lda #0
        sta pspan+1
        lda tp_cols,x
        asl
        asl
        asl
        rol pspan+1                 ; (C = 0 before: 8 * 40 columns at most)
        sta pspan
        lda #<TBUF
        sta tp
        lda #>TBUF
        sta tp+1
@ctl:   ldy #0
        lda (w16b),y
        cmp #$FF
        beq @done
        inc w16b
        bne :+
        inc w16b+1
:       cmp #$80
        bcs @run
        tax                         ; n + 1 literals
        inx
@lit:   lda (w16b),y
        sta (tp),y
        iny
        dex
        bne @lit
        tya                         ; the stream on by Y too
        clc
        adc w16b
        sta w16b
        bcc @adv
        inc w16b+1
        bcs @adv                    ; (always: inc leaves the carry)
@run:   sbc #$7D                    ; C = 1: n - $7D copies
        tax
        lda (w16b),y
        inc w16b
        bne @r
        inc w16b+1
@r:     sta (tp),y
        iny
        dex
        bne @r
@adv:   tya                         ; the buffer on by Y
        clc
        adc tp
        sta tp
        bcc @ctl
        inc tp+1
        bcs @ctl                    ; (always)
@done:  rts

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
@r:     stx tmp3
        lda #0
        sta w16
        sta w16+1
        txa
        clc                         ; (ringaddr7 adds the carry in)
        jsr ringaddr7               ; sp = the row's start
        lda sp
        sta w16
        lda sp+1
        sta w16+1
        ldx tmp3
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
        cpx #VISROWS                ; the window's last row (below: the menus' bar rows,
                                    ; never drawn, black since clear_ring)
        bne @r
@done:  rts

; ---------------------------------------------------------------- screens
; title menu: returns 0 start, 1 help, 2 exit
title_menu:
        lda MUSON
        bne :+
        jsr music_start             ; only if not already playing (back from help)
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
        tya                         ; y = i*10+16, the last line at 66: laid out for
        asl                         ; the Model B's 84 px of window (Y = 2i, C = 0 from
        adc tmp3                    ; the asl above): i*5
        adc #8
        asl                         ; (i*5+8)*2 = i*10+16
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
        jsr music_stop              ; the win/lose screen is silent
        jsr menu_begin
        .assert TP_WIN = TP_LOSE - 1, error, "winlose picks the piece as TP_LOSE - mtop"
        lda #0
        sta spx+1
        sta spy+1
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
SCORE_Y = 64                        ; 84 px of window: under big Cleo (28..59)
HISCORE_Y = 76                      ; (a glyph row is a multiple of 4)
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
        sta mbuf                    ; the frame in TBUF      screen runs no list, and
        stz msel                    ; animation counter      tmp2/tmp3 do not survive
                                    ;                        menu_show's callees)
        lda #66                     ; big Cleo's place, once: nothing in the loop moves
        sta spx                     ; spx/spy (spx+1, spy+1 are 0 from the pieces above)
        lda #28
        sta spy
@loop:  jsr cleo_frame              ; the frame for msel: in TBUF already (unpacked a
        cmp mcount                  ; frame ahead, below) but for the first
        beq @same
        sta mcount
        cmp mbuf
        beq :+
        sta mbuf
        jsr unpack
:       jsr blit                    ; right after menu_keys' vsync, as the copy it is
@same:  jsr menu_show
        inc msel
        jsr cleo_frame              ; the next one, unpacked now, while the page stands
        cmp mcount
        beq :+
        cmp mbuf
        beq :+
        sta mbuf
        jsr unpack
:       jsr menu_keys
        and #(K_FIRE|K_RIGHT)
        beq @loop
        rts

; big Cleo's frame for msel -> A (the piece): the shift count is the same on both arms
cleo_frame:
        lda msel
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
        ldx #4
@d:
        jsr div10_16                ; (X kept: Y is its count)
        ora #'0'                    ; A = the remainder (= q1)
        sta numbuf,x
        dex
        bpl @d
        ; suppress leading zeros (keep at least one)
        ldy #$FF
:       iny
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
mbuf:      .res 1                  ; the piece in TBUF (winlose: big Cleo a frame ahead)
prow:      .res 1                  ; blit: the char row, and the rows left
pleft:     .res 1
prows:     .res 1                  ; unpack's piece: its char rows, a row's bytes
pspan:     .res 2
TBUF:      .res TBUF_LEN           ; the piece unpacked (title.inc: the largest)
tx:        .res 1
ty:        .res 1
