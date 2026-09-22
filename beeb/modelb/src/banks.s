; ============================================================================
; The banks' static tables and the few routines that exist only here.  Everything
; a level brings -- tiles, map, sprites, directory, its tables -- is loaded into
; the banks by ldprog.s; the menu overlay (bank 5 from MENU_BASE) is the menus with
; the tune and the font, and is loaded the same way.
;
; $8000 of EVERY bank is the same: the far table (the thunk in low RAM reads it
; from whichever bank is paged in); banks 5 and 7 go on with the small tables more
; than one bank's code indexes (sprmul5, the row multiples, the ring modulus).  The
; Master builds these at start-up; here they are assembled.
; ============================================================================
.macro FAR bank, target
        .byte bank, <(target-1), >(target-1)
.endmacro
.macro COMMON_TABLES                ; the far table: the same $40 bytes in every bank
        .assert * = FARTAB, error, "the far table must be at FARTAB in every bank"
        FAR BANK_SPR,   spr4::ds_entry      ; F_SPRLOOP4
        FAR BANK_MAP,   spr6::ds_entry      ; F_SPRLOOP6
        FAR BANK_TILES, drawrect_rows       ; F_DRAWROWS
        FAR BANK_TILES, render5             ; F_RENDER5
        FAR BANK_LVL,   blank_below         ; F_BLANK5 (unused)
        FAR BANK_TILES, title_menu          ; F_TITLE     (the menu overlay)
        FAR BANK_TILES, help_screen         ; F_HELP
        FAR BANK_TILES, level_select        ; F_LEVELSEL
        FAR BANK_TILES, winlose             ; F_WINLOSE
        FAR BANK_LVL,   build_sections      ; F_BUILDSECT
        FAR BANK_LVL,   blank_palette       ; F_BLANKPAL
        FAR BANK_LVL,   set_palette         ; F_SETPAL
        FAR BANK_LVL,   wait_flip           ; F_WAITFLIP
        FAR BANK_LVL,   load_title_b        ; F_LOADTITLE
        FAR BANK_LVL,   music_start         ; F_MUSSTART
        FAR BANK_LVL,   music_stop          ; F_MUSSTOP
        FAR BANK_LVL,   div10_16            ; F_DIV10
        FAR BANK_LVL,   drawsprite          ; F_DRAWSPR
        FAR BANK_LVL,   calc_ring           ; F_CALCRING
        .assert * = FARTAB + 3*NFAR, error, "NFAR does not match the far table"
        .res $40 - 3*NFAR
.endmacro
        .segment "COMMON4"
        COMMON_TABLES
        .segment "COMMON5"
        COMMON_TABLES
        .segment "COMMON6"
        COMMON_TABLES
        .segment "COMMON7"
        COMMON_TABLES

; ---------------------------------------------------------------- main RAM: the small tables
; The Master builds these at start-up; here they are assembled, in the main RAM block
; every bank sees (MRX), beside the code that indexes them from wherever it runs.
        .segment "MRXCODE"
sprmul5:
.repeat MAXSPR, i
        .byte i*5
.endrepeat
mulrowlo:
.repeat RINGROWS, i
        .byte <(i*ROWCHARS)
.endrepeat
mulrowhi:
.repeat RINGROWS, i
        .byte >(i*ROWCHARS)
.endrepeat
ringmodtab:                         ; A = a map char row (brought under RINGROWS*5 by
.repeat RINGROWS*5, i               ; the ringmod macro) -> its ring slot
        .byte i .mod RINGROWS
.endrepeat

; ---------------------------------------------------------------- the sprite banks
; MASKTAB0..3 at the same address in both banks that hold sprite data, so the
; prologue in bank 5 can name a mask page for either; SWAPTAB in bank 4 alone
; (bank 6 draws nothing mirrored: the packer keeps such images out, and that page
; holds data instead).  The values are the Master's init_tables' (MODE 1).
.macro MASK4 f                      ; AND mask by pair: keep what is NOT opaque
  .if f = 0
        .byte $FF
  .elseif f = 1
        .byte $CC
  .elseif f = 2
        .byte $33
  .else
        .byte $00
  .endif
.endmacro
.macro MASK_TABLES
        .assert * = MASKTAB0, error, "MASKTAB0 must be at the same address in both sprite banks"
.repeat 4, kk                       ; MASKTABk[x] = mask4[(x >> (6 - 2k)) & 3]
  .repeat 256, xx
        MASK4 {((xx >> (6 - 2*kk)) & 3)}
  .endrepeat
.endrepeat
.endmacro
        .segment "SPR4SWAP"
        .assert * = SWAPTAB, error, "SWAPTAB must be at SWAPTAB"
.repeat 256, xx                     ; four-dot reversal: bits 7<->4, 6<->5, 3<->0, 2<->1
        .byte ((xx & $88) >> 3) | ((xx & $44) >> 1) | ((xx & $22) << 1) | ((xx & $11) << 3)
.endrepeat
        .segment "SPR4MASK"
        MASK_TABLES
        .segment "SPR6MASK"
        MASK_TABLES

; ---------------------------------------------------------------- main RAM: the mirror's notes
; the mirror's range: A = the first window column written of the row the mirror
; follows, X = the last (0..79).  Those chars sit in the last slot row at wcxm on;
; only the ones up to char 79 are in it (the rest wrapped to slot row 0), and only
; those from wcxm are ever read (display.s).  Called by the tile blitter's head and
; the sprite prologue, so it is in main RAM.
        .segment "FRAG2"
menurec:   .res 10                  ; the menus' one sprite record (the prologue writes it)
        .segment "MRXCODE"
mirdirty:
        clc
        adc wcxm
        cmp #ROWCHARS
        bcs @out
        pha
        txa
        clc
        adc wcxm
        cmp #ROWCHARS
        bcc :+
        lda #ROWCHARS-1
:       tax
        ldy curbuf
        lda #1
        sta mirdty,y
        pla
        cmp mirlo,y
        bcs :+
        sta mirlo,y
:       txa
        cmp mirhi,y
        bcc :+
        sta mirhi,y
:       rts
@out:   rts

; the once-only part of the Master's init_tables that is this bank's, falling into
; the per-level clear its load_level does (the records are bank 7's, the buffers'
; state main RAM's)
        .segment "LGCCODE"
init5:
        lda #BANK_SPR
        sta spbank
        lda #$FF
        sta BUF_BARQ
        sta BUF_BARQ+1
lvreset:
        stz BUF_VALID
        stz BUF_VALID+1
        stz RECCNT
        stz RECCNT+1
        stz DIRTYCNT
        stz DIRTYCNT+1
        rts

; ---------------------------------------------------------------- bank 7: the level
        .segment "LGCLVL"           ; the level's tables, loaded by ldprog.s (the
LV_ATTR0:   .res 256                ; objects go to main RAM: LV_OBJS, defs.inc)
LV_ALTCLS:  .res 256                ; alt class by tile id
LV_ATTR1 = LV_ALTCLS
LV_HDR:     .res 32                 ; header: lw, lh, start, exit, nobj, the special
                                    ; tiles, gset, ntiles, maprow's shift
        .segment "LGCDATA"
LV_ALTTAB:                          ; alt class -> eight altitudes (global)
        .incbin "build/alt.bin"
digits_art:                         ; the HUD's ten digits, 64 bytes each
        .incbin "build/digits.bin"
        .segment "LGCBSS"
; the object state arrays, laid out as the Master's (logic.s): O_STAMP + k*OBJN, then
; the grid heads and chains and the cached bin walk lists.  level_init's clear runs
; 2560 bytes from LV_OBJST, which stays inside these.
LV_OBJST:   .res 16*OBJN
LV_GRID:    .res 128
LV_BOBJ:    .res 256                ; an entry per object per grid cell it covers: up
LV_BNEXT:   .res 256                ; to 255 of them, as the Master's tables
LV_BINSTAR: .res BINMAX
LV_BINOTH:  .res BINMAX
        .assert 16*OBJN + 128 + 512 + 2*BINMAX >= 2560, error, "level_init's clear overruns the arrays"
SPRMASK:    .res 2*BOXID0           ; mask plane address by sprite id (the boxes, from
                                    ; BOXID0, have none): the loader's, read by the
                                    ; prologue (this bank)

; ---------------------------------------------------------------- bank 5: the menu overlay
        .segment "MNUDATA"
MUSIC_ADDR:                         ; 144 bytes of periods (the table itself, here),
        .incbin "build/music.bin"   ; then the note stream
font_art:                           ; the menus' 40 glyphs, 8 bytes each
        .incbin "build/font.bin"
