; ============================================================================
; Cleo's tables in bank 7, both machines, at one address on each (layoutcheck):
; the game's image holds the altitude classes, the HUD's packed digits, the
; sprite geometry (GAMEDATA) and the object state arrays (GAMEOBJ); the menus'
; image holds the tune, the font and the title pieces (MNUDATA).  Every .incbin
; is tools/assets.py's output (which runs tools/convert.py over the original's
; data).  The engine's own tables are beebgame's banks.s.  No code.
; ============================================================================
        .segment "GAMEDATA"        ; bank 7, the game's image
alt_tab:    .incbin "alt.bin"      ; an altitude class's 8 bytes, one a tile column
                                    ; (logic.s altof: class*8 + (x & 7)); a level's ids
                                    ; map to classes through LV_ALTCLS
digits_art: .incbin "digits.bin"   ; the HUD's ten digits, DIGIT_PACKED bytes each: by
                                    ; char row, by byte column, two bytes -- game rows
                                    ; 0-1 then 2-3, a nibble a row, the earlier row's
                                    ; high (logic.s bar_digit decodes them)
DIGTAB_N  = 16                     ; a nibble's 16 values
digtop:     .incbin "digtab.bin", 0, DIGTAB_N          ; a nibble -> its screen byte's
digbot:     .incbin "digtab.bin", DIGTAB_N, DIGTAB_N   ;  top scanline, and its bottom
        .include "sprgeom.inc"     ; the sprites' geometry by shape (sprg_ix by id;
                                    ; sprg_w, sprg_rx, sprg_ry, sprg_ln, sprg_fl): the
                                    ; engine's sprite prologue reads it (frame.s)

; ---------------------------------------------------------------- the object state
        .segment "GAMEOBJ"         ; (page aligned, after GAMEBSS and GAMEROWH: the cfg)
; The arrays logic.s names: O_STAMP + k*OBJ_MAX for its 16 fields, then the
; collision grid's heads, its chains and the cached bin walk lists.  level_init
; clears OBJCLR_PAGES pages from LV_OBJST and fills LV_GRID with GRID_NONE.
LV_OBJST:   .res 16*OBJ_MAX        ; a byte a field an object (logic.s O_*)
LV_GRID:    .res GRIDN             ; a cell's first link, GRID_NONE when empty
LV_BOBJ:    .res BINLINKS          ; a link: its object, and the next link (GRID_NONE
LV_BNEXT:   .res BINLINKS          ;  ends the chain, so 255 links at most)
LV_BINSTAR: .res BINMAX            ; the bin walk's lists: the stars, the others
LV_BINOTH:  .res BINMAX
        .assert 16*OBJ_MAX + GRIDN + 2*BINLINKS + 2*BINMAX >= OBJCLR_PAGES*256, error, "level_init's clear overruns the arrays"

; ---------------------------------------------------------------- the menus' image
        .segment "MNUDATA"         ; bank 7, the menus' image
music_addr: .incbin "music.bin"    ; the period table, MUS_TAB_LEN bytes, then the
                                    ; sequence (engine/menus.s; midi2snd.py writes it)
font_art:   .incbin "font.bin"     ; the menus' 40 glyphs, GLYPHH bytes each, a bit a
                                    ; game pixel, the left one bit 7 (convert.py font)
        .include "title.inc"       ; the title pieces' directory, by TP_ index: tp_lo,
                                    ; tp_hi their streams, tp_cols, tp_rows their size
title_art:  .incbin "title.bin"    ; the streams (menu.s unpack)
