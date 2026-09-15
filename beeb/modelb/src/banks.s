; ============================================================================
; The banks' tables and data, and the few routines that exist only here.
;
; $8000-$80FF of EVERY bank is the same: the far table (the thunk in low RAM reads
; it from whichever bank is paged in), and the small tables more than one bank's
; code indexes (sprmul5, the row multiples, the ring modulus).  The Master builds
; these at start-up; here they are assembled.
; ============================================================================
.macro COMMON_TABLES full           ; the far table alone in banks 4 and 6, whose
        .assert * = FARTAB, error, "the far table must be at FARTAB in every bank"
        .byte BANK_TILES, <(render_core-1),     >(render_core-1)        ; F_RENDCORE
        .byte BANK_SPR,   <(spr4::ds_entry-1),  >(spr4::ds_entry-1)     ; F_SPRLOOP4
        .byte BANK_MAP,   <(spr6::ds_entry-1),  >(spr6::ds_entry-1)     ; F_SPRLOOP6
        .byte BANK_TILES, <(mark_dirty_far-1),  >(mark_dirty_far-1)     ; F_MARKDIRTY
        .byte BANK_TILES, <(lvreset-1),         >(lvreset-1)            ; F_LVRESET
        .byte BANK_TILES, <(init5-1),           >(init5-1)              ; F_INIT5
  .if full
        .res $30 - 3*NFAR
        .assert * = sprmul5, error
.repeat MAXSPR, i
        .byte i*5
.endrepeat
        .res $20 - MAXSPR
        .assert * = mulrowlo, error
.repeat RINGROWS, i
        .byte <(i*ROWCHARS)
.endrepeat
        .res $18 - RINGROWS
        .assert * = mulrowhi, error
.repeat RINGROWS, i
        .byte >(i*ROWCHARS)
.endrepeat
        .res $18 - RINGROWS
        .assert * = ringmodtab, error
.repeat 128, i                      ; A = a map char row -> its ring slot: 128 rows
        .byte i .mod RINGROWS       ; is the tallest map (64 tiles)
.endrepeat
  .else
        .res $20 - 3*NFAR
  .endif
.endmacro
        .segment "COMMON4"
        COMMON_TABLES 0
        .segment "COMMON5"
        COMMON_TABLES 1
        .segment "COMMON6"
        COMMON_TABLES 0
        .segment "COMMON7"
        COMMON_TABLES 1

; ---------------------------------------------------------------- the sprite banks
; SWAPTAB and MASKTAB0..3, at the same address in both banks that hold sprite data,
; so the prologue in bank 5 can name a mask page for either.  The values are the
; Master's init_tables' (MODE 1).
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
.macro SWAP_TABLE
        .assert * = SWAPTAB, error, "SWAPTAB must be at the same address in both sprite banks"
.repeat 256, xx                     ; four-dot reversal: bits 7<->4, 6<->5, 3<->0, 2<->1
        .byte ((xx & $88) >> 3) | ((xx & $44) >> 1) | ((xx & $22) << 1) | ((xx & $11) << 3)
.endrepeat
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
        SWAP_TABLE
        .segment "SPR4MASK"
        MASK_TABLES
        .segment "SPR6SWAP"         ; bank 6 draws nothing mirrored: the packer keeps
  .if SPR6_MIRROR                   ; such images out, and the page holds data instead
        SWAP_TABLE
  .else
        .incbin "build/spr6s.bin"
  .endif
        .segment "SPR6MASK"
        MASK_TABLES

        .segment "SPR4HOLE"         ; $8030-$82FF of bank 4: mask planes, packed there
        .incbin "build/spr4h.bin"
        .segment "SPR4DATA"         ; the images (and their masks) the packer put here
        .incbin "build/spr4.bin"
        .segment "SPR6DATA"         ; and the rest, in bank 6 (directory flag $10)
        .incbin "build/spr6.bin"
        .segment "SPR6HOLE"         ; $8180-$82FF of bank 6: more of them
        .incbin "build/spr6h.bin"

; ---------------------------------------------------------------- bank 5: tiles
        .segment "TILDATA"
TILES:                              ; this level's tiles, 64 bytes each, by tile id
        .assert (* & $FF) = 0, error, "TILES must be page aligned (build_tileaddr)"
        .incbin "build/tiles.bin"
SPRMASK:                            ; mask plane address by sprite id
        .incbin "build/sprmask.bin"
        .segment "TILBSS"
LV_PAGE0:  .res 512                 ; tile id -> address (build_tileaddr), page aligned

; the mirror's range: A = the first window column written of the row the mirror
; follows, X = the last (0..79).  Those chars sit in the last slot row at wcxm on;
; only the ones up to char 79 are in it (the rest wrapped to slot row 0), and only
; those from wcxm are ever read (display.s).
        .segment "TILCODE"
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

; the per-level clear the Master's load_level does in main RAM
lvreset:
        stz BUF_VALID
        stz BUF_VALID+1
        stz RECCNT
        stz RECCNT+1
        stz DIRTYCNT
        stz DIRTYCNT+1
        rts

; and the once-only part of its init_tables that is this bank's
init5:
        lda #BANK_SPR
        sta spbank
        lda #$FF
        sta BUF_BARQ
        sta BUF_BARQ+1
        jsr lvreset
        jmp build_tileaddr          ; (ends in pagelogic: harmless under a far call)

; ---------------------------------------------------------------- bank 6: the map
        .segment "MAPDATA"
LV_MAP:                             ; row major, 128 x 64 tile ids
        .assert (* & $FF) = 0, error, "LV_MAP must be page aligned (maprow)"
        .incbin "build/map.bin"
SPR_TABLE:                          ; the sprite directory: the prologue in bank 5 reads
        .incbin "build/sprtab.bin"  ; an entry through low RAM (dirfetch)

; ---------------------------------------------------------------- bank 7: the level
        .segment "LGCDATA"          ; (page aligned: <LV_OBJS = 0 is what the logic assumes)
LV_OBJS:                            ; 6 bytes an object
        .incbin "build/objs.bin"
LV_ATTR0:                           ; attribute (kill/push) by tile id
        .incbin "build/attr.bin"
LV_ALTCLS:                          ; alt class by tile id
        .incbin "build/altcls.bin"
LV_ATTR1 = LV_ALTCLS
LV_HDR:                             ; header: lw, lh, start, exit, nobj, the special tiles
        .incbin "build/hdr.bin"
LV_ALTTAB:                          ; alt class -> eight altitudes
        .incbin "build/alt.bin"
MUSIC_ADDR:                         ; 144 bytes of periods (the table itself, here),
        .incbin "build/music.bin"   ; then the note stream
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
title_res:  .res 1                  ; (the menus': game.s clears it)
