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
; The banks are whichever sockets the boot loader found RAM in: it left their numbers
; in PBANK (low BSS, one byte per bank 4..7).  This program comes off the disc at
; every load, so the loader cannot patch it as it does the banks' code: every switch
; here reads the physical bank from PBANK, and the placement lists' bank bytes
; (4 or 6, the packer's) go through it too.
BANK_MAP   = 6                      ; (the placement lists' number for bank 6)
PB_SPR     = PBANK
PB_TILES   = PBANK + 1
PB_MAP     = PBANK + 2
PB_LVL     = PBANK + 3
; A Solidisk or Watford board takes the bank a store goes to from a register of its own
; (defs.inc BOARD_*): the game's code was patched for it at boot, this program reads
; PBOARD and does it by hand -- pgbank pages the bank in A (X, Y kept), wrx sets the
; write bank to the socket in X.  Not hot: a load makes a few dozen switches.
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
readfile:                           ; file A -> dst (page-aligned: its low byte is not read)
        ldx dst+1
readpage:                           ; file A -> page X (main RAM)
        stx ld_dst+1
        sta tmp
        asl
        adc tmp                     ; * 3
        tax
        lda ftab,x
        sta ld_sec
        lda ftab+1,x
        sta ld_sec+1
        lda ftab+2,x
        sta ld_n                    ; (ld_dst's low byte: 0 from disc_boot, and never
        .assert <LDPROG = 0, error, "ld_dst's low byte is 0"
        jmp read_sectors            ;  changed -- every destination is a page)

; copy cnt bytes from src (main RAM) to dst in the bank the placement entry (lp) names
; -- the packer's number, 4 or 6, for the socket that is that bank here
plcopy: ldy #1
        lda (lp),y
        tay
        ldx PBANK-4,y               ; (Y: bcopy reloads it)
; copy cnt bytes from src (main RAM) to dst in bank X (a socket); bank 7 back afterwards
bcopy:  stx ROMSEL_CPY
        stx ROMSEL
        jsr wrx                     ; the write bank too (A is free here)
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
@done:  lda PB_LVL
        jsr pgbank
        rts

pgbank: sta ROMSEL_CPY              ; A = the socket to page (and to write to)
        sta ROMSEL
        pha
        txa
        pha
        tsx
        lda $0102,x                 ; the socket again
        tax
        jsr wrx
        pla
        tax
        pla
        rts
wrx:    lda PBOARD                  ; X = the socket a store should reach
        beq @r
        lsr                         ; 1 (Watford) -> C set, 2 (Solidisk) -> C clear
        bcc @s
        sta WRSEL_WATFORD,x         ; Watford: the address is the bank, the value nothing
@r:     rts
@s:     stx WRSEL_SOLIDISK          ; Solidisk: the bank on port B (the loader set DDRB)
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
        sty cnt+1                   ; Y = 0: section 0's index
        .assert <LV_HDR = 0, error, "dst's low byte is Y's 0"
        sty dst
        lda #>LV_HDR
        sta dst+1
        ldx PB_LVL
        jsr bcopy
        lda #1
        jsr section                 ; the objects: 6 a piece, nobj of them
        lda #0                      ; (cnt+1 is 0 still: the header's copy set it)
        ldx LV_HDR+6
        beq @objdone
:       clc
        adc #6
        bcc :+
        inc cnt+1
:       dex
        bne :--
@objdone:
        sta cnt
        .assert <LV_OBJS = 0, error, "dst's low byte is 0 still"
        lda #>LV_OBJS               ; main RAM (level_init reads them once, before
        sta dst+1                   ; the first render)
        ldx PB_LVL
        jsr bcopy
        lda #2
        jsr section
        .assert <LV_ATTR0 = 0, error, "dst's low byte is 0 still"
        lda #>LV_ATTR0
        sta dst+1
        jsr copy256
                                    ; (src: the copy left it at section 3, which
                                    ;  follows the 256-byte attr in the file)
        .assert LV_ALTCLS = LV_ATTR0 + $100, error, "copy256 leaves dst at LV_ALTCLS"
        jsr copy256
        ; ---- the shape: maprow's shift, the row stride, the directory's address
        lda LV_HDR+22
        sta mapshr
        stx MAPSTRIDE+1             ; X = 0: copy256 ends in bcopy
        ldx LV_HDR                  ; lw: stride = 1 << lw
        lda #1
:       asl
        rol MAPSTRIDE+1
        dex
        bne :-
        sta MAPSTRIDE
        lda LV_HDR                  ; the map is 1 << (lw + lh) bytes, at least 1K
        adc LV_HDR+1                ; (C = 0: the stride's last rol shifted out a 0)
        adc #$F8                    ; - 8 (C = 0: lw + lh < 256)
        tax
        lda #1
:       asl
        dex
        bne :-
        adc #>MAP6                  ; (C = 0: the map is under 32K)
        sta sprtab+1
        stx sprtab                  ; X = 0 from the loop
        ; ---- the map, run-length coded, into bank 6
        lda #6
        jsr section
        .assert <MAP6 = 0, error, "dst's low byte is 0 still"
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
        sta lp+1                    ; (section returns A = src+1)
        lda src
        sta lp
        lda LV_HDR+21
        sta nt
        lda #>TILES
        sta dst+1
        ldy #0
        sty dst                     ; <TILES = 0
        .assert <TILES = 0, error, "sty dst wants TILES page-aligned"
        sty cnt+1                   ; 64 bytes a tile: bcopy leaves cnt alone
        lda #64
        sta cnt
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
        ldx PB_TILES
        jsr bcopy                   ; (bcopy leaves dst where it started, and
        tya                         ;  Y = cnt = 64: step dst by it)
        clc
        adc dst
        sta dst
        ldy tmp2
        bcc :+
        inc dst+1
:       iny
        bne @tile
@tiles_done:
        ; ---- the half tiles: one 32-byte row each, from the page after the full tiles;
        ; their pair table follows them and the blitter's fill is patched to find it
        lda #8
        jsr section
        sta lp+1                    ; (section returns A = src+1)
        lda src
        sta lp
        lda LV_HDR+23               ; the count (two list bytes a half), the ids' ranges
        asl                         ; and the halves' page, the packer's, into bank 5's
        sta nt                      ; variables
        lda LV_HDR+24               ; (read with bank 7 in: the header is its)
        sta tmp
        lda LV_HDR+25
        pha                         ; LV_HDR+25 (half1)
        lda LV_HDR+26
        pha                         ; (half2)
        ldy LV_HDR+27               ; (halfhi; pgbank keeps Y)
        lda LV_HDR+24               ; the gather's subtraction: half0 less the first
        sec                         ; half's slot in its page (the halves follow the
        sbc LV_HDR+28               ; full tiles at once, not from the next page)
        tax                         ; (halfsub; pgbank keeps X)
        lda PB_TILES
        jsr pgbank
        lda tmp
        sta half0
        pla
        sta half2
        pla
        sta half1
        sty halfhi
        stx halfsub
        lda PB_LVL
        jsr pgbank
        lda LV_HDR+28               ; the halves start slot HALFOFF into their page
        asl
        asl
        asl
        asl
        asl
        sta dst
        sty dst+1                   ; (Y = LV_HDR+27 still)
        ldy #0
        sty cnt+1                   ; 32 bytes a half (bcopy leaves cnt alone)
        lda #32
        sta cnt
@half:  cpy nt
        beq @halves_done
        sty tmp2
        lda (lp),y                  ; the tile's index in the set ...
        tax
        iny
        lda (lp),y                  ; ... and which of its rows: 0 or 1 (the packer's)
        lsr                         ; C = the row
        txa
        and #3
        ror
        ror
        ror                         ; (t & 3) << 6 | row << 5
        sta src
        txa
        lsr
        lsr
        clc
        adc #>STAGE
        sta src+1
        ldx PB_TILES
        jsr bcopy                   ; (Y = cnt = 32 after: its tail loop's count)
        tya
        clc
        adc dst
        sta dst
        bcc :+
        inc dst+1
:       ldy tmp2
        iny
        iny
        bne @half
@halves_done:
        lda #9                      ; the pairs, right after the halves
        jsr section
        lda LV_HDR+28               ; the fill indexes them by the slot from the page,
        asl                         ; two bytes each: the operands sit 2*HALFOFF below
        eor #$FF                    ; the table (dst is where the halves ended):
        sec                         ; dst - 2*HALFOFF, low in X, high in Y
        adc dst
        tax
        lda dst+1
        sbc #0
        tay
        lda LV_HDR+23               ; two bytes a half
        asl
        sta cnt
        lda #0
        rol
        sta cnt+1
        lda PB_TILES
        jsr pgbank                  ; (X, Y kept)
        stx HPAIR0
        sty HPAIR0+1
        inx
        stx HPAIR1
        bne :+
        iny
:       sty HPAIR1+1
        ldx PB_TILES
        jsr bcopy                   ; (bank 7 back after it)
        ; ---- the sprites: each source file staged in turn, the placement list walked
        lda #0
        sta fnum
@sfile: jsr stage                   ; (A = fnum both ways in)
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
        jsr plcopy                  ; to the placement's bank
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
        jsr plcopy                  ; to the placement's bank
@plnext:
        lda lp
        clc
        adc #6
        sta lp
        bcc @pl
        inc lp+1
        bne @pl                     ; (lp+1 is never 0)
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
@dir:   lda PB_MAP                  ; the directory's bank, for both paths
        jsr pgbank
        ldy #0
        lda (lp),y
        sta item
        cmp #$FF
        beq @dnone
        jsr findplace               ; src -> the placement entry, or C set
        bcs @dnone
        ldy #2
        lda (src),y
        ldy #0
        sta (dst),y
        ldy #3
        lda (src),y
        ldy #1
        sta (dst),y
        iny
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
:       ldy #4                      ; the mask: X = lo, Y = hi
        lda (src),y
        tax
        iny
        lda (src),y
        tay
@dmask: lda PB_LVL
        jsr pgbank              ; box ids (the last 15) have no entry
        lda nt
        cmp #16
        bcc @dnext
        tya
        ldy #1
        sta (ent),y
        txa
        dey
        sta (ent),y
        bcs @dnext                  ; (C set: the cmp)
@dnone: lda #0
        ldy #7
:       sta (dst),y
        dey
        bpl :-
        tax                         ; no mask: X = Y = 0
        tay
        beq @dmask
@dnext:
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
        ; ---- the flat tiles' pairs, into bank 5 with the blitter's fill
        lda #7
        jsr section
        lda #<FLATTAB
        sta dst
        lda #>FLATTAB
        sta dst+1
        lda #32
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_TILES
        jmp bcopy                   ; (the tile addresses are arithmetic: drawrect's gather)

; ---- helpers
section:                            ; A = section 0..9 -> src = its start in the staged file
        asl                         ; (C = 0: A < 128)
        tay
        lda STAGE_LVL,y
        sta src
        lda STAGE_LVL+1,y
        adc #>STAGE_LVL
        sta src+1
        rts
        .assert <STAGE_LVL = 0, error, "section: STAGE_LVL page-aligned"
copy256:                            ; src -> dst (bank 7), 256 bytes
        stx cnt                     ; (X = 0: bcopy's exit, both callers)
        inx
        stx cnt+1
        ldx PB_LVL
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
        rol ent+1                   ; * 4 (C = 0)
        adc item                    ; * 5
        bcc :+
        inc ent+1
:       asl
        rol ent+1                   ; * 10 (C = 0)
        adc #<imgtab
        sta ent
        lda ent+1
        adc #>imgtab
        sta ent+1
        rts
srccnt:                             ; (ent),Y = offset lo, hi, length lo, hi -> src, cnt
        lda (ent),y
        sta src                     ; (<STAGE = 0)
        iny
        lda (ent),y
        clc
        adc #>STAGE
        sta src+1
        .assert <STAGE = 0, error, "srccnt: STAGE's low byte"
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
@found: clc
@none:  rts                         ; (C = 1 from the cmp #$FF)
unrle:                              ; src (packed) -> dst in bank 6: c < 128 = c+1
        lda PB_MAP
        jsr pgbank
@c:     lda dst+1
        cmp #>(MAP6 + $2000)        ; the map is 8K at most: stop there whatever the
        bcs @end                    ; stream says
        ldy #0
        lda (src),y
        jsr @next                   ; (A untouched)
        tax                         ; X = the count, N = the control byte's sign
        bmi @run
        inx                         ; c+1 literals
@lit:   lda (src),y
        jsr @next
        sta (dst),y
        jsr @dnext
        dex
        bne @lit
        beq @c
@run:   sbc #125                    ; (C = 0 from the bcs) c - 126
        tax
        lda (src),y
        jsr @next
@r:     sta (dst),y
        jsr @dnext
        dex
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
@end:   lda PB_LVL
        jmp pgbank

; ---------------------------------------------------------------- the menus
title_load:
        lda #FI_MENU
        jsr stage                   ; (dst = STAGE: its lo 0 = <MENU_BASE)
        lda #0                      ; <STAGE = 0, cnt lo = 0
        sta src
        sta cnt
        lda #>STAGE
        sta src+1
        lda #>MENU_BASE
        sta dst+1
        lda #F_MENU_N
        sta cnt+1
        ldx PB_TILES
        jsr bcopy                   ; (src, cnt lo kept: bcopy, readfile leave them)
        lda #FI_TITLE
        jsr stage                   ; (dst lo 0 = <TITLE_ADDR)
        lda #>STAGE
        sta src+1
        lda #>TITLE_ADDR
        sta dst+1
        lda #F_TITLE_N
        sta cnt+1
        ldx PB_MAP
        jsr bcopy
        ; ---- the bar template, straight into place: once per return to the title, as the
        ; menus never touch it (engine.s menu_sections) and a level does not either
        stx dst                     ; (X = 0 from bcopy; <BARADDR = 0)
        lda #>BARADDR
        sta dst+1
        lda #FI_BAR
        jmp readfile
        .assert <BARADDR = 0, error, "title_load: BARADDR's low byte"
        .assert (<STAGE | <MENU_BASE | <TITLE_ADDR) = 0, error, "title_load: page-aligned"

; ---------------------------------------------------------------- the packer's tables
imgtab: .incbin "build/imgtab.bin"  ; per item: file, offset, length, mask file, offset, length
sprdir: .incbin "build/sprdir.bin"  ; the directory template: item, kind, W, h, rx, ry, flags, lines
