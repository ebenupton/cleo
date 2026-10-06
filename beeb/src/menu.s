; ============================================================================
; Cleo's menus: the title, the help, the level chooser, the win/lose screen, and
; the top of the game loop (the engine's hook_title and hook_over).  The menus'
; image of bank 7 (MNUCODE, MNUBSS; the font, the tune and the title pieces are
; gamedata.s's MNUDATA), which go_game replaces with the game's image for play
; and go_menu brings back after (disc.s).  Both machines, the same code: what
; differs is one store in menu_show.  What the menus call in bank 7 is the
; kernel's, above either image: a plain call (ring_addr7, calc_ring,
; menu_sections, the palettes, music_stop).
;   game_main    hook_title: start-up, then the title loop (main.s)
;   menu_over    hook_over: a game has ended, A = 0 lost or 1 won (main.s)
;   menu_keys    the once-a-frame key read: the test harness's break point in
;                the menus (test/menusync.mjs, roundtrip.mjs, loadsync2.mjs)
; The menus draw into buffer 0 with the window at the origin, a page at a time
; with the palette black (menu_begin), then flip it in (menu_show); the win/lose
; screen then animates in the displayed page.  Every screen is laid out for the
; Model B's window (MENU_LAID_PX of game pixels) and centred in a taller one
; (TITLE_DY, HELP_DY, WL_DY).  test/harness.mjs patches title_loop's first six
; bytes (jsr title_menu / beq new_game): keep them.
; ============================================================================
        .segment "MNUCODE"

; ---------------------------------------------------------------- the menus' layout
; Positions in game pixels: an x is even and a piece's y a multiple of
; MENU_ROWPX, so that pieces sit on chars; text goes on any pixel row.
MENU_ROWPX   = CHARLINES/2         ; a char row in game pixels (4)
MENU_LAID_PX = 84                  ; the window height the screens are laid out
                                    ; for: the Model B's
        .assert (.not BHW) || (VISLINES/2 = MENU_LAID_PX), error, "the menus are laid out for the Model B's window"
MENU_LOGO_X  = 40                  ; the title: the logo (its 80 px centred), then the
MENU_LOGO_Y  = 4                   ;  items
MENU_ITEMS_Y = 48
MENU_STEP    = 14                  ;  a line apart
MENU_NITEMS  = 2
HELP_N       = 6                   ; the help: its lines, from HELP_Y0, HELP_PITCH apart
HELP_Y0      = 16
HELP_PITCH   = 10
LEVEL_STEP   = 12                  ; the level chooser's lines, or LEVEL_STEP_TIGHT when
LEVEL_STEP_TIGHT = 10              ;  all eight would not fit the window
WL_WORDS_Y   = 4                   ; win/lose: YOU WIN's top (YOU LOSE a char row lower)
WL_YOU_X     = 34                  ;  YOU's x losing, 2 px on winning
WL_LABEL_X   = 12                  ;  SCORE and HISCORE, their values at WL_VALUE_X
WL_VALUE_X   = 84
WL_SCORE_Y   = 64                  ;  the two rows, under big Cleo
WL_HISCORE_Y = 76
BIGCLEO_X    = 66                  ;  big Cleo, between the words and the score
BIGCLEO_Y    = 24
BIGCLEO_WIN0 = 4                   ;  her frames: TP_CLEO0 + 0..3 losing, + 4..7 winning
CLEO_SEQ_MASK = 30                 ;  the frame sequences, 2 bits a frame, by msel & 30
WIN_SEQ      = 441                 ;  winning: 441 >> n, losing: $E79E79 >> n
LOSE_SEQ     = $E79E79
NUM_DIGITS   = 5                   ; draw_number: the score's digits shown (then "00")
BLIT_CHUNK   = 128                 ; blit copies a piece's row this much at a time
; the font (convert.py font: tit.png's glyphs in this order): A-Z, then > < / .
; and the digits, GLYPHW x GLYPHH px each (glyph_index maps the characters)
GLYPH_GT    = 26
GLYPH_LT    = 27
GLYPH_SLASH = 28
GLYPH_DOT   = 29
GLYPH_0     = 30
; The picture a menu shows is the window (VISLINES/2 px, y 0 down) and, above it,
; the bar's section (MENU_BAND_PX: menu_sections points it at ring rows below the
; window, cleared, so it shows black).  A screen's ink spans top..bot-1 as laid
; out (y >= 0: the band cannot hold ink); centred in the whole picture its offset
; is (VISLINES/2 - MENU_BAND_PX - bot - top) / 2, rounded to a char row (pieces sit
; on chars), negative to move a screen up, but never so far that its ink starts
; above y = 0.
MENU_BAND_PX  = BARROWS*CHARLINES/2
TITLE_TOP     = MENU_LOGO_Y
TITLE_BOT     = MENU_ITEMS_Y + (MENU_NITEMS-1)*MENU_STEP + GLYPHH
HELP_TOP      = HELP_Y0
HELP_BOT      = HELP_Y0 + (HELP_N-1)*HELP_PITCH + GLYPHH
WL_TOP        = WL_WORDS_Y
WL_BOT        = WL_HISCORE_Y + GLYPHH
MENU_ROOM = VISLINES/2 - MENU_BAND_PX     ; the picture's height less the band, twice its centre
TITLE_DY = .max(-(TITLE_TOP & ~(MENU_ROWPX-1)), ((MENU_ROOM - TITLE_BOT - TITLE_TOP) / 2 + MENU_ROWPX/2) & ~(MENU_ROWPX-1))
HELP_DY  = .max(-(HELP_TOP & ~(MENU_ROWPX-1)), ((MENU_ROOM - HELP_BOT - HELP_TOP) / 2 + MENU_ROWPX/2) & ~(MENU_ROWPX-1))
WL_DY    = .max(-(WL_TOP & ~(MENU_ROWPX-1)), ((MENU_ROOM - WL_BOT - WL_TOP) / 2 + MENU_ROWPX/2) & ~(MENU_ROWPX-1))

; ---------------------------------------------------------------- variables
        .segment "MNUBSS"          ; the menus' image: gone while the game runs
tfine:    .res 1                   ; draw_glyph_rows: ty & 3, and the row's place
tline:    .res 1
NUMBUF:   .res NUM_DIGITS+3        ; draw_number's digits, "00" and the end
menu_ptr: .res 2                   ; menu_list's table (read through its own operands)
tchar:    .res 1                   ; draw_text's place in the string
mcount:   .res 1                   ; menu_list: the items, the first's y, the row step,
mtop:     .res 1                   ;  the selection (win_lose borrows them: the flag,
mstep:    .res 1                   ;  the frames, the counter)
msel:     .res 1
mlast:    .res 1                   ; the item the cursor was last drawn at
mbuf:     .res 1                   ; the piece in TBUF (win_lose: big Cleo, one ahead)
prow:     .res 1                   ; blit: the char row, and the rows left
pleft:    .res 1
prows:    .res 1                   ; unpack's piece: its char rows, a row's bytes
pspan:    .res 2
TBUF:     .res TBUF_LEN            ; the piece unpacked (assets.py: the largest)
tx:       .res 1                   ; draw_text's pen: x (even), y
ty:       .res 1
        .segment "MNUCODE"

; ---------------------------------------------------------------- the game loop's top
; ----------------------------------------------------------------------------
; game_main: hook_title -- start-up, then the title loop
;   In:    nothing (jumped to by the loader with the menus' image in and the
;          stack reset: ldprog.s ld_image)
;   Out:   does not return: every way out is new_game's go_game
;   Uses:  everything
; The game's state that lives across a session is set once here: rnd's seed, the
; hi-score, the chooser's reach.  menu_over comes back into title_loop when a
; game ends (go_menu's load resets the stack again).
; ----------------------------------------------------------------------------
game_main:
        lda #<RND_SEED
        sta seed
        lda #>RND_SEED
        sta seed+1
        zero hi_score, hi_score+1, hi_score+2, max_level
  .if ALLLEVELS
        lda #NLEVELS/2-1           ; (a test build: every main level on the chooser)
        sta max_level
  .endif
; ---- title_loop: the title, then the help or a game (the harness patches the
;      jsr to lda #0: start a game)
title_loop:
        jsr title_menu
        beq new_game               ; A = 0 start, 1 help (menu_list's Z)
        jsr help_screen
        bne title_loop             ; (always: help_screen returns Z = 0)
; ---- new_game: a game's state into zero page, where it survives the image
;      swap, and the game's image in
new_game:
        stz score
        sta0 score+1, score+2      ; A = 0 (the Model B's stz)
        lda #LIVES
        .assert LIVES = HEALTH_MAX, error, "new_game: one load for the lives and the health"
        sta lives
        sta health
        lda max_level              ; 0: level 0 (A = 0 is the store), else the chooser
        beq @skip
        jsr level_select
        asl                        ; the main level's index: even
@skip:  sta level
        jsr blank_palette          ; dark for the load
        jmp go_game                ; the game's image, then level_loop (disc.s)

; ----------------------------------------------------------------------------
; menu_over: hook_over -- a game has ended
;   In:    A = 0 lost, 1 won (go_menu's; jumped to with the menus' image in)
;   Out:   does not return: back into title_loop
;   Uses:  everything
; ----------------------------------------------------------------------------
menu_over:
        jsr win_lose
        bne title_loop             ; (always: win_lose returns Z = 0)

; ---------------------------------------------------------------- text
; ----------------------------------------------------------------------------
; draw_text: a string in the font at (x, y), into buffer 0
;   In:    ptr = the string, 0-terminated (its characters: A-Z, space, > < / .,
;          the digits, and '_' for an erased glyph); A = x (game px, even); X =
;          y (game px, any row)
;   Out:   tx = x past the last glyph; ty = y; A = 0 and Z = 1 (the terminator);
;          Y = the string's length
;   Uses:  A X Y, w16, w16b, sp, tp, tmp, tmp2, tmp4, tchar, tfine, tline
;   Pre:   menu_begin has run (buffer 0 selected, the window at the origin); the
;          string in bank 7 or main RAM
; A glyph is GLYPHW x GLYPHH game pixels, GLYPHH bytes of a bit a pixel
; (font_art), or font_blank's zeros for '_'; a space only advances.  No string
; is 256 characters.
; ----------------------------------------------------------------------------
draw_text:
        sta tx
        stx ty
        ldy #0
@ch:    lda (ptr),y
        beq @done
        sty tchar                  ; (not phy: the character is in A and the 6502 has
        cmp #' '                   ;  no phy)
        beq @space
        cmp #'_'
        bne @glyph
        lda #<font_blank           ; '_' = erase: the all-zero glyph
        sta w16b
        lda #>font_blank
        sta w16b+1
        bne @rows                  ; (always: font_blank is in bank 7)
@glyph: jsr glyph_index            ; w16b = font_art + 8*glyph, read in place (the font
        asl                        ;  is in this image), as 2*(4*glyph + font_art/2) + 1:
        asl                        ;  4*glyph < 256 (40 glyphs), so C = 0 here
        adc #<(font_art/2)
        sta w16b
        lda #>(font_art/2)
        adc #0
        .assert (font_art & 1) = 1, error, "draw_text: the sec is font_art's low bit (odd)"
        sec                        ; font_art's low bit
        rol w16b
        rol
        sta w16b+1
@rows:  jsr draw_glyph_rows
@space: lda tx
        adc #GLYPHW-1              ; +GLYPHW: C = 1 on every way in (cmp #' ' equal, or
        sta tx                     ;  draw_glyph_rows' final cpx)
        ldy tchar
        iny
        bne @ch                    ; (always: Y < 255)
@done:  rts

; ----------------------------------------------------------------------------
; glyph_index: a character's glyph
;   In:    A = the character: 'A'..'Z', '>', '<', '/', '.' or '0'..'9'
;   Out:   A = its glyph index, 0..39 (GLYPH_*)
;   Uses:  A (C clobbered)
; Another character comes out as a wrong glyph, not an error.
; ----------------------------------------------------------------------------
glyph_index:
        cmp #'A'
        bcc @notalpha
        cmp #'Z'+1
        bcs @notalpha
        sbc #('A'-1)               ; C = 0 (the bcs fell through): A - 'A'
        rts
@notalpha:
        cmp #'>'
        bne @skip
        lda #GLYPH_GT
        rts
@skip:  cmp #'<'
        bne @skip2
        lda #GLYPH_LT
        rts
@skip2: cmp #'0'                   ; below '0' only '/' and '.' come here
        bcs @skip3
        eor #'/' ^ GLYPH_SLASH     ; one eor maps both: '/' -> SLASH, '.' -> DOT
        .assert ('/' ^ GLYPH_SLASH) = ('.' ^ GLYPH_DOT), error, "glyph_index: the slash's and the dot's glyphs differ as the characters do"
        rts
@skip3: sbc #('0'-GLYPH_0)         ; C = 1 (the bcs): A - '0' + GLYPH_0
        rts

; ----------------------------------------------------------------------------
; draw_glyph_rows: one glyph's GLYPHH rows into buffer 0 at (tx, ty)
;   In:    w16b = the glyph's rows (GLYPHH bytes, a bit a game pixel, bit 7 the
;          left); tx (even), ty (any row)
;   Out:   the glyph on the screen; X = GLYPHH, C = 1 (the exit's cpx)
;   Uses:  A X Y, w16, sp, tp, tmp, tmp2, tmp4, tfine, tline
; A glyph is 4 chars wide (a pair of game pixels a char) and spans two or three
; char rows: row r of the glyph is tfine + r game pixel rows below the top of
; ty's char row, and at MENU_ROWPX and 2*MENU_ROWPX the pen moves one char row
; down.  Each row writes two scanlines (a game pixel is two) of each of its four
; chars, in logical colour 3 (pair_tab).
; ----------------------------------------------------------------------------
draw_glyph_rows:
        lda tx
        lsr
        sta w16
        stz w16+1                  ; w16 = the char column
        lda ty
        tax                        ; (X is free until the ldx #0 below)
        and #MENU_ROWPX-1
        sta tfine                  ; tfine = ty's place in its char row
        txa
        lsr
        lsr
        clc                        ; (ring_addr7 adds the carry in: ty's bit 1 is out)
        jsr ring_addr7             ; sp = the first char: row ty/4, column tx/2
        ldx #0                     ; X = the glyph row, 0..GLYPHH-1
@row:   txa
        clc
        adc tfine
        sta tline                  ; tline = the row's place from the first row's top
        cmp #MENU_ROWPX
        beq @next
        cmp #2*MENU_ROWPX
        bne @put
@next:  lda sp                     ; a char row boundary: sp += ROWBYTES (C = 1 from the
        adc #(<ROWBYTES) - 1       ;  cmp that found it equal)
        .assert (<ROWBYTES) <> 0, error, "the carry-in add needs a nonzero low byte"
        sta sp
        lda sp+1
        adc #>ROWBYTES
        ringup sp                  ; the ring's fold
        sta sp+1
@put:   txa
        tay
        lda (w16b),y
        sta tmp                    ; the row's bits
        lda tline
        asl
        and #CHARLINES-1
        sta tmp2                   ; the row's first scanline in its char
        lda sp
        sta tp
        lda sp+1
        sta tp+1                   ; the row's first char, kept for the next row
        lda #GLYPHW/2
        sta tmp4                   ; the chars left in the row
@pair:  lda #0                     ; A = the next two bits, shifted out of tmp's top
        asl tmp
        rol
        asl tmp
        rol
        tay
        lda pair_tab,y             ; their screen byte
        ldy tmp2
        sta (sp),y                 ; both scanlines of the game pixel row
        iny
        sta (sp),y
        spnext                     ; the next char (sp += CHARBYTES, the ring fold)
        dec tmp4
        bne @pair
        lda tp
        sta sp
        lda tp+1
        sta sp+1
        inx
        cpx #GLYPHH
        beq @done
        jmp @row                   ; (@row is out of a branch's reach)
@done:  rts

; ----------------------------------------------------------------------------
; text_centred: a string centred in the window's width
;   In:    ptr = the string; X = y
;   Out:   as draw_text
;   Uses:  as draw_text
; x = (WINPX - len*GLYPHW)/2, computed as WINPX/2 - len*GLYPHW/2 without parking
; A.
; ----------------------------------------------------------------------------
text_centred:
        ldy #$FF
@loop:  iny
        lda (ptr),y
        bne @loop                  ; Y = len
        tya
        asl
        asl                        ; A = len*GLYPHW/2 (C = 0: len < 64)
        .assert GLYPHW = 8, error, "text_centred: two shifts halve a string's width"
        eor #$FF                   ; -A-1, then + WINPX/2 + 1 = WINPX/2 - A
        adc #(WINPX/2)+1
        jmp draw_text

; ---------------------------------------------------------------- a page
; ----------------------------------------------------------------------------
; menu_begin: a page's start -- buffer 0 as the work buffer, the window at
;   the origin, the ring cleared, the palette black
;   In:    nothing
;   Out:   wx = wy = wcx = wcy = wfine = 0, cur_buf = 0; the back buffer
;          selected and ring_s/barq computed for it (selbb, calc_ring); the ring
;          black; A = 0, Y = 0 (clear_ring's)
;   Uses:  A X Y, w16, calc_ring's and select_backbuf's
;   Pre:   interrupts on (a pending flip is waited for)
; ----------------------------------------------------------------------------
menu_begin:
        jsr blank_palette
@loop:  lda flip_req               ; a flip the game asked for may still be pending
        bne @loop
        sta wx                     ; A = 0 (flip_req's)
        sta wx+1
        sta wy
        sta wy+1
        sta wcx
        sta wcx+1
        sta wcy
        sta wfine
        sta cur_buf
        jsr selbb                  ; select_backbuf (bank 6, through low RAM)
        jsr calc_ring              ; then falls into clear_ring (its one caller)

; ----------------------------------------------------------------------------
; clear_ring: the ring to black
;   In:    nothing
;   Out:   CLEAR0 .. $7FFF = 0 (the Model B's mirrors and both rings; the
;          Master's buffer 0 ring; the bar lies below either, untouched); A = 0,
;          Y = 0
;   Uses:  A Y, w16
; Whole pages, to $8000 where the ring ends (defs.s).  The menus never show the
; bar's rows (menu_sections), so it stays as the game left it.
; ----------------------------------------------------------------------------
        .assert <CLEAR0 = 0, error, "the clear is whole pages"
clear_ring:
        lda #>CLEAR0
        sta w16+1
        lda #0
        sta w16
        tay
@l:     sta (w16),y
        iny
        bne @l
        inc w16+1
        bpl @l                     ; to $8000
        rts

; ----------------------------------------------------------------------------
; menu_show: the finished page onto the screen -- buffer 0's chain built, the
;   flip taken, the palette back
;   In:    nothing
;   Out:   buffer 0 displayed; cur_buf = 1 (the game's first render goes to the
;          other buffer); next_sect = 0 (and the Master's next_buf); flip_req =
;          0; A X Y clobbered (set_palette's)
;   Uses:  A X Y, menu_sections' (build_sections' and BUF_SEC0)
;   Pre:   flip_req = 0 (every way in has waited for it: menu_begin, or this
;          routine last time round the win/lose loop)
; cur_buf is 0 again because the last menu_show left it 1 (win_lose shows a page
; a frame).  The chain variables are written before the build: the vsync reads
; them only for a flip, and flip_req is 0 until the inc below.
; ----------------------------------------------------------------------------
menu_show:
        stz cur_buf                ; (A dead: menu_sections reloads it)
  .if .not BHW                     ; hardware: the Master's flip reads next_buf too
        stz next_buf
  .endif
        sta0 next_sect             ; A = 0 (the Model B's stz): buffer 0's chain
        jsr menu_sections          ; the kernel's (kernel.s): the bar's rows left out
        inc flip_req               ; 0 -> 1
@loop:  lda flip_req
        bne @loop
        inc cur_buf                ; 0 -> 1
        jmp set_palette            ; the page is on display: colours back

; ----------------------------------------------------------------------------
; menu_keys: one vsync on, the keys newly pressed
;   In:    keys (the vsync's), last_keys
;   Out:   A = keys & ~last_keys (pressed now and not last time), Z from it;
;          last_keys = keys; X = keys
;   Uses:  A X
;   Pre:   interrupts on
; Where the tests stop the menus: every page is drawn and settled by the time
; this is reached (test/menusync.mjs, roundtrip.mjs, loadsync2.mjs break at this
; label).
; ----------------------------------------------------------------------------
menu_keys:
        lda vsyncs
@loop:  cmp vsyncs
        beq @loop
        lda keys
        tax
        eor last_keys
        and keys
        stx last_keys
        rts

; ---------------------------------------------------------------- the title pieces
; Everything the menus show is on black, so a piece is drawn opaque: no mask.  A
; piece is a run-length stream (title.bin: convert.py title_rle) of its screen
; bytes in the screen's own order -- a char row at a time, each char's eight
; lines after another -- so it unpacks into TBUF as one run and goes to the
; screen a char row at a time.  Big Cleo's frames are unpacked a frame ahead
; (win_lose), so what reaches the displayed page after the vsync is the copy
; alone.

; ----------------------------------------------------------------------------
; draw_piece: a title piece onto buffer 0
;   In:    A = the piece (TP_*); spx, spy = its top left (game px: spx even, spy
;          a multiple of MENU_ROWPX; the low bytes alone are read)
;   Out:   the piece drawn; prows, pspan, TBUF = the piece (unpack's); C = 1
;          (blit's)
;   Uses:  A X Y, w16, w16b, sp, tp, tmp, tmp2, tmp3, prow, pleft
;   Keeps: spx, spy
; ----------------------------------------------------------------------------
draw_piece:
        jsr unpack
; ---- blit: TBUF to the screen -- prows char rows of pspan bytes each, from
;      char column spx/2 of char row spy/4.  Also win_lose's, for a frame
;      already in TBUF.
blit:   lda #<TBUF
        sta w16b
        lda #>TBUF
        sta w16b+1
        lda spy
        lsr
        lsr
        sta prow                   ; the char row
        lda prows
        sta pleft                  ; the rows left
@row:   lda spx
        lsr                        ; (C = 0: spx is even)
        sta w16
        stz w16+1                  ; w16 = the char column
        lda prow
        jsr ring_addr7             ; sp = the row's first byte (C = 0 in)
        lda pspan
        sta tmp
        lda pspan+1
        sta tmp2                   ; tmp2:tmp = the row's bytes left
@chunk: lda tmp2                   ; at most BLIT_CHUNK bytes a copy: Y counts down from
        bne @full                  ;  the chunk's size - 1 with a bpl
        lda tmp
        cmp #BLIT_CHUNK+1
        bcc @part
@full:  lda #BLIT_CHUNK
@part:  sta tmp3                   ; tmp3 = this chunk's bytes
        tay
        dey
@c:     lda (w16b),y
        sta (sp),y
        dey
        bpl @c
        lda w16b                   ; w16b += tmp3 (C unknown here: the @full way skips
        clc                        ;  the cmp)
        adc tmp3
        sta w16b
        bcc @skip
        inc w16b+1
@skip:  lda sp                     ; sp += tmp3: within a row the ring never folds (its
        clc                        ;  end is a row boundary); ring_addr7 folds per row
        adc tmp3
        sta sp
        bcc @skip2
        inc sp+1
@skip2: lda tmp                    ; tmp2:tmp -= tmp3
        sec
        sbc tmp3
        sta tmp
        bcs @skip3
        dec tmp2
@skip3: ora tmp2
        bne @chunk                 ; (row's end: C = 1, the last sbc had no borrow)
        inc prow
        dec pleft
        bne @row
        rts

; ----------------------------------------------------------------------------
; unpack: a title piece's stream into TBUF
;   In:    A = the piece (TP_*)
;   Out:   TBUF = its screen bytes; prows = its char rows; pspan = a row's bytes
;          (16-bit: 8 x its columns)
;   Uses:  A X Y, w16b, tp
;   Keeps: spx, spy
; The stream (convert.py title_rle; assets.inc RLE_*): a byte n < RLE_RUN is n+1
; literal bytes after it; RLE_RUN..RLE_END-1 a run of n - RLE_RUNBIAS copies of
; the byte after it; RLE_END the end.  Its directory is title.inc (tp_lo, tp_hi,
; tp_cols, tp_rows).
; ----------------------------------------------------------------------------
unpack: tax
        lda tp_lo,x
        sta w16b
        lda tp_hi,x
        sta w16b+1                 ; w16b = the stream
        lda tp_rows,x
        sta prows
        lda tp_cols,x
        asl
        asl
        asl                        ; 8 * the columns (40 at most): bit 8 is the carry
        sta pspan
        lda #0
        rol
        sta pspan+1
        lda #<TBUF
        sta tp
        lda #>TBUF
        sta tp+1
@ctl:   ldy #0
        lda (w16b),y               ; the control byte
        cmp #RLE_END
        beq @done
        inc w16b
        bne @skip
        inc w16b+1
@skip:  cmp #RLE_RUN
        bcs @run
        tax                        ; n + 1 literals
        inx
@lit:   lda (w16b),y
        sta (tp),y
        iny
        dex
        bne @lit
        tya                        ; the stream on by the literals (C = 0: the cmp)
        adc w16b
        sta w16b
        bcc @adv
        inc w16b+1
        bcs @adv                   ; (always: inc leaves the carry)
@run:   sbc #RLE_RUNBIAS           ; C = 1: n - RLE_RUNBIAS copies
        tax
        lda (w16b),y               ; the byte to repeat
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

; ---------------------------------------------------------------- a list menu
; ----------------------------------------------------------------------------
; menu_list: a page of items with a cursor; returns the one chosen
;   In:    menu_ptr = a table of the items' strings (words); A = the items; X =
;          the first item's y; mstep = the rows' step
;   Out:   A = the chosen item's index, Z from it; mtop, mcount, msel, mlast,
;          last_keys
;   Uses:  A X Y, ptr, draw_text's, tmp, tmp3
;   Pre:   menu_begin has run (the ring is black: the items are drawn on it)
; Up and down move the cursor, fire or right chooses.  The page is shown once
; the items are drawn; a move redraws only the two cursor rows (right after the
; vsync menu_keys waited for) in the displayed page.  The strings' table is read
; through this routine's own operand (@mt0): the image is in RAM.
; ----------------------------------------------------------------------------
menu_list:
        ldy menu_ptr
        sty @mt0+1
        ldy menu_ptr+1
        sty @mt0+2
        sta mcount
        stx mtop
        lda #$FF
        sta last_keys              ; every key held counts as held, not pressed
        ldx #0
        stx msel                   ; (X = 0: a stz would cost the Model B a lda)
@it:    stx tmp3                   ; the item
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
        ldx tmp3
        jsr item_y                 ; X = its y
        jsr text_centred
        ldx tmp3
        inx
        cpx mcount
        bne @it
        jsr @cursor                ; A = 0 = msel (draw_text's)
        jsr menu_show
@loop:  jsr menu_keys
        sta tmp
        and #K_UP
        beq @skip
        dec msel                   ; 0 -> $FF and back: nothing above
        bpl @move
        inc msel
@skip:  lda tmp
        and #K_DOWN
        beq @skip2
        ldx msel
        inx
        cpx mcount
        bcs @skip2                 ; nothing below
        stx msel
        bcc @move                  ; (always: the bcs fell through)
@skip2: lda tmp
        and #(K_FIRE|K_RIGHT)
        beq @loop
        lda #SFX_SELECT
        jsr sfx_request
        lda msel
        rts
@move:  lda #SFX_MOVE
        jsr sfx_request
        lda mlast                  ; the cursor moved: erase the old row's, draw the new
        ldx #<blank_str
        ldy #>blank_str
        jsr @curstr
        lda msel
        jsr @cursor
        beq @loop                  ; (always: draw_text's Z = 1)
@cursor:                           ; the cursor at item A (and remember where)
        sta mlast
        ldx #<cursor_str
        ldy #>cursor_str
@curstr:                           ; the string at Y:X on item A's row, centred
        stx ptr
        sty ptr+1
        tax
        jsr item_y
        lda #(WINPX-CURSORLEN*GLYPHW)/2   ; centred, as text_centred puts the items
        jmp draw_text

; ----------------------------------------------------------------------------
; item_y: an item's row
;   In:    X = the item; mtop, mstep
;   Out:   A = X = mtop + X*mstep
;   Uses:  A X (C clobbered)
; ----------------------------------------------------------------------------
item_y: lda mtop
@step:  dex                        ; X steps of mstep (X < 128: 0 goes negative)
        bmi @done
        clc
        adc mstep
        bcc @step                  ; (always: every row is on the screen, < 256)
@done:  tax
        rts

; ---------------------------------------------------------------- the screens
; ----------------------------------------------------------------------------
; title_menu: the title page -- the logo and the two items
;   In:    mus_on (the tune keeps playing back from the help)
;   Out:   A = 0 START GAME, 1 HELP (menu_list's), Z from it
;   Uses:  everything
; ----------------------------------------------------------------------------
title_menu:
        lda mus_on
        bne @skip
        jsr music_start            ; the tune, unless it is playing already
@skip:  jsr menu_begin
        lda #MENU_LOGO_X
        sta spx
        lda #MENU_LOGO_Y+TITLE_DY
        sta spy
        lda #TP_LOGO               ; (the menus' blit reads spx and spy's low
        jsr draw_piece             ;  bytes only)
        lda #<menu1
        sta menu_ptr
        lda #>menu1
        sta menu_ptr+1
        lda #MENU_STEP
        sta mstep
        lda #MENU_NITEMS
        ldx #MENU_ITEMS_Y+TITLE_DY
        jmp menu_list

; ----------------------------------------------------------------------------
; help_screen: the help page -- HELP_N centred lines, until fire or right
;   In:    nothing
;   Out:   Z = 0 (A = the key bits that ended it)
;   Uses:  everything
; ----------------------------------------------------------------------------
help_screen:
        jsr menu_begin
        ldy #2*(HELP_N-1)          ; Y = 2i, the last line first (the lines share no
@l:     sty tmp3                   ;  char row, so the order shows nowhere)
        lda help_tab,y
        sta ptr
        lda help_tab+1,y
        sta ptr+1
        tya                        ; y = i*HELP_PITCH + HELP_Y0 (+ HELP_DY): 2i*4 + 2i
        asl
        asl                        ; (C = 0 from the shifts: 8i < 256)
        .assert HELP_PITCH = 10, error, "help_screen: 2i*4 + 2i is i*HELP_PITCH"
        adc tmp3
        adc #HELP_Y0+HELP_DY
        tax
        jsr text_centred
        ldy tmp3
        dey
        dey
        bpl @l
        jsr menu_show
        lda #$FF
        sta last_keys
@loop:  jsr menu_keys
        and #(K_FIRE|K_RIGHT)
        beq @loop
        rts

; ----------------------------------------------------------------------------
; level_select: the level chooser -- the main levels reached so far, centred
;   In:    A = the highest main level reached, 0..7 (max_level)
;   Out:   A = the chosen one, 0..A in
;   Uses:  everything
; The n = A+1 items are LEVEL_STEP apart, or LEVEL_STEP_TIGHT when the list
; would not fit the window: on the Model B's 84 px all eight are 92 tall at 12,
; 78 at 10.  The first item's y = (VISLINES/2 - MENU_BAND_PX - GLYPHH -
; (n-1)*step) / 2, the list centred in the picture with the bar's band (the
; screens' rule, above), and 0 when that is negative: text goes on any row.
; ----------------------------------------------------------------------------
level_select:
        pha
        jsr menu_begin
        lda #<level_names
        sta menu_ptr
        lda #>level_names
        sta menu_ptr+1
        pla                        ; A = n-1
        tax
        inx
        stx tmp                    ; tmp = n
        sta tmp2
        asl tmp2                   ; tmp2 = (n-1)*2
        .assert LEVEL_STEP = 12 && LEVEL_STEP_TIGHT = 10, error, "level_select builds (n-1)*12 and takes (n-1)*2 off it"
        asl
        asl
        sta tmp3                   ; (n-1)*4
        asl
        adc tmp3                   ; A = (n-1)*12 (C = 0: (n-1)*8 <= 56)
        ldy #LEVEL_STEP
        cmp #VISLINES/2 - GLYPHH + 1   ; the list's height against the window's
        bcc @skip
        sbc tmp2                   ; C = 1: (n-1)*12 - (n-1)*2 = (n-1)*10
        ldy #LEVEL_STEP_TIGHT
        clc
@skip:  sty mstep
        eor #$FF                   ; (VISLINES/2 - MENU_BAND_PX - GLYPHH - A) / 2:
        adc #VISLINES/2 - MENU_BAND_PX - GLYPHH + 1   ;  -A-1, + (.. + 1) (C = 0 both
        bcs @skip2                 ;  ways in); no carry: negative, so 0
        lda #0
@skip2: lsr
        tax                        ; X = the first item's y
        lda tmp
        jmp menu_list

; ----------------------------------------------------------------------------
; win_lose: the end of a game -- YOU WIN or YOU LOSE, big Cleo animated, the
;   score and the hi-score, until fire or right
;   In:    A = 1 won, 0 lost; score, hi_score (BCD)
;   Out:   Z = 0 (A = the key bits that ended it); mus_on = 0
;   Uses:  everything (menu_list's variables as its own: mtop the flag, mcount
;          the frame shown, mbuf the frame in TBUF, msel the counter)
; The page: the words at the top, big Cleo at BIGCLEO_Y, the two score rows at
; the bottom.  Big Cleo's frame comes from cleo_frame; it is unpacked a frame
; ahead, while the page stands, and copied in (blit) right after the vsync
; menu_keys waited for, so the copy is meant to run ahead of the beam in the
; displayed page.
; ----------------------------------------------------------------------------
win_lose:
        sta mtop                   ; the flag (not a zp temp: draw_text uses tmp..tmp4)
        jsr music_stop             ; silent
        jsr menu_begin
        .assert TP_WIN = TP_LOSE - 1, error, "win_lose picks the piece as TP_LOSE - mtop"
        lda mtop                   ; YOU WIN at WL_WORDS_Y, YOU LOSE a char row lower
        eor #1
        asl
        asl                        ; (C = 0 from the shifts)
        adc #WL_WORDS_Y+WL_DY
        sta spy
        lda mtop
        asl                        ; (C = 0)
        adc #WL_YOU_X              ; YOU at 36 winning, 34 losing
        sta spx
        lda #TP_YOU
        jsr draw_piece
        lda spx
        adc #WINPX/2-WL_YOU_X-1    ; C = 1 (draw_piece's): WIN at 82, LOSE at 80; C = 0
        sta spx
        lda #TP_LOSE+1
        sbc mtop                   ; C = 0: TP_LOSE - mtop = TP_WIN or TP_LOSE
        jsr draw_piece
        ; ---- the two score rows: a label at WL_LABEL_X, its number at WL_VALUE_X
        lda #<str_score
        sta ptr
        lda #>str_score
        sta ptr+1
        stz t16                    ; draw_number's: the score (draw_text leaves t16)
        ldx #WL_SCORE_Y+WL_DY
@srow:  lda #WL_LABEL_X
        jsr draw_text
        lda #WL_VALUE_X
        ldx ty                     ; the row's y (draw_text's)
        jsr draw_number
        ldx ty                     ; (draw_number's stx ty wrote the same y)
        cpx #WL_HISCORE_Y+WL_DY
        beq @sdone                 ; both rows drawn
        lda #<str_hiscore
        sta ptr
        lda #>str_hiscore
        sta ptr+1
        lda #hi_score-score        ; the hi-score's (score + 3)
        sta t16
        ldx #WL_HISCORE_Y+WL_DY
        bne @srow                  ; (always: the y is not 0)
        ; ---- big Cleo, animated in the displayed page
@sdone: lda #$FF
        sta last_keys
        sta mcount                 ; no frame shown yet
        sta mbuf                   ; none in TBUF
        stz msel                   ; the counter
        lda #BIGCLEO_X             ; her place, once: nothing in the loop moves spx/spy
        sta spx
        lda #BIGCLEO_Y+WL_DY
        sta spy
@loop:  jsr cleo_frame             ; the frame for msel
        cmp mcount
        beq @same                  ; the one shown
        sta mcount
        jsr @unpk                  ; unless in TBUF already (unpacked a frame ahead, below)
        jsr blit                   ; right after menu_keys' vsync
@same:  jsr menu_show
        inc msel
        jsr cleo_frame             ; the next frame, unpacked now, while the page stands
        cmp mcount
        beq @skip2
        jsr @unpk
@skip2: jsr menu_keys
        and #(K_FIRE|K_RIGHT)
        beq @loop
@wret:  rts
; ---- @unpk: frame A into TBUF unless mbuf says it is there
@unpk:  cmp mbuf
        beq @wret
        sta mbuf
        jmp unpack

; ----------------------------------------------------------------------------
; cleo_frame: big Cleo's frame for the counter
;   In:    msel = the counter; mtop = 1 won, 0 lost
;   Out:   A = the piece: TP_CLEO0 + (BIGCLEO_WIN0 +) the 2-bit frame
;   Uses:  A X, w16, w16b
; The frame is two bits of a sequence word shifted by msel & CLEO_SEQ_MASK
; (even, so a frame holds for two counts): WIN_SEQ (16 bits) winning, LOSE_SEQ
; (24) losing.
; ----------------------------------------------------------------------------
cleo_frame:
        lda msel
        and #CLEO_SEQ_MASK
        tax                        ; X = the shift, both arms
        lda mtop
        beq @lframe
        .assert WIN_SEQ < $10000, error, "cleo_frame takes WIN_SEQ's top byte as 0"
        lda #<WIN_SEQ              ; winning: BIGCLEO_WIN0 + ((WIN_SEQ >> X) & 3)
        sta w16
        lda #>WIN_SEQ
        sta w16+1
        lda #^WIN_SEQ              ; 0: 24 bits with zeros on top, as 16 shifted
        beq @shift                 ; (always)
@lframe:
        lda #<LOSE_SEQ             ; losing: (LOSE_SEQ >> X) & 3
        sta w16
        lda #>LOSE_SEQ
        sta w16+1
        lda #^LOSE_SEQ
@shift: sta w16b
        jsr shr24x
        lda w16
        and #3                     ; (2 bits a frame)
        ldx mtop                   ; (X dead: shr24x left 0)
        beq @drawc
        ora #BIGCLEO_WIN0
@drawc: clc
        adc #TP_CLEO0
        rts

; ----------------------------------------------------------------------------
; shr24x: w16b:w16 (24 bits, w16b the top) >>= X
;   In:    X = the shift count; w16, w16b
;   Out:   w16 shifted; X = 0; A = the count
;   Uses:  A X
; ----------------------------------------------------------------------------
shr24x: txa                        ; Z from X
        beq @done
@s:     lsr w16b
        ror w16+1
        ror w16
        dex
        bne @s
@done:  rts

; ----------------------------------------------------------------------------
; draw_number: a score, times 100, as digits
;   In:    t16 = 0 the score, hi_score-score the hi-score (BCD, three bytes, the
;          ones first); A = x (even); X = y
;   Out:   as draw_text; NUMBUF = the digits drawn
;   Uses:  as draw_text, and Y
; NUM_DIGITS digits (the top byte's high nibble is not shown), leading zeros
; blanked but the last, then "00": the score counts in hundreds.  It enters
; draw_text past the stores of A and X, which it has made itself.
; ----------------------------------------------------------------------------
draw_number:
        sta tx
        stx ty
        ldy t16
        ldx #NUM_DIGITS-1          ; NUMBUF 4..0: each byte's low nibble, then its high
@d:     lda score,y
        and #$0F                   ; the low BCD digit
        ora #'0'
        sta NUMBUF,x
        dex
        bmi @z                     ; five stored: the top byte's high nibble unshown
        lda score,y
        lsr
        lsr
        lsr
        lsr
        ora #'0'
        sta NUMBUF,x
        iny
        dex
        bpl @d                     ; (always: X = 2 or 0 here)
@z:                                ; leading zeros to spaces, but the last digit (X = $FF:
@loop:  inx                        ;  the digit loop ends on dex from 0)
        lda NUMBUF,x
        cmp #'0'
        bne @skip
        lda #' '
        sta NUMBUF,x
        cpx #NUM_DIGITS-2
        bne @loop
@skip:  lda #'0'                   ; then the "00", and the end
        sta NUMBUF+NUM_DIGITS
        sta NUMBUF+NUM_DIGITS+1
        stz NUMBUF+NUM_DIGITS+2
        lda #<NUMBUF
        sta ptr
        lda #>NUMBUF
        sta ptr+1
        jmp draw_text+6            ; past its sta tx / stx ty (3 bytes each: MNUBSS)

; ---------------------------------------------------------------- tables
font_blank: .res GLYPHH, 0         ; the erased glyph ('_' in a string)
pair_tab:   .byte 0, MODE1_DOTS_R, MODE1_DOTS_L, MODE1_DOTS_L|MODE1_DOTS_R
                                    ; a game pixel pair's screen byte in logical 3
                                    ; (yellow): the right one lit, the left, both
cursor_str: .byte ">                 <", 0
CURSORLEN = * - cursor_str - 1
        .assert ((WINPX-CURSORLEN*GLYPHW)/2) .mod 2 = 0, error, "draw_text's x must be even"
blank_str:  .byte "_                 _", 0   ; the cursor's erase
        .assert * - blank_str = CURSORLEN + 1, error, "blank_str erases the cursor's width"
menu1:      .word s_start, s_help
s_start:    .byte "START GAME", 0
s_help:     .byte "HELP", 0
help_tab:   .word h1, h2, h3, h4, h5, h6
h1:         .byte "Z X TO RUN", 0
h2:         .byte "RETURN TO JUMP", 0
h3:         .byte "SLASH TO THROW", 0
h4:         .byte "COLLECT ALL", 0
h5:         .byte "STARS TO OPEN", 0
h6:         .byte "BONUS LEVEL", 0
level_names: .word l0, l1, l2, l3, l4, l5, l6, l7
l0:         .byte "CITY GATES", 0
l1:         .byte "TUTANKHAMUN", 0 ; (levels 1 and 5: the maps swapped, convert.py)
l2:         .byte "VINEYARDS", 0
l3:         .byte "CHEFREN", 0
l4:         .byte "CITADELS", 0
l5:         .byte "CHEOPS", 0
l6:         .byte "ALEXANDRIA", 0
l7:         .byte "NEFERTITI", 0
str_score:  .byte "SCORE", 0
str_hiscore: .byte "HISCORE", 0
