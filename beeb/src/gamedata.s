; ============================================================================
; Cleo's tables in bank 7: the game's image (the altitude classes, the HUD's
; digits, the object state) and the menus' image (the tune, the font, the title
; pieces).  The engine's are beebgame's banks.s.
; ============================================================================
        .segment "GAMEDATA"
alt_tab:                           ; alt class -> eight altitudes (global)
        .incbin "alt.bin"
digits_art:                        ; the HUD's ten digits, DIGIT_PACKED bytes each: a
        .incbin "digits.bin"      ; nibble per byte column and two game rows (assets.py)
DIGTAB_N = 16                      ; a nibble's values: each one's screen bytes
digtop:     .incbin "digtab.bin", 0, DIGTAB_N          ; a nibble's top scanline byte
digbot:     .incbin "digtab.bin", DIGTAB_N, DIGTAB_N   ; and its bottom one
        .include "sprgeom.inc"      ; the sprites' geometry by shape (assets.py): the
                                    ; engine's prologue reads it
        .segment "GAMEOBJ"          ; (page aligned, after GAMEBSS and GAMEROWH: the cfg)
; the object state arrays, laid out as logic.s names them: O_STAMP + k*OBJ_MAX, then
; the grid heads and chains and the cached bin walk lists.  level_init's clear runs
; OBJCLR_PAGES pages from LV_OBJST, which stays inside these.
LV_OBJST:   .res 16*OBJ_MAX
LV_GRID:    .res GRIDN
LV_BOBJ:    .res BINLINKS          ; an entry per object per grid cell it covers: up
LV_BNEXT:   .res BINLINKS          ; to 255 of them
LV_BINSTAR: .res BINMAX
LV_BINOTH:  .res BINMAX
        .assert 16*OBJ_MAX + GRIDN + 2*BINLINKS + 2*BINMAX >= OBJCLR_PAGES*256, error, "level_init's clear overruns the arrays"

; ---------------------------------------------------------------- bank 7: the menus' image
        .segment "MNUDATA"
music_addr:                        ; 144 bytes of periods (the table itself, here),
        .incbin "music.bin"   ; then the note stream
font_art:                          ; the menus' 40 glyphs, 8 bytes each
        .incbin "font.bin"
        .include "title.inc"        ; the title pieces' directory (assets.py): tp_lo,
title_art:                         ; tp_hi, tp_cols, tp_rows; their streams (menu.s
        .incbin "title.bin"         ; unpack)
