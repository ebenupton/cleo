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
.macro FAR bank, target, in        ; (in: the bank this copy of the table is in --
        .byte bank                  ;  the bank byte is patched by the loader, cpu.inc)
        BANKREF .sprintf("far_%s_%d", .string(target), in), in
        .byte <(target-1), >(target-1)
.endmacro
.macro COMMON_TABLES in             ; the far table: the same $40 bytes in every bank
        .assert * = FARTAB, error, "the far table must be at FARTAB in every bank"
        FAR BANK_TILES, render5, in                 ; F_RENDER5
        FAR BANK_TILES, select_backbuf, in          ; F_SELBB
        FAR BANK_TILES, title_menu, in              ; F_TITLE     (the menu overlay)
        FAR BANK_TILES, help_screen, in             ; F_HELP
        FAR BANK_TILES, level_select, in            ; F_LEVELSEL
        FAR BANK_TILES, winlose, in                 ; F_WINLOSE
        FAR BANK_LVL, build_sections, in            ; F_BUILDSECT
        FAR BANK_LVL, blank_palette, in             ; F_BLANKPAL
        FAR BANK_LVL, set_palette, in               ; F_SETPAL
        FAR BANK_LVL, load_title_b, in              ; F_LOADTITLE
        FAR BANK_LVL, music_stop, in                ; F_MUSSTOP
        FAR BANK_LVL, div10_16, in                  ; F_DIV10
        FAR BANK_LVL, drawsprite, in                ; F_DRAWSPR
        FAR BANK_LVL, calc_ring, in                 ; F_CALCRING
        FAR BANK_TILES, copy_partial, in            ; F_COPYPART
        FAR BANK_TILES, mark_dirty_x, in            ; F_MARKDIRTY (the logic)
        FAR BANK_TILES, init5, in                   ; F_INIT5     (start-up: with take_over)
        FAR BANK_TILES, ldstop5, in                 ; F_LDSTOP    (a load: display.s)
        .assert * = FARTAB + 3*NFAR, error, "NFAR does not match the far table"
        .res $40 - 3*NFAR
.endmacro
        .segment "COMMON4"
        COMMON_TABLES BANK_SPR
        .segment "COMMON5"
        COMMON_TABLES BANK_TILES
        .segment "COMMON6"
        COMMON_TABLES BANK_MAP
        .segment "COMMON7"
        COMMON_TABLES BANK_LVL

; ---------------------------------------------------------------- the small tables
; The Master builds these at start-up; here they are assembled, each in the bank of
; the code that indexes it: the sprite multiples and the row multiples are bank 7's
; (the prologue, the records, the chain), the ring modulus bank 5's (ringaddr).
        .segment "LGCDATA"
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
        .segment "TILCODE"
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
; copy_partial (bank 5: mirdirty5) and the sprite prologue (bank 7: mirdirty): one
; body, twice.
        .segment "TILBSS"
menurec:   .res 10                  ; the menus' one sprite record (the prologue writes it)
.macro MIRDIRTY_BODY
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
.endmacro
        .segment "TILCODE"
mirdirty5:
        MIRDIRTY_BODY
        .segment "LGCCODE"
mirdirty:
        MIRDIRTY_BODY

; the once-only part of the Master's init_tables that is bank 5's or low RAM's,
; then the interrupt takeover -- in bank 5's low corner, where once-only code costs
; the level nothing.  Bank 7's per-level clear (lvreset) is load_level's.
        .import __TILBSS_RUN__: absolute, __TILBSS_SIZE__: absolute
        .segment "TILLOW"
; callbank's way into this bank (BANKENTRY jumps here): the write bank first -- A is
; the bank, as callbank left it -- then drawrect_clip, which bank 5's own draw_dirty
; also calls directly (with A something else, so the companion cannot sit there).
bank5_entry:
        wrsel BANK_TILES, BANK_TILES
        jmp drawrect_clip
init5:
        .assert __TILBSS_SIZE__ < 256, error, "init5 zeroes TILBSS with an 8-bit index"
        ldx #0
        txa
:       sta __TILBSS_RUN__,x        ; the ring work's state: zero, as the Master's tables
        inx
        cpx #<__TILBSS_SIZE__
        bne :-
        bankimm lda, BANK_SPR, BANK_TILES
        sta spbank
        lda #$FF
        sta BUF_BARQ
        sta BUF_BARQ+1
        jmp take_over
        .segment "LGCCODE"
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
