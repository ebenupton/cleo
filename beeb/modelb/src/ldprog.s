; ============================================================================
; The load-time program: read into LDPROG ($0E00) by disc.s at every level load and
; every return to the title, and run there, in main RAM, where it can page any bank
; in.  The display is black; $1800-$7FFF is its scratch.  A level is gathered from
; the shared files -- a tile set, SPR/SPRAND/BOX, the level's own file -- by the
; lists the packer (tools/assets.py) put in the level file: which tiles, and where
; every image goes.  Bank 7 is paged on entry and on return; read_sectors (disc.s)
; is bank 7's and reads into main RAM.
;
;   LDPROG+0  lv_load     X = level index 0..15
;   LDPROG+3  title_load  the menu overlay to bank 5, the title pack to bank 6
; ============================================================================
        .include "defs_ld.inc"      ; the addresses the game exports (build.sh)
        .include "files.inc"        ; the disc's sector table (mkdfs.py table)
ROMSEL     = $FE30
ROMSEL_CPY = $F4
BANK_SPR   = 4
BANK_TILES = 5
BANK_MAP   = 6
BANK_LVL   = 7
; zero page: the logic's transient temps, which a load may clobber
src   = $A8                         ; 2
dst   = $AA                         ; 2
cnt   = $AC                         ; 2
tmp   = $AE
tmp2  = $AF
ent   = $B0                         ; 2: the directory entry / placement entry
lp    = $B2                         ; 2: list pointer
item  = $B4
fnum  = $B5                         ; the shared file being walked
tbase = $B6                         ; 2: the level file's section table
nt    = $B8

        .segment "CODE"
        jmp lv_load
        jmp title_load

; ---------------------------------------------------------------- the file table
; index -> sector lo, hi, sectors (from files.inc: the disc's own order)
.macro FILE name
        .byte <.ident(.concat("F_", name, "_SEC")), >.ident(.concat("F_", name, "_SEC")), .ident(.concat("F_", name, "_N"))
.endmacro
ftab:   FILE "SPR"                  ; 0..2: the sprite sources, in imgtab's numbering
        FILE "SPRAND"
        FILE "BOX"
        FILE "TILESO"               ; 3, 4: the tile sets
        FILE "TILESI"
        FILE "MENU"                 ; 5
        FILE "TITLE"                ; 6
        FILE "BAR"                  ; 7
        FILE "L0"                   ; 8..23: the levels
        FILE "L1"
        FILE "L2"
        FILE "L3"
        FILE "L4"
        FILE "L5"
        FILE "L6"
        FILE "L7"
        FILE "L8"
        FILE "L9"
        FILE "L10"
        FILE "L11"
        FILE "L12"
        FILE "L13"
        FILE "L14"
        FILE "L15"
FI_TILESO = 3
FI_MENU = 5
FI_TITLE = 6
FI_BAR = 7
FI_L0 = 8

; read file A to dst (main RAM)
readfile:
        sta tmp
        asl
        adc tmp                     ; * 3
        tax
        lda ftab,x
        sta ld_sec
        lda ftab+1,x
        sta ld_sec+1
        lda ftab+2,x
        sta ld_n
        lda dst
        sta ld_dst
        lda dst+1
        sta ld_dst+1
        jmp read_sectors

; copy cnt bytes from src (main RAM) to dst in bank X; bank 7 back afterwards
bcopy:  stx ROMSEL_CPY
        stx ROMSEL
        ldy #0
        ldx cnt+1
        beq @tail
@page:  lda (src),y
        sta (dst),y
        iny
        bne @page
        inc src+1
        inc dst+1
        dex
        bne @page
@tail:  ldx cnt
        beq @done
:       lda (src),y
        sta (dst),y
        iny
        dex
        bne :-
@done:  lda #BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        rts

; ---------------------------------------------------------------- a level
lv_load:
        txa
        clc
        adc #FI_L0
        ldx #<STAGE_LVL
        stx dst
        ldx #>STAGE_LVL
        stx dst+1
        jsr readfile
        ; ---- the tables: the section table's seven offsets are from the file's start
        lda #0
        jsr section                 ; the header
        lda #32
        sta cnt
        lda #0
        sta cnt+1
        lda #<LV_HDR
        sta dst
        lda #>LV_HDR
        sta dst+1
        ldx #BANK_LVL
        jsr bcopy
        lda #1
        jsr section                 ; the objects: 6 a piece, nobj of them
        lda #0
        sta cnt
        sta cnt+1
        ldx LV_HDR+6
        beq @objdone
:       lda cnt
        clc
        adc #6
        sta cnt
        bcc :+
        inc cnt+1
:       dex
        bne :--
@objdone:
        lda #<LV_OBJS
        sta dst
        lda #>LV_OBJS
        sta dst+1
        ldx #BANK_LVL
        jsr bcopy
        lda #2
        jsr section
        lda #<LV_ATTR0
        sta dst
        lda #>LV_ATTR0
        sta dst+1
        jsr copy256
        lda #3
        jsr section
        lda #<LV_ALTCLS
        sta dst
        lda #>LV_ALTCLS
        sta dst+1
        jsr copy256
        ; ---- the shape: maprow's shift, the row stride, the directory's address
        lda LV_HDR+22
        sta mapshr
        ldx LV_HDR                  ; lw: stride = 1 << lw
        lda #1
        sta MAPSTRIDE
        lda #0
        sta MAPSTRIDE+1
:       asl MAPSTRIDE
        rol MAPSTRIDE+1
        dex
        bne :-
        lda LV_HDR                  ; the map is 1 << (lw + lh) bytes, at least 1K
        clc
        adc LV_HDR+1
        sec
        sbc #8
        tax
        lda #1
:       asl
        dex
        bne :-
        clc
        adc #>MAP6
        sta sprtab+1
        lda #0
        sta sprtab
        ; ---- the map, run-length coded, into bank 6
        lda #6
        jsr section
        lda #<MAP6
        sta dst
        lda #>MAP6
        sta dst+1
        jsr unrle
        ; ---- the tiles: the set staged, then the level's picked out by its list
        lda LV_HDR+20
        clc
        adc #FI_TILESO
        jsr stage
        lda #4
        jsr section
        lda src
        sta lp
        lda src+1
        sta lp+1
        lda LV_HDR+21
        sta nt
        lda #<TILES
        sta dst
        lda #>TILES
        sta dst+1
        ldy #0
@tile:  cpy nt
        beq @tiles_done
        sty tmp2
        lda (lp),y                  ; the tile's index in the set: * 64 from STAGE
        pha
        and #3
        lsr
        ror
        ror                         ; (t & 3) << 6
        sta src
        pla
        lsr
        lsr
        clc
        adc #>STAGE
        sta src+1
        lda #64
        sta cnt
        lda #0
        sta cnt+1
        ldx #BANK_TILES
        jsr bcopy                   ; (dst runs on by 64 itself: bcopy's tail loop
        ldy tmp2                    ;  leaves dst where it started -- step it)
        lda dst
        clc
        adc #64
        sta dst
        bcc :+
        inc dst+1
:       iny
        bne @tile
@tiles_done:
        ; ---- the sprites: each source file staged in turn, the placement list walked
        lda #0
        sta fnum
@sfile: lda fnum
        jsr stage
        lda #5
        jsr section
        lda src
        sta lp
        lda src+1
        sta lp+1
@pl:    ldy #0
        lda (lp),y
        cmp #$FF
        beq @plend
        sta item
        jsr imgent                  ; ent -> imgtab's entry for the item
        ldy #0
        lda (ent),y
        cmp fnum
        bne @mask
        ldy #1                      ; the image: src = STAGE + offset, cnt = length
        jsr srccnt
        ldy #2
        lda (lp),y
        sta dst
        iny
        lda (lp),y
        sta dst+1
        ldy #1
        lda (lp),y
        tax
        jsr bcopy
@mask:  ldy #5
        lda (ent),y
        cmp fnum
        bne @plnext
        ldy #8
        lda (ent),y
        iny
        ora (ent),y
        beq @plnext                 ; no mask
        ldy #6
        jsr srccnt
        ldy #4
        lda (lp),y
        sta dst
        iny
        lda (lp),y
        sta dst+1
        ldy #1
        lda (lp),y
        tax
        jsr bcopy
@plnext:
        lda lp
        clc
        adc #6
        sta lp
        bcc @pl
        inc lp+1
        jmp @pl
@plend: inc fnum
        lda fnum
        cmp #3
        bne @sfile
        ; ---- the directory and SPRMASK, from the template and the placement list
        lda sprtab
        sta dst
        lda sprtab+1
        sta dst+1
        lda #<SPRMASK
        sta ent
        lda #>SPRMASK
        sta ent+1
        lda #<sprdir
        sta lp
        lda #>sprdir
        sta lp+1
        lda #118
        sta nt
@dir:   ldy #0
        lda (lp),y
        sta item
        cmp #$FF
        beq @dnone
        jsr findplace               ; src -> the placement entry, or C set
        bcs @dnone
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        ldy #2
        lda (src),y
        ldy #0
        sta (dst),y
        ldy #3
        lda (src),y
        ldy #1
        sta (dst),y
        ldy #2
:       lda (lp),y
        sta (dst),y
        iny
        cpy #8
        bne :-
        ldy #1
        lda (src),y                 ; the bank: bank 6's images carry the flag
        cmp #BANK_MAP
        bne :+
        ldy #6
        lda (lp),y
        ora #$10
        sta (dst),y
:       lda #BANK_TILES
        sta ROMSEL_CPY
        sta ROMSEL
        ldy #4
        lda (src),y
        ldy #0
        sta (ent),y
        ldy #5
        lda (src),y
        ldy #1
        sta (ent),y
        jmp @dnext
@dnone: lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        lda #0
        ldy #7
:       sta (dst),y
        dey
        bpl :-
        lda #BANK_TILES
        sta ROMSEL_CPY
        sta ROMSEL
        lda #0
        tay
        sta (ent),y
        iny
        sta (ent),y
@dnext: lda #BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        lda lp
        clc
        adc #8
        sta lp
        bcc :+
        inc lp+1
:       lda dst
        clc
        adc #8
        sta dst
        bcc :+
        inc dst+1
:       lda ent
        clc
        adc #2
        sta ent
        bcc :+
        inc ent+1
:       dec nt
        beq :+
        jmp @dir
:
        ; ---- the bar template, straight into place
        lda #<BARADDR
        sta dst
        lda #>BARADDR
        sta dst+1
        lda #FI_BAR
        jsr readfile
        ; ---- the tile address table, in bank 5 with the tiles
        lda #BANK_TILES
        sta ROMSEL_CPY
        sta ROMSEL
        jmp build_tileaddr          ; ends in pagelogic: bank 7, and its rts is ours

; ---- helpers
section:                            ; A = section 0..6 -> src = its start in the staged file
        asl
        tay
        lda STAGE_LVL,y
        clc
        adc #<STAGE_LVL
        sta src
        lda STAGE_LVL+1,y
        adc #>STAGE_LVL
        sta src+1
        rts
copy256:                            ; src -> dst (bank 7), 256 bytes
        lda #0
        sta cnt
        lda #1
        sta cnt+1
        ldx #BANK_LVL
        jmp bcopy
stage:                              ; file A -> STAGE
        ldx #<STAGE
        stx dst
        ldx #>STAGE
        stx dst+1
        jmp readfile
imgent:                             ; item -> ent = imgtab + item*10
        lda #0
        sta ent+1
        lda item
        asl
        rol ent+1
        asl
        rol ent+1
        asl
        rol ent+1                   ; * 8
        sta ent
        lda item
        asl
        bcc :+
        inc ent+1
        clc
:       adc ent                     ; + * 2
        sta ent
        bcc :+
        inc ent+1
:       lda ent
        clc
        adc #<imgtab
        sta ent
        lda ent+1
        adc #>imgtab
        sta ent+1
        rts
srccnt:                             ; (ent),Y = offset lo, hi, length lo, hi -> src, cnt
        lda (ent),y
        clc
        adc #<STAGE
        sta src
        iny
        lda (ent),y
        adc #>STAGE
        sta src+1
        iny
        lda (ent),y
        sta cnt
        iny
        lda (ent),y
        sta cnt+1
        rts
findplace:                          ; item -> src = the placement entry; C = 1 if none
        lda #5
        jsr section
:       ldy #0
        lda (src),y
        cmp #$FF
        beq @none
        cmp item
        beq @found
        lda src
        clc
        adc #6
        sta src
        bcc :-
        inc src+1
        bne :-
@none:  sec
        rts
@found: clc
        rts
unrle:                              ; src (packed) -> dst in bank 6: c < 128 = c+1
        lda #BANK_MAP               ; literals follow; c >= 128 = the next byte c-126 times
        sta ROMSEL_CPY
        sta ROMSEL
@c:     lda dst+1
        cmp #>(MAP6 + $2000)        ; the map is 8K at most: stop there whatever the
        bcs @end                    ; stream says
        ldy #0
        lda (src),y
        tax                         ; (the control byte's sign, after the step: inc
        jsr @next                   ;  sets the flags from the pointer)
        txa
        bmi @run
        clc
        adc #1
        sta tmp
@lit:   lda (src),y
        jsr @next
        sta (dst),y
        jsr @dnext
        dec tmp
        bne @lit
        beq @c
@run:   sec
        sbc #126
        sta tmp
        lda (src),y
        jsr @next
@r:     sta (dst),y
        jsr @dnext
        dec tmp
        bne @r
        beq @c
@next:  inc src                     ; (A untouched)
        bne :+
        inc src+1
:       rts
@dnext: inc dst
        bne :+
        inc dst+1
:       rts
@end:   lda #BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        rts

; ---------------------------------------------------------------- the menus
title_load:
        lda #FI_MENU
        jsr stage
        lda #<STAGE
        sta src
        lda #>STAGE
        sta src+1
        lda #<MENU_BASE
        sta dst
        lda #>MENU_BASE
        sta dst+1
        lda #0
        sta cnt
        lda #F_MENU_N
        sta cnt+1
        ldx #BANK_TILES
        jsr bcopy
        lda #FI_TITLE
        jsr stage
        lda #<STAGE
        sta src
        lda #>STAGE
        sta src+1
        lda #<TITLE_ADDR
        sta dst
        lda #>TITLE_ADDR
        sta dst+1
        lda #0
        sta cnt
        lda #F_TITLE_N
        sta cnt+1
        ldx #BANK_MAP
        jmp bcopy

; ---------------------------------------------------------------- the packer's tables
imgtab: .incbin "build/imgtab.bin"  ; per item: file, offset, length, mask file, offset, length
sprdir: .incbin "build/sprdir.bin"  ; the directory template: item, kind, W, h, rx, ry, flags, lines
