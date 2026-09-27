; ============================================================================
; Cleo's tables in bank 7: the game's image (the altitude classes, the HUD's
; digits, the object state) and the menus' image (the tune, the font, the title
; pieces).  The engine's are beebgame's banks.s.
; ============================================================================
        .segment "GAMEDATA"
LV_ALTTAB:                          ; alt class -> eight altitudes (global)
        .incbin "alt.bin"
digits_art:                         ; the HUD's ten digits, 16 bytes each: a nibble per
        .incbin "digits.bin"      ; byte column and two game rows (assets.py)
DIGTOP:     .incbin "digtab.bin", 0, 16   ; a nibble's top scanline byte
DIGBOT:     .incbin "digtab.bin", 16, 16  ; and its bottom one
        .segment "GAMEBSS"
; the object state arrays, laid out as logic.s names them: O_STAMP + k*OBJN, then
; the grid heads and chains and the cached bin walk lists.  level_init's clear runs
; 2560 bytes from LV_OBJST, which stays inside these.
LV_OBJST:   .res 16*OBJN
LV_GRID:    .res 128
LV_BOBJ:    .res 256                ; an entry per object per grid cell it covers: up
LV_BNEXT:   .res 256                ; to 255 of them
LV_BINSTAR: .res BINMAX
LV_BINOTH:  .res BINMAX
        .assert 16*OBJN + 128 + 512 + 2*BINMAX >= 2560, error, "level_init's clear overruns the arrays"

; ---------------------------------------------------------------- bank 7: the menus' image
        .segment "MNUDATA"
MUSIC_ADDR:                         ; 144 bytes of periods (the table itself, here),
        .incbin "music.bin"   ; then the note stream
font_art:                           ; the menus' 40 glyphs, 8 bytes each
        .incbin "font.bin"
        .include "title.inc"        ; the title pieces' directory (assets.py): tp_lo,
title_art:                          ; tp_hi, tp_cols, tp_rows; their streams (menu.s
        .incbin "title.bin"         ; unpack)
