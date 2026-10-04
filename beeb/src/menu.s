; ============================================================================
; CLEO - the menus: title, help, level select, win/lose, and the top of the game
; loop.  The menus' image of bank 7 (MNUCODE/MNUBSS; the font, the tune and the title
; pieces in banks.s's MNUDATA), which the game's image replaces for play and which
; replaces it again after (disc.s go_game, go_menu).  What they call in bank 7 is the
; kernel's, which neither image covers: a plain call.
; ============================================================================
        .segment "MNUCODE"      

; ---------------------------------------------------------------- the game loop's top
; start-up comes here (disc.s go_title), and the game's image comes back to menu_over when a game ends (A = 0 lost, 1 won), with the stack
; reset: every way out of here is go_game.
game_main:
        lda #$34                   ; rnd's seed
        sta seed
        lda #$12
        sta seed+1
        zero hi_score, hi_score+1, hi_score+2, max_level
  .if ALLLEVELS
        lda #7                     ; (a test build: every main level on the chooser)
        sta max_level
  .endif
title_loop:
        jsr title_menu
        beq new_game               ; A = 0 start, 1 help: Z from menu_list's lda msel
        jsr help_screen
        bne title_loop             ; (always: help_screen returns Z = 0)
new_game:
        stz score
        sta0 score+1, score+2      ; A = 0 (the Model B's stz)
        lda #3
        sta lives
        sta health
        lda max_level              ; 0: level 0, A = 0 for the store below
        beq :+
        jsr level_select
        asl
:       sta level
        jsr blank_palette          ; the load is dark (go_game takes nothing in A)
        jmp go_game                ; the game's image, and its level loop (disc.s)
menu_over:
        jsr win_lose
        bne title_loop             ; (always: win_lose returns Z = 0)

; ---------------------------------------------------------------- text
; draw_text: ptr -> 0-terminated string, A = x (px, even), X = y (px, multiple of 4)
draw_text:
        sta tx
        stx ty
        ldy #0
@ch:    lda (ptr),y
        beq @done
        sty tchar                  ; not phy: on a 6502 that is tya/pha, and the
        cmp #' '                    ; character is in A
        beq @space
        cmp #'_'
        bne :+
        lda #<font_blank           ; '_' = erase: draw the all-zero glyph (A is dead:
        sta w16b                   ;  draw_glyph_rows starts with lda tx)
        lda #>font_blank
        sta w16b+1
        bne @rows                  ; (always: the font is in bank 7)
:       jsr glyph_index            ; glyph A's rows: the font is in the overlay beside
        stzx w16b+1                ; this code (font_art, banks.s), read in place
                                    ;  through w16b (A live; X is dead: draw_glyph_rows
                                    ;  sets it before reading it)
        asl
        asl
        asl
        rol w16b+1                 ; C = 0: the byte it shifts out was 0
        adc #<font_art
        sta w16b
        lda w16b+1
        adc #>font_art
        sta w16b+1                 ; glyph rows
@rows:  jsr draw_glyph_rows
@space: lda tx
        adc #7                     ; C = 1 on every way in: cmp #' ' equal, or the cpx #8
                                    ; draw_glyph_rows returns from
        sta tx
        ldy tchar
        iny
        bne @ch                    ; Y > 0: no string is 256 characters
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
        eor #$33                   ; '/' -> 28, '.' -> 29
        rts
:       sbc #('0'-30)               ; C = 1 from the bcs: -'0'+30 in one subtraction
        rts

; draw the glyph rows at w16b at (tx, ty) : 8x8 px -> 4 chars x 2 char rows
draw_glyph_rows:
        lda tx
        lsr
        sta w16
        stz w16+1
        lda ty                     ; any game pixel row: tfine = ty & 3, the glyph's
        and #3                     ;  rows (a game pixel, two lines, each) start that
        sta tfine                  ;  far into its char row and run on into the next
        lda ty
        lsr
        lsr
        clc                        ; (ring_addr7 adds the carry in: ty's bit 1 is out)
        jsr ring_addr7             ; sp = first char (row 0)
        ldx #0                     ; glyph row 0..7
@row:   txa                        ; tline = the glyph row's place from the first char
        clc                        ;  row's top: the next char row at 4 and 8
        adc tfine
        sta tline
        cmp #4
        beq @next
        cmp #8
        bne @put
@next:  lda sp                     ; one char row on (C = 1: the cmp found it equal)
        adc #(<ROWBYTES) - 1
        .assert (<ROWBYTES) <> 0, error, "the carry-in add needs a nonzero low byte"
        sta sp
        lda sp+1
        adc #>ROWBYTES
        ringup sp
        sta sp+1
@put:   txa
        tay
        lda (w16b),y
        sta tmp                    ; row bits
        lda tline
        asl
        and #7
        sta tmp2                   ; ra: its line in the char row
        lda sp
        sta tp
        lda sp+1
        sta tp+1                   ; remember row start
        lda #4
        sta tmp4
@pair:  lda #0                     ; shift the top two bits of tmp straight out of it
        asl tmp
        rol
        asl tmp
        rol
        tay
        lda pair_tab,y
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
        jmp @row                   ; (the 6502 spellings put @row out of a branch's reach)
:       rts
font_blank: .res 8, 0              ; the erase glyph ('_' in a string)
pair_tab: .byte $00, $33, $CC, $FF ; logical 3 (yellow) on both dots of a game px

; ---------------------------------------------------------------- menu screen helpers
; clear the ring to black.  The bar is left alone: the menus' frame does not show it
; (menu_sections, engine.s)
        .assert <CLEAR0 = 0, error, "the clear is whole pages"
clear_ring:
        lda #>CLEAR0               ; to the top ($8000), whole pages: the Model B's
        sta w16+1                  ; mirrors and rings, the Master's buffer 0 ring
        lda #0                     ; (the bar is below either)
        sta w16
        tay
@l:     sta (w16),y
        iny
        bne @l
        inc w16+1
        bpl @l                     ; to $8000 (engine.s asserts the ring ends)
        rts

; menu_begin: window at (0,0), buffer 0 as work buffer, cleared; screen blanked until
; menu_show has flipped the finished page in
menu_begin:
        jsr blank_palette
:       lda flip_req               ; the game may still have a flip pending
        bne :-
        sta wx                     ; A = 0: flip_req was
        sta wx+1
        sta wy
        sta wy+1
        sta wcx
        sta wcx+1
        sta wcy
        sta wfine
        sta cur_buf
        jsr selbb                  ; (bank 6's select_backbuf, through low RAM)
        jsr calc_ring
        jmp clear_ring

; menu_show: display buffer 0 (build sections, flip)
menu_show:
        stz cur_buf                ; (A is dead: build_sections loads it)
    .if BHW
        sta next_sect              ; A = 0 (the stz).  Before the build: the vsync reads
    .else                          ;  it only for a flip, and flip_req is 0 until below
        stz next_buf               ; (the Master: its handler's flip reads it)
        stz next_sect
    .endif
        jsr menu_sections          ; the kernel's (engine.s)
        inc flip_req               ; 0 -> 1: every way in has waited for it to clear
:       lda flip_req
        bne :-
        inc cur_buf                ; 0 -> 1: next game frame renders into the other buffer
        jmp set_palette            ; page is on display: colours back

; wait one vsync and return new key edges in A (keys pressed now but not last time)
menu_keys:
        lda vsyncs
:       cmp vsyncs
        beq :-
        lda keys
        tax
        eor last_keys
        and keys
        stx last_keys
        rts

; ---------------------------------------------------------------- the title pieces
; Everything the menus show is on black, so a piece is drawn opaque: no mask.  A piece
; is a run-length stream (title.bin, convert.py) of its screen bytes in the screen's
; own order -- a char row at a time, each a column of eight lines after another -- so
; it unpacks into TBUF as a straight run and goes to the screen a char row at a time.
; Big Cleo's frames are unpacked a frame ahead (win_lose), so what reaches the screen
; after the vsync is the copy alone, which stays ahead of the beam.

; draw a title piece: A = piece index, spx/spy = position (top-left: char aligned,
; spx a multiple of 2, spy of 4)
draw_piece:
        jsr unpack                 ; (leaves spx, spy alone)
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
        lda prow                   ; (C = 0: spx is even -- ring_addr7 adds the carry in)
        jsr ring_addr7             ; sp = the row's first byte (Y untouched)
        lda pspan
        sta tmp
        lda pspan+1
        sta tmp2
@chunk: lda tmp2                   ; 128 bytes at most at a time: the copy counts Y
        bne @full                  ; down to 0 with bpl
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
        lda w16b                   ; (C = 0: dey leaves the carry of the cmp or the
        clc                        ;  lda, which is not known on the @full way)
        adc tmp3
        sta w16b
        bcc :+
        inc w16b+1
:       lda sp                     ; within a row: the ring folds only between rows
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
        lda tp_cols,x
        asl
        asl
        asl                        ; (8 * 40 columns at most: the high byte is the carry)
        sta pspan
        lda #0
        rol
        sta pspan+1
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
        tax                        ; n + 1 literals
        inx
@lit:   lda (w16b),y
        sta (tp),y
        iny
        dex
        bne @lit
        tya                        ; the stream on by Y too (C = 0: the cmp #$80)
        adc w16b
        sta w16b
        bcc @adv
        inc w16b+1
        bcs @adv                   ; (always: inc leaves the carry)
@run:   sbc #$7D                   ; C = 1: n - $7D copies
        tax
        lda (w16b),y
        inc w16b
        bne @r
        inc w16b+1
@r:     sta (tp),y
        iny
        dex
        bne @r
@adv:   tya                        ; the buffer on by Y
        clc
        adc tp
        sta tp
        bcc @ctl
        inc tp+1
        bcs @ctl                   ; (always)
@done:  rts

; centred text: ptr -> string, X = y  (x = (160 - len*8)/2)
text_centred:
        ldy #$FF
:       iny
        lda (ptr),y
        bne :-
        tya
        asl
        asl                        ; len*4
        eor #$FF                   ; WINPX/2 - A, without parking A in memory
        adc #(WINPX/2)+1           ; C = 0 from the second asl: len < 64
        jmp draw_text

; ---------------------------------------------------------------- generic list menu
; menu_list: menu_ptr -> table of string pointers (word), A = count, X = first y,
; mstep = row step, mclear = clear the items' area first; returns A = selected index
menu_list:
        ldy menu_ptr               ; the table's address into the one load below: the
        sty @mt0+1                 ; overlay is in sideways RAM, so the pointer needs
        ldy menu_ptr+1             ; no zero page
        sty @mt0+2
        sta mcount
        stx mtop
        lda #$FF
        sta last_keys
        jsr clear_items
        ldx #0
        stx msel                   ; (not stz: on the Model B that is lda #0 / sta)
@it:    stx tmp3
        txa
        asl
        tay
        iny                        ; Y = 2i + 1: the high byte, then the low
        ldx #1
@mt0:   lda $FFFF,y                ; (menu_ptr, patched in above)
        sta ptr,x
        dey
        dex
        bpl @mt0
        ldx tmp3                   ; the index again, for item_y
        jsr item_y                 ; X = the index still: A = X = its y
        jsr text_centred
        ldx tmp3
        inx
        cpx mcount
        bne @it
        jsr @cursor                ; A = 0 = msel: draw_text returns A = 0
        jsr menu_show
@loop:  jsr menu_keys
        sta tmp
        and #K_UP
        beq :+
        dec msel                   ; 0 -> $FF and back: nothing to move up to
        bpl @move                  ; msel < mcount <= 8: from 1..7 always taken
        inc msel
:       lda tmp
        and #K_DOWN
        beq :+
        ldx msel
        inx
        cpx mcount
        bcs :+
        stx msel
        bcc @move                  ; always: bcs not taken
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
        beq @loop                  ; always: draw_text returns Z = 1
@cursor:
        sta mlast
        ldx #<cursor_str
        ldy #>cursor_str
@curstr:
        stx ptr
        sty ptr+1
        tax
        jsr item_y
        lda #(WINPX-CURSORLEN*8)/2 ; centred, as text_centred puts the items
        jmp draw_text
item_y: lda mtop                   ; X = item index -> A = X = its y
        cpx #0
        beq :++
:       clc
        adc mstep
        dex
        bne :-
:       tax
        rts
cursor_str: .byte ">                 <", 0
CURSORLEN = * - cursor_str - 1
        .assert ((WINPX-CURSORLEN*8)/2) .mod 2 = 0, error, "draw_text's x must be even"
blank_str:  .byte "_                 _", 0

; if mclear: clear the items' area below the logo, char row mtop/4 to the last (640
; bytes each, buffer 0's rows)
clear_items:

        lda mtop
        lsr
        lsr
        tax
@r:     stx tmp3
        lda #0
        sta w16
        sta w16+1
        txa
        clc                        ; (ring_addr7 adds the carry in)
        jsr ring_addr7             ; sp = the row's start
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
        cpx #VISROWS               ; the window's last row (below: the menus' bar rows,
                                    ; never drawn, black since clear_ring)
        bne @r
@done:  rts

; ---------------------------------------------------------------- screens
; title menu: returns 0 start, 1 help, 2 exit
; ---- a screen laid out for the Model B's 84 px of window, centred in a taller one
; (the Master's 120): with its ink spanning top..bot-1, the offset is
; (VISLINES/2 - bot - top) / 2, rounded to a char row (4 px)
  .if VISLINES/2 > 84
TITLE_DY = ((VISLINES/2 - 70 - 4) / 2 + 2) & $FC    ; the logo's top to the second item's
HELP_DY  = ((VISLINES/2 - 74 - 16) / 2 + 2) & $FC   ;  last row; the help's lines;
WL_DY    = ((VISLINES/2 - 84 - 4) / 2 + 2) & $FC    ;  YOU WIN's top to the hi-score's last
  .else                            ;  row (YOU LOSE: a row lower, 2 px off)
TITLE_DY = 0
HELP_DY  = 0
WL_DY    = 0
  .endif
title_menu:
        lda mus_on
        bne :+
        jsr music_start            ; only if not already playing (back from help)
:       jsr menu_begin
        lda #40
        sta spx
        lda #4+TITLE_DY
        sta spy
        lda #TP_LOGO               ; = 0: both high bytes
        .assert TP_LOGO = 0, error, "title_menu: TP_LOGO doubles as the zero high bytes"
        sta spx+1
        sta spy+1
        jsr draw_piece
        lda #<menu1
        sta menu_ptr
        lda #>menu1
        sta menu_ptr+1
        lda #14
        sta mstep
        lda #1
        sta mclear
        asl                        ; A = 2 items
        ldx #48+TITLE_DY
        jmp menu_list

help_screen:
        jsr menu_begin
        ldy #10                    ; Y = 2i, the last line first: no two lines share a
@l:     sty tmp3                   ; char row, so the order leaves the same page
        lda help_tab,y
        sta ptr
        lda help_tab+1,y
        sta ptr+1
        tya                        ; y = i*10+16, the last line at 66: laid out for
        asl                        ; the Model B's 84 px of window: 2i*4 + 2i (C = 0
        asl                        ; from the asls)
        adc tmp3
        adc #16+HELP_DY            ; i*10+16 (+ HELP_DY)
        tax
        jsr text_centred
        ldy tmp3
        dey
        dey
        bpl @l
        jsr menu_show
        lda #$FF
        sta last_keys
:       jsr menu_keys
        and #(K_FIRE|K_RIGHT)
        beq :-
        rts

; level select: A = max level index (0..7) -> returns chosen level (0..max)
level_select:
        pha
        jsr menu_begin
        lda #<level_names
        sta menu_ptr
        lda #>level_names
        sta menu_ptr+1
        lda #1
        sta mclear
        pla                        ; max = n-1
        tax
        inx
        stx tmp                    ; n
        sta tmp2
        asl tmp2                   ; (n-1)*2
        ; the items 12 px apart, or 10 when that would not fit the window (all eight on
        ; the Model B's 84 px: 92 tall at 12, 78 at 10)
        asl
        asl
        sta tmp3                   ; (n-1)*4
        asl
        adc tmp3                   ; (n-1)*12 (C = 0: (n-1)*8 <= 56)
        ldy #12
        cmp #VISLINES/2 - 8 + 1    ; the list's height less a glyph's, against the window's
        bcc :+
        sbc tmp2                   ; C = 1: (n-1)*12 - (n-1)*2 = (n-1)*10
        ldy #10
        clc
:       sty mstep
        ; top y = (VISLINES/2 - 8 - (n-1)*step) / 2 (text goes on any pixel row)
        eor #$FF                   ; (C = 0 both ways in)
        adc #VISLINES/2 - 8 + 1
        lsr
        tax
        lda tmp
        jmp menu_list

; win/lose: A = 1 win, 0 lose; score and hi-score shown
win_lose:
        sta mtop                   ; the win/lose flag (not tmp4: the sprite prologue
                                    ; uses it, and the lose screen cycled the WIN frames)
        jsr music_stop             ; the win/lose screen is silent
        jsr menu_begin
        .assert TP_WIN = TP_LOSE - 1, error, "win_lose picks the piece as TP_LOSE - mtop"
        sta spx+1                  ; A = 0: menu_begin ends in clear_ring, which
        sta spy+1                  ;  stores A = 0 throughout
        lda mtop                   ; YOU WIN at 4, YOU LOSE at 8: big Cleo (24) is then
        eor #1                     ;  centred between the words and the score -- the
        asl                        ;  lose frames' ink starts 6 px into the piece, the
        asl                        ;  win frames' at 0 (C = 0 from the asls)
        adc #4+WL_DY
        sta spy
        lda mtop                   ; 1 win, 0 lose
        asl                        ; (C = 0)
        adc #34                    ; YOU at 36 / 34
        sta spx
        lda #TP_YOU
        jsr draw_piece             ; (leaves spx, spx+1, spy, spy+1 alone)
        lda spx
        adc #80-34-1               ; C = 1 from draw_piece (blit's last sbc found no
                                    ;  borrow): WIN at 82 / LOSE at 80; C = 0
        sta spx
        lda #TP_LOSE+1
        sbc mtop                   ; C = 0: TP_LOSE - mtop = TP_WIN / TP_LOSE
        jsr draw_piece
@scores:
        lda #<str_score
        sta ptr
        lda #>str_score
        sta ptr+1
SCORE_Y = 64+WL_DY                 ; 84 px of window: under big Cleo (24..55)
HISCORE_Y = 76+WL_DY               ; (a glyph row is a multiple of 4)
        stz t16                    ; the score's BCD (score+0: draw_text leaves t16 alone)
        ldx #SCORE_Y
@srow:  lda #12                    ; a row: the label, then its value at 84 (the score
        jsr draw_text              ;  column aligned with the hi-score's)
        lda #84
        ldx ty                     ; the row's y: draw_text leaves ty
        jsr draw_number
        ldx ty                     ; (draw_number's stx ty wrote the same y)
        cpx #HISCORE_Y
        beq @sdone                 ; both rows drawn
        lda #<str_hiscore
        sta ptr
        lda #>str_hiscore
        sta ptr+1
        lda #hi_score-score        ; the hi-score's (score+3)
        sta t16
        ldx #HISCORE_Y
        bne @srow                  ; (always: HISCORE_Y > 0)
@sdone:
        lda #$FF
        sta last_keys
        sta mcount                 ; the frame last drawn  (menu_list's variables: this
        sta mbuf                   ; the frame in TBUF      screen runs no list, and
        stz msel                   ; animation counter      tmp2/tmp3 do not survive
                                    ;                        menu_show's callees)
        lda #66                    ; big Cleo's place, once: nothing in the loop moves
        sta spx                    ; spx/spy (spx+1, spy+1 are 0 from the pieces above)
        lda #24+WL_DY              ; (ink 24..54 winning, 30..54 losing: 7 and 9 px /
        sta spy                    ;  9 and 9 px from the words and the score)
@loop:  jsr cleo_frame             ; the frame for msel: in TBUF already (unpacked a
        cmp mcount                 ; frame ahead, below) but for the first
        beq @same
        sta mcount
        cmp mbuf
        beq :+
        sta mbuf
        jsr unpack
:       jsr blit                   ; right after menu_keys' vsync, as the copy it is
@same:  jsr menu_show
        inc msel
        jsr cleo_frame             ; the next one, unpacked now, while the page stands
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
        bne @drawc                 ; (always)
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
shr16x: txa                        ; Z from X (A dead at both callers)
        beq :++
:       lsr w16+1
        ror w16
        dex
        bne :-
:       rts
; w16b:w16 (24 bit) >>= X
shr24x: txa                        ; Z from X (A dead at the caller)
        beq :++
:       lsr w16b
        ror w16+1
        ror w16
        dex
        bne :-
:       rts

; draw_number: t16 = 0 the score, 3 the hi-score (BCD, ones first); prints it *100 as
; digits at (A = x, X = y): five digits + "00", leading zeros suppressed
draw_number:
        sta tx
        stx ty
        ldy t16
        ldx #4                     ; NUMBUF 4..0: each byte's low nibble, then its high
@d:     lda score,y
        and #$0F
        ora #'0'
        sta NUMBUF,x
        dex
        bmi @z                     ; five: the top byte's high nibble is not shown
        lda score,y
        lsr
        lsr
        lsr
        lsr
        ora #'0'
        sta NUMBUF,x
        iny
        dex
        bpl @d                     ; (always: X = 3 or 1 here)
@z:
        ; suppress leading zeros (keep at least one)
        ldy #$FF
:       iny
        lda NUMBUF,y
        cmp #'0'
        bne :+
        lda #' '
        sta NUMBUF,y
        cpy #3
        bne :-
:       lda #'0'
        sta NUMBUF+5
        sta NUMBUF+6
        stz NUMBUF+7
        lda #<NUMBUF
        sta ptr
        lda #>NUMBUF
        sta ptr+1
        jmp draw_text+6            ; past its sta tx/stx ty: tx, ty hold A, X already

; ---------------------------------------------------------------- strings
menu1:      .word s_start, s_help
s_start:    .byte "START GAME", 0
s_help:     .byte "HELP", 0
help_tab:    .word h1, h2, h3, h4, h5, h6
h1:         .byte "Z X TO RUN", 0
h2:         .byte "RETURN TO JUMP", 0
h3:         .byte "SLASH TO THROW", 0
h4:         .byte "COLLECT ALL", 0
h5:         .byte "STARS TO OPEN", 0
h6:         .byte "BONUS LEVEL", 0
level_names: .word l0, l1, l2, l3, l4, l5, l6, l7
l0:         .byte "CITY GATES", 0
l1:         .byte "TUTANKHAMUN", 0        ; (levels 1 and 5: the maps swapped, convert.py)
l2:         .byte "VINEYARDS", 0
l3:         .byte "CHEFREN", 0
l4:         .byte "CITADELS", 0
l5:         .byte "CHEOPS", 0
l6:         .byte "ALEXANDRIA", 0
l7:         .byte "NEFERTITI", 0
str_score:  .byte "SCORE", 0
str_hiscore:.byte "HISCORE", 0

        .segment "MNUBSS"
tfine:     .res 1                  ; draw_glyph_rows: ty & 3, and the row's place
tline:     .res 1
NUMBUF:    .res 8
menu_ptr:   .res 2                 ; menu_list's table (read through its own operands)
tchar:     .res 1                  ; draw_text's place in the string
mcount:    .res 1
mtop:      .res 1
mstep:     .res 1
msel:      .res 1
mclear:    .res 1
mlast:     .res 1                  ; item index the cursor was last drawn at
mbuf:      .res 1                  ; the piece in TBUF (win_lose: big Cleo a frame ahead)
prow:      .res 1                  ; blit: the char row, and the rows left
pleft:     .res 1
prows:     .res 1                  ; unpack's piece: its char rows, a row's bytes
pspan:     .res 2
TBUF:      .res TBUF_LEN           ; the piece unpacked (title.inc: the largest)
tx:        .res 1
ty:        .res 1
