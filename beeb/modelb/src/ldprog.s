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
        .ifndef BHW                 ; (cpu.inc's flag: the Model B's hardware unless the
BHW = 1                             ;  build says -D BHW=0, the converged Master)
        .endif
        .include "defs_ld.inc"      ; the addresses the game exports (build.sh)
        .include "files.inc"        ; the disc's sector table (mkdfs.py table)
ROMSEL     = $FE30
ROMSEL_CPY = $F4
ACCCON     = $FE34                  ; (the converged Master: bit 2, X, puts the CPU's
                                    ;  $3000-$7FFF in shadow RAM -- where STAGE is)
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
ftab:   FILE "SPRX"                 ; 0: the sprites placed per level (imgtab's file 0)
        FILE "SPRC"                 ; 1: the sprites every level draws: bank 4, once
        FILE "SPRC"                 ; 2: (unused)
        FILE "TILES0"               ; 3, 4: the tile set's outdoor and shared files
        FILE "TILES1"
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
        FILE "TILES2"               ; 24: and its indoor file
tfi:    .byte 3, 4, 24              ; the tile set's files (convert.py TSET) by number
FI_SPRX = 0
FI_SPRC = 1
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
  .if .not BHW
        jmp scopy                   ; (a placed image comes from the stage)
; the converged Master stages the shared files in shadow RAM: a copy out of the stage
; reads with ACCCON X set (X and Y kept, as bcopy leaves them)
scopy:  lda ACCCON
        ora #4
        sta ACCCON
        jsr bcopy
        lda ACCCON
        and #$FB
        sta ACCCON
        rts
  .endif
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
  .if .not BHW
        jsr mainram                 ; (X here is whatever buffer the game drew last)
  .endif
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
        ; ---- the tiles (convert.py pack_tiles): each of the level's files of the tile
        ; set staged in turn and its tiles copied to their slots in bank 5 -- the full
        ; tiles by the tile list (the files: each one's number and its full tiles; then
        ; each tile's index in its file), the half tiles by the half list (index,
        ; row | the file's place in the list << 1)
        lda #4
        jsr section
        ldy #0
        lda (src),y
        sta nfiles
        asl                         ; the first index: past the files (C = 0: n < 128)
        sec
        adc src
        sta lp
        lda src+1
        adc #0
        sta lp+1
        .assert <TILES = 0, error, "TILES page-aligned"
        sty tbase                   ; the next full slot (Y = 0)
        lda #>TILES
        sta tbase+1
        sty fnum
@file:  lda #4
        jsr section
        lda fnum
        asl
        tay
        iny
        lda (src),y                 ; the set's file
        tay
        lda tfi,y
        jsr stage
        lda #4
        jsr section
        lda fnum
        asl
        tay
        iny
        iny
        lda (src),y                 ; this file's full tiles
        sta nt
@tile:  lda nt
        beq @halves
        lda tbase
        sta dst
        lda tbase+1
        sta dst+1
        ldy #0
        lda (lp),y
        clc                         ; (the whole tile)
        ldx #64
        jsr tcopy
        lda tbase
        clc
        adc #64
        sta tbase
        bcc :+
        inc tbase+1
:       inc lp
        bne :+
        inc lp+1
:       dec nt
        jmp @tile
@halves:                            ; this file's half tiles, to their slots: HALFOFF
        lda LV_HDR+28               ; slots into the halves' page
        asl
        asl
        asl
        asl
        asl
        sta hdst
        lda LV_HDR+27
        sta hdst+1
        lda #0
        sta item
@half:  lda item
        cmp LV_HDR+23
        beq @nextfile
        lda #8
        jsr section
        lda item
        asl
        tay
        iny
        lda (src),y                 ; the row | the file << 1
        lsr
        cmp fnum
        bne @hnext
        lda (src),y
        lsr                         ; C = the row
        dey
        lda (src),y                 ; the index
        ldx hdst
        stx dst
        ldx hdst+1
        stx dst+1
        ldx #32
        jsr tcopy
@hnext: lda hdst
        clc
        adc #32
        sta hdst
        bcc :+
        inc hdst+1
:       inc item
        jmp @half
@nextfile:
        inc fnum
        lda fnum
        cmp nfiles
        beq :+
        jmp @file
:
        ; ---- the halves' fill pairs, where the halves end (hdst): the fill indexes
        ; them by the slot from the halves' page, so its operands sit 2*HALFOFF below
        lda #9
        jsr section
        lda hdst
        sta dst
        lda hdst+1
        sta dst+1
        lda LV_HDR+23               ; two bytes a half
        asl
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_TILES
        jsr bcopy                   ; (bank 7 back after it)
        lda LV_HDR+28
        asl
        eor #$FF
        sec
        adc hdst                    ; hdst - 2*HALFOFF: low in X, high in Y
        tax
        lda hdst+1
        sbc #0
        tay
        ; ---- the tile shape, into bank 5's variables (read here, with bank 7 in)
        lda LV_HDR+24
        sta sv_half0
        clc
        sbc LV_HDR+28
        sta sv_halfsub              ; half0 - HALFOFF - 1: the gather's borrow
        lda LV_HDR+25
        sta sv_half1
        lda LV_HDR+26
        sta sv_half2
        lda LV_HDR+27
        sta sv_halfhi
        lda LV_HDR+29
        sta sv_mir0
        lda PB_TILES
        jsr pgbank                  ; (X, Y kept)
        stx HPAIR0
        sty HPAIR0+1
        inx
        stx HPAIR1
        bne :+
        iny
:       sty HPAIR1+1
        lda sv_half0
        sta half0
        lda sv_half1
        sta half1
        lda sv_half2
        sta half2
        lda sv_halfhi
        sta halfhi
        lda sv_halfsub
        sta halfsub
        lda sv_mir0
        sta mir0
        lda PB_LVL
        jsr pgbank
        ; ---- MIRTAB: each mirrored tile's source slot
        lda #10
        jsr section
        lda #<MIRTAB
        sta dst
        lda #>MIRTAB
        sta dst+1
        lda LV_HDR+30
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_TILES
        jsr bcopy
        ; ---- the sprites.  The common block (SPRC: Cleo, the boomerang, the stars) goes
        ; to its fixed place in bank 4 once, and stays; the rest (SPRX) is staged and
        ; the level's subset copied out by its placement list
        lda sprc_ok
        bne @sprx
        lda #FI_SPRC
        jsr stage
        lda #<STAGE
        sta src
        lda #>STAGE
        sta src+1
        lda #<SPRC_BASE
        sta dst
        lda #>SPRC_BASE
        sta dst+1
        lda #<SPRC_LEN
        sta cnt
        lda #>SPRC_LEN
        sta cnt+1
        ldx PB_SPR
        jsr sccopy                  ; the mirrored ones: bank 4
        lda #<(STAGE + SPRC_LEN)
        sta src
        lda #>(STAGE + SPRC_LEN)
        sta src+1
        lda #<SPRC6_BASE
        sta dst
        lda #>SPRC6_BASE
        sta dst+1
        lda #<SPRC6_LEN
        sta cnt
        lda #>SPRC6_LEN
        sta cnt+1
        ldx PB_MAP
        jsr sccopy                  ; the plain ones: the top of bank 6
        inc sprc_ok
@sprx:  lda #FI_SPRX
        sta fnum
  .if BHW
        jsr stage
  .else
        ; the converged Master reads SPRX once and keeps it: HAZEL (8K), ANDY (4K) and
        ; a tail in main RAM; after, the stage is refilled from them, no disc read
        ldx sprx_ok
        bne @unkeep
        jsr stage
        jsr keep
        inc sprx_ok
        bne @sfile                  ; (always)
@unkeep:
        jsr unkeep
  .endif
@sfile: lda #5
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
@plend:
        ; ---- the directory and SPRMASK, as the packer finished them (assets.py)
        lda #11
        jsr section
        lda sprtab
        sta dst
        lda sprtab+1
        sta dst+1
        lda #<(118*8)
        sta cnt
        lda #>(118*8)
        sta cnt+1
        ldx PB_MAP
        jsr bcopy
        lda #12
        jsr section
        lda #<SPRMASK
        sta dst
        lda #>SPRMASK
        sta dst+1
        lda #2*BOXID0
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_LVL
        jsr bcopy
        ; ---- the flat tiles' pairs, into bank 5 with the blitter's fill
        lda #7
        jsr section
        lda #<FLATTAB
        sta dst
        lda #>FLATTAB
        sta dst+1
        lda #2*(NFLAT+2)
        sta cnt
        lda #0
        sta cnt+1
        ldx PB_TILES
  .if BHW
        jmp bcopy                   ; (the tile addresses are arithmetic: drawrect's gather)
  .else
        jsr bcopy
        ; ---- the converged Master: the gather's table, to main RAM, and the screens
        ; (main and shadow) cleared of what the load staged there -- a ring row the
        ; window has not reached yet must not show it
        lda #13
        jsr section
        lda #<LV_PAGE0
        sta dst
        lda #>LV_PAGE0
        sta dst+1
        lda #0
        sta cnt
        lda #2
        sta cnt+1
        ldx PB_LVL
        jsr bcopy
        lda ACCCON
        ora #4
        jsr @clr                    ; shadow
        lda ACCCON
        and #$FB
@clr:   sta ACCCON                  ; (and main, falling in: X clear on the way out)
        lda #0
        sta dst
        tay
        ldx #$30
@cp:    stx dst+1
@cb:    sta (dst),y
        iny
        bne @cb
        inx
        bpl @cp                     ; to $7FFF
        rts
  .endif

; ---- helpers
sccopy:                             ; a copy out of the stage, on either machine
  .if BHW
        jmp bcopy
  .else
        jmp scopy
  .endif
  .if .not BHW
; the converged Master: every load starts with the CPU on main RAM -- the game leaves
; ACCCON X on the buffer it drew last, and the level's file is main RAM's
mainram:
        pha
        lda ACCCON
        and #$F3                    ; X and Y clear
        sta ACCCON
        pla
        rts
; SPRX's residency on the converged Master: the stage (shadow RAM, $3000) to HAZEL
; ($C000, ACCCON Y), ANDY ($8000, ROMSEL bit 7) and main RAM (TAILBUF) -- keep -- and
; back -- unkeep.  Only under a load: interrupts are off, and the MOS's interrupt
; entry is under HAZEL.
SPRX_PAGES = (SPRX_LEN + 255) / 256
        .assert SPRX_PAGES - $30 <= >($2B00 - TAILBUF), error, "SPRX outgrows HAZEL, ANDY and the tail"
        .assert <TAILBUF = 0, error, "TAILBUF page aligned"
keep:   sec
        .byte $24                   ; (bit zp: skips the clc)
unkeep: clc
        php
        lda ACCCON
        ora #$0C                    ; X (the stage) and Y (HAZEL)
        sta ACCCON
        ldx #$20                    ; HAZEL: the stage's first 8K
        lda #>STAGE
        ldy #$C0
        jsr kpart
        lda #$80                    ; ANDY: the next 4K
        sta ROMSEL
        ldx #$10
        lda #>STAGE + $20
        ldy #$80
        jsr kpart
        lda PB_LVL                  ; (bank 7 back, ANDY out)
        jsr pgbank
        ldx #SPRX_PAGES - $30       ; the rest, main RAM
        beq :+
        lda #>STAGE + $30
        ldy #>TAILBUF
        jsr kpart
:       plp
        lda ACCCON
        and #$F3
        sta ACCCON
        rts
kpart:  stx cnt                     ; X pages between the stage's page A and page Y:
        tsx                         ; from the stage (keep: the C its caller pushed is
        pha                         ; set) or to it
        lda $0103,x                 ; (the P keep/unkeep pushed, under this call's return)
        lsr
        pla
        bcc :+
        sta src+1
        sty dst+1
        bcs :++
:       sty src+1
        sta dst+1
:       lda #0
        sta src
        sta dst
        tay
@pg:    lda (src),y
        sta (dst),y
        iny
        bne @pg
        inc src+1
        inc dst+1
        dec cnt
        bne @pg
        rts
  .endif
tcopy:                              ; tile A of the staged file, its row C (or all of it:
        stx cnt                     ; C = 0, X = 64), X bytes to dst in bank 5
        ldx #0
        stx cnt+1
        tax
        lda #0
        ror
        lsr
        lsr                         ; the row: 0 or 32
        sta src
        txa
        and #3
        lsr
        ror
        ror                         ; (t & 3) << 6
        ora src
        sta src
        txa
        lsr
        lsr
        clc
        adc #>STAGE
        sta src+1
        ldx PB_TILES
  .if BHW
        jmp bcopy
  .else
        jmp scopy
  .endif
nfiles: .res 1                      ; (lv_load's: the set's file count,
hdst:   .res 2                      ;  the next half's slot,
sv_half0:   .res 1                  ;  the tile shape on its way to bank 5)
sv_half1:   .res 1
sv_half2:   .res 1
sv_halfhi:  .res 1
sv_halfsub: .res 1
sv_mir0:    .res 1
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
  .if BHW
        jmp readfile
  .else
        pha                         ; the converged Master: into shadow RAM
        lda ACCCON
        ora #4
        sta ACCCON
        pla
        jsr readfile
        lda ACCCON
        and #$FB
        sta ACCCON
        rts
  .endif
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
  .if .not BHW
        jsr mainram
  .endif
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
  .if BHW
        jsr bcopy                   ; (src, cnt lo kept: bcopy, readfile leave them)
  .else
        jsr scopy
  .endif
        lda #FI_TITLE
        jsr stage                   ; (dst lo 0 = <TITLE_ADDR)
        lda #>STAGE
        sta src+1
        lda #>TITLE_ADDR
        sta dst+1
        lda #F_TITLE_N
        sta cnt+1
        ldx PB_MAP
  .if BHW
        jsr bcopy
  .else
        jsr scopy
  .endif
        lda #0                      ; the title pack reaches the resident sprites' part
        sta sprc_ok                 ; in bank 6: the next level puts them back
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
