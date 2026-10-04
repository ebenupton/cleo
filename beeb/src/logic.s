; ============================================================================
; CLEO - game logic (port of CleoApp.run() from the J2ME original)
; ============================================================================

; ---------------------------------------------------------------- 16-bit macros
.macro mov16 dst, src
        lda src
        sta dst
        lda src+1
        sta dst+1
.endmacro
.macro mov16i dst, imm
        lda #<(imm)
        sta dst
        lda #>(imm)
        sta dst+1
.endmacro
.macro add16 dst, src
        clc
        lda dst
        adc src
        sta dst
        lda dst+1
        adc src+1
        sta dst+1
.endmacro
.macro add16i dst, imm
        clc
        lda dst
        adc #<(imm)
        sta dst
  .if (>(imm) = 0) .and (.not .xmatch({dst}, {dpx}))  ; vy_step reads the high byte from A
        .assert (dst) < $100, error, "add16i: bcc *+4 skips a zero-page inc"
        bcc *+4                     ; no carry: the high byte stands
        inc dst+1
  .else
        lda dst+1
        adc #>(imm)
        sta dst+1
  .endif
.endmacro
.macro sub16 dst, src
        sec
        lda dst
        sbc src
        sta dst
        lda dst+1
        sbc src+1
        sta dst+1
.endmacro
.macro sub16i dst, imm
        sec
        lda dst
        sbc #<(imm)
        sta dst
  .if >(imm) = 0
        .assert (dst) < $100, error, "sub16i: bcs *+4 skips a zero-page dec"
        bcs *+4                     ; no borrow: the high byte stands
        dec dst+1
  .else
        lda dst+1
        sbc #>(imm)
        sta dst+1
  .endif
.endmacro
; dst = a - b
.macro dif16 dst, aa, bb
        sec
        lda aa
        sbc bb
        sta dst
        lda aa+1
        sbc bb+1
        sta dst+1
.endmacro
.macro asr16 var
        lda var+1
        cmp #$80
        ror var+1
        ror var
.endmacro
.macro asl16 var
        asl var
        rol var+1
.endmacro
.macro neg16 var
        sec
        lda #0
        sbc var
        sta var
        lda #0
        sbc var+1
        sta var+1
.endmacro
; sign-extend 8-bit A into dst
.macro sx16 dst
        sta dst
        and #$80
        beq :+
        lda #$FF
:       sta dst+1
.endmacro
; branch if var > imm (signed 16)
.macro bgt16i var, imm, label
        lda var                     ; var > imm is var >= imm+1: ble16i's bias form
        cmp #<((imm)+1)
        lda var+1
        eor #$80
        sbc #(>((imm)+1) ^ $80)
        bcs label
.endmacro
; branch if var < imm (signed 16)
.macro blt16i var, imm, label
        lda var
        cmp #<(imm)
        lda var+1
        eor #$80                    ; bias both sides by $8000 and compare unsigned:
        sbc #(>(imm) ^ $80)         ; the bias on the constant is free at assembly time
        bcc label
.endmacro
; branch if var >= imm (signed 16)
.macro bge16i var, imm, label
        lda var
        cmp #<(imm)
        lda var+1
        eor #$80
        sbc #(>(imm) ^ $80)
        bcs label
.endmacro
; branch if var <= imm (signed 16)
.macro ble16i var, imm, label
        lda var                     ; var <= imm is var < imm+1, so this is blt16i's
        cmp #<((imm)+1)             ; bias form: one instruction and no V fixup
        lda var+1
        eor #$80
        sbc #(>((imm)+1) ^ $80)
        bcc label
.endmacro
; branch if a > b (both 16-bit vars)
.macro bgt16 aa, bb, label
        lda bb
        cmp aa
        lda bb+1
        sbc aa+1
:      bmi label                   ; no V fixup: every caller compares x positions (a map
                                    ; x < 2048, or one plus C>>1), never 2^15 apart
.endmacro
.macro blt16 aa, bb, label
        lda aa
        cmp bb
        lda aa+1
        sbc bb+1
        bvc :+
        eor #$80
:      bmi label
.endmacro
.macro bge16 aa, bb, label
        lda aa
        cmp bb
        lda aa+1
        sbc bb+1
:      bpl label                   ; no V fixup: every caller compares x positions (a map
                                    ; x < 2048, or one plus C>>1), never 2^15 apart
.endmacro
.macro bmi16 var, label
        bit var+1
        bmi label
.endmacro
.macro bpl16 var, label
        bit var+1
        bpl label
.endmacro
; A = max(A - n, 0)  (unsigned)
.macro submin0 n
        sec
        sbc #n
        bcs :+                      ; no borrow: A >= n, the difference stands
        lda #0
:
.endmacro
; branch if var (16) == 0
.macro beq16 var, label
        lda var
        ora var+1
        beq label
.endmacro
.macro bne16 var, label
        lda var
        ora var+1
        bne label
.endmacro

; ---------------------------------------------------------------- object arrays (bank 7)
OBJN    = 149                      ; the most objects a level has (L7B)
MAXFALL = 12                       ; Cleo's fall a frame at most (the camera follows it):
                                   ;  three char rows (the original's 8 a step was 16)
O_STAMP = LV_OBJST
O_TYPE  = O_STAMP + OBJN
O_XL    = O_TYPE + OBJN
O_XH    = O_XL + OBJN
O_YL    = O_XH + OBJN
O_YH    = O_YL + OBJN
O_AL    = O_YH + OBJN
O_AH    = O_AL + OBJN
O_BL    = O_AH + OBJN
O_BH    = O_BL + OBJN
O_CL    = O_BH + OBJN
O_CH    = O_CL + OBJN
O_DL    = O_CH + OBJN
O_DH    = O_DL + OBJN
O_EL    = O_DH + OBJN
O_EH    = O_EL + OBJN

; ---------------------------------------------------------------- game state (zero page, persistent)
        .segment "ZPGAME": zeropage  ; (after the engine's: defs.inc)
BINMAX = BINMAXDEF                ; the bin walk's lists (assets.py: the objects' grid
                                  ; cells under the worst window)
BINI:     .res 1                  ; the bin walk's index (44-64 accesses a frame)
NSTARL:   .res 1                  ; the cached bin walk's lengths: stars,
NOTHL:    .res 1                  ;   everything else
frame:    .res 2
px:       .res 2                  ; player x, y (px)
py:       .res 2
vx:       .res 2                  ; 1/256 px per frame
vy:       .res 2
anim:     .res 1
evframe:  .res 2
facing:   .res 1                  ; 1 = left
running:  .res 1
firing:   .res 1
hurt:     .res 1                  ; invulnerable after hit
control:  .res 1
bx:       .res 2                  ; boomerang
by:       .res 2
bvx:      .res 2
bvy:      .res 2
bcnt:     .res 1
bactive:  .res 1
bounce:   .res 1
stars:    .res 1
startx:   .res 2
starty:   .res 2
exitx:    .res 2
exity:    .res 2
nobj:     .res 1
exiting:  .res 1
level:    .res 1
lives:    .res 1
health:   .res 1
maxlevel: .res 1
lastkeys: .res 1
logicvs:  .res 1
gridsh:   .res 1                  ; log2 of the collision grid width
camoff:   .res 1                  ; window bias: px - camoff = window left (eased 40..120)

seed:     .res 2                  ; rnd's
; transient temps
ox:       .res 2
oy:       .res 2
fa:       .res 2
fb:       .res 2
fc:       .res 2
fd:       .res 2
fe:       .res 2
rx:       .res 2
ry:       .res 2
qx:       .res 2
qy:       .res 2
alt:      .res 1
q1:       .res 1
q2:       .res 1
q3:       .res 1
q4:       .res 1
q5:       .res 1
q6:       .res 1
obj:      .res 1
starclk:  .res 1                  ; the stars' clock, 0..11: a star's spin step is it plus its phase
BINR:     .res 4                  ; the bin walk's rectangle, and its list's validity
BINOK:    .res 1                  ;  (profiled hot: zero page)
gx:       .res 1
gy:       .res 1
gx0:      .res 1
gx1:      .res 1
gy1:      .res 1
bent:     .res 1
otype:    .res 1
t16:      .res 2
t16b:     .res 2
dpx:      .res 2                  ; player step count etc
hx:       .res 2                  ; rx used for hit direction
rise:     .res 2
grow:     .res 1                  ; bucket walk: gy << gridsh
        .zeropage

        .segment "GAMECODE"      

; ============================================================================
; Map queries.  The map is in bank 5 and this code in bank 7, so every touch goes
; through low RAM's maprow/mapbyte/mapput (engine.s), which put bank 7 back.
; ============================================================================
; get map byte (the tile id) at tile (X = tx, A = ty) -> A; mapptr = the row, Y = tx,
; X kept.  The row's address from the level's table (MROWL/MROWH, level_init).
maptile:
        tay
        lda MROWL,y
        sta mapptr
        lda MROWH,y
        sta mapptr+1
        txa
        tay
        jmp mapbyte

; ALTOF: A = a tile id -> A = its alt byte at column qx & 7 (ALTTAB[cls*8 + (qx&7)],
; cls = LV_ALTCLS[id]).  Y clobbered.
.macro ALTOF
        tay
        lda LV_ALTCLS,y
        asl
        asl
        asl
        eor qx                      ; (A & $F8) | (qx & 7): A's low 3 bits are 0
        and #$F8
        eor qx
        tay
        lda LV_ALTTAB,y
.endmacro

; tilexy: X = qx >> 3, A = qy >> 3, carry set if (qx,qy) is inside the map.
; Map sizes are multiples of 256 px, so "0 <= q < size" is just a compare of the high
; byte, and with that byte < 8 the tile coordinate is (hi << 5) | (lo >> 3) in one byte.
tilexy: lda qx+1
        cmp mapw+1
        bcs @out
        lsr                         ; hi <= 7: A = hi >> 1, C = hi & 1
        sta q2
        lda qx
        and #$F8
        ora q2                      ; lo7..lo3, 0, hi2, hi1 (C = hi0)
        ror
        ror
        ror                         ; hi2..hi0, lo7..lo3 (C = 0)
        tax
        lda qy+1
        cmp maph+1
        bcs @out
        lsr                         ; as for x: (hi << 5) | (lo >> 3) by rotation
        sta q2
        lda qy
        and #$F8
        ora q2
        ror
        ror
        ror
@out:   rts                         ; C = 0 inside (the rors), 1 outside (the bcs)

; getinfo: A = alt byte for pixel (qx, qy), 8 if outside the map
getinfo:
        jsr tilexy                  ; X = qx>>3, A = qy>>3
        bcs @out8                   ; (outside: out of line, after the rts)
        jsr maptile
        ALTOF
        rts
@out8:  lda #8                      ; outside the map
        rts

; The map memo: the last tile getaltitude read (mapcol: it and the tiles above and
; below it in its column) and where.  Cleo's queries -- the altitude under her, at
; each pixel of her move across, through her fall, the tile attributes -- land in the
; tile the one before them did more than half the time (test: 57%), and then skip the
; tile arithmetic and the visit to bank 5.  It holds across frames: mok = 0 (none) at a
; level's start and wherever the map is written (mark_pair: the vanishing block's and
; the switch's tiles).
; getaltitude: A = altitude (signed) at pixel (qx, qy)  [qy modified; tp clobbered]
; It reads the tile at (qx, qy) and at most one of the tiles above and below it, so
; the three come from one visit to the map (mapcol) and the rest is arithmetic.  A
; pixel off the map takes the general way (@off), a read at a time through getinfo.
getaltitude:
        lda qy+1                    ; tilexy's, in line, the row into X and the column
        cmp maph+1                  ; into Y
        bcs @offjj
        ldx mok                     ; the same tile as the last read (mapmemo)?
        beq @read
        cmp mkyh
        bne @read
        lda qx+1
        cmp mkxh
        bne @read
        lda qy
        and #$F8
        cmp mky
        bne @read
        lda qx
        and #$F8
        cmp mkx
        bne @read
        lda ma                      ; then its column's three tiles, as mapcol gave them
        sta tp
        lda mb
        sta tp+1
        lda mt
        jmp @have
@offjj: jmp @offj                   ; (off the map: out of reach of a branch)
@read:  lda qy+1
        lsr
        sta q2
        lda qy
        and #$F8
        ora q2
        ror
        ror
        ror
        tax                         ; X = ty
        lda qx+1
        cmp mapw+1
        bcs @offjj
        lsr
        sta q2
        lda qx
        and #$F8
        ora q2
        ror
        ror
        ror
        tay                         ; Y = tx
        lda MROWL,x
        sta mapptr
        lda MROWH,x
        sta mapptr+1
        jsr mapcol                  ; A = the tile, tp = the one above, tp+1 the one below
        sta mt                      ; the memo: this tile, its column's two others, and
        tay                         ;  where it is
        lda tp
        sta ma
        lda tp+1
        sta mb
        lda qx
        and #$F8
        sta mkx
        lda qx+1
        sta mkxh
        lda qy
        and #$F8
        sta mky
        lda qy+1
        sta mkyh
        sta mok                     ; (qy+1 + 1 > 0: inside the map; any nonzero will do)
        inc mok
        tya
@have:  ALTOF
        tax                         ; X = n3 (the alt byte)
        lda qy
        and #7
        sta q5                      ; n5
        txa
        and #15                     ; C = 0 from ALTOF (a class < 32: its third asl)
        sbc q5                      ; (n3 & 15) - n5 - 1: C = 1 iff n5 < (n3 & 15)
        bcs @fnb                    ; n5 < (n3 & 15)
        lda qy                      ; C = 0 from the sbc: +8
        adc #8
        sta qy
        bcc @fbt                    ; no carry: qy+1 as tested at entry, inside the map
        inc qy+1
        lda qy+1                    ; the pixel 8 below: the tile below, or getinfo's 8
        cmp maph+1                  ; past the map's bottom (tilexy's test)
        lda #8
        bcs @fb2
@fbt:   lda tp+1
        ALTOF
@fb2:   lsr
        lsr
        lsr
        lsr
        clc
        adc #9                      ; as @b1's
        sbc q5
        rts
@offj:  lda qy                      ; a pixel off the map: its alt byte is getinfo's 8,
        and #7                      ; so n5 < (n3 & 15) and n4 = 0 always: the tile above
        sta q5                      ; n5
        lda qy                      ; C = 1 from the bcs that came here
        sbc #8
        sta qy
        bcs :+
        dec qy+1
:       jsr getinfo
        jmp @nb2
@fnb:   txa
        lsr
        lsr
        lsr
        lsr                         ; n4
        bne @d2
        lda qy
        sec
        sbc #8
        sta qy
        bcs @fnt                    ; no borrow: qy+1 as tested at entry, inside the map
        dec qy+1
        lda qy+1                    ; the pixel 8 above: the tile above, or getinfo's 8
        cmp maph+1                  ; above the map's top (qy+1 = $FF) or past it
        lda #8
        bcs @nb2
@fnt:   lda tp
        ALTOF                       ; (on into @nb2)
@nb2:   tax
        and #15
        cmp #8
        beq @eq
        lda #0                      ; n4, which was 0: @d2's tail in line
        sec
        sbc q5
        rts
@eq:    txa
        lsr
        lsr
        lsr
        lsr                         ; C = 1: the low nibble is 8
        sbc #8
@d2:    sec
        sbc q5
        rts

; gettileattr: A = attribute byte for the tile at (qx,qy): bits0-2 push+3, bit7 kill ; 3 if outside
gettileattr:
        lda qy+1                    ; tilexy's, in line (as getaltitude's): row into X,
        cmp maph+1                  ; column into Y (gettileattr+2: A = qy+1 already,
        bcs @out                    ;  which that caller has not stored: store it, the
        sta qy+1                    ;  read below loads it again)
        ldx mok                     ; the same tile as getaltitude's last read?
        beq @read
        cmp mkyh
        bne @read
        lda qx+1
        cmp mkxh
        bne @read
        lda qy
        and #$F8
        cmp mky
        bne @read
        lda qx
        and #$F8
        cmp mkx
        bne @read
        lda mt
        jmp @attr
@read:  lda qy+1
        lsr
        sta q2
        lda qy
        and #$F8
        ora q2
        ror
        ror
        ror
        tax                         ; X = ty
        lda qx+1
        cmp mapw+1
        bcs @out
        lsr
        sta q2
        lda qx
        and #$F8
        ora q2
        ror
        ror
        ror
        tay                         ; Y = tx
        lda MROWL,x
        sta mapptr
        lda MROWH,x
        sta mapptr+1
        jsr mapbyte
@attr:  tay
        lda LV_ATTR0,y
        rts
@out:   lda #3                      ; off the map
        rts

; ============================================================================
; Level initialisation (the loader has gathered the level into the banks)
; ============================================================================
; Cleo's fields in the level header (tools/assets.py writes them): the start and the
; exit in tiles; the special tiles from HDR_SPECIAL
HDR_STARTX = 2
HDR_STARTY = 3
HDR_EXITX  = 4
HDR_EXITY  = 5
HDR_SPECIAL = 8
level_init:
        ; header
  .assert starty = startx+2 && exitx = startx+4 && exity = startx+6, error, "level_init: the start and exit words in a row"
  .assert HDR_STARTY = HDR_STARTX+1 && HDR_EXITX = HDR_STARTX+2 && HDR_EXITY = HDR_STARTX+3, error, "level_init: the header's four in a row"
        ldy #6                      ; exity..startx, last to first: Y = 2 * the field
@hdr:   sty gridsh                  ; (gridsh is set below: a free counter till then)
        tya
        lsr
        tay
        lda LV_HDR+HDR_STARTX,y
        jsr @x8                     ; A/X = px lo/hi (Y clobbered)
        ldy gridsh
        sta startx,y
        stx startx+1,y
        dey
        dey
        bpl @hdr
        lda LV_HDR+HDR_NOBJ
        sta nobj
        lda maplw
        sec
        sbc #3
        sta gridsh
        ldx #127                    ; the map's row addresses, for the map queries
@mrow:  txa                         ; (rows past the map's are never read)
        jsr maprow                  ; X kept
        lda mapptr
        sta MROWL,x
        lda mapptr+1
        sta MROWH,x
        dex
        bpl @mrow
        lda #80                     ; the camera starts centred; the lookahead eases in
        sta camoff
        ; clear object state, then grid
        tya                         ; A = 0: maprow left Y = 0 (the last @mrow pass)
        sta BINOK                   ; the cached object list belongs to the old level
        sta mok                     ; and the map memo to its map
        sta dxl                     ; (and a level's start is no move to sweep)
        sta dyl
        sta starclk                 ; the stars' clock: every phase from the level's start
        sta stars
        sta bent
  .assert <O_STAMP = 0, error, "level_init's clear: O_STAMP must be page aligned"
        sta t16                     ; t16 = O_STAMP: ten pages through (t16),y
        ldx #>O_STAMP               ; (t16 is free: @ol sets it before any read)
        stx t16+1
        ldx #10
:       sta (t16),y
        iny
        bne :-
        inc t16+1
        dex
        bne :-
        dex                         ; X = $FF: the stamp loop left X = 0
        txa                         ; A = $FF
:       sta LV_GRID-128,x           ; X = $FF..$80: LV_GRID+127 down to +0
        dex
        bmi :-
        ; objects, last to first
        ldy nobj
        jmp @nextobj+2              ; to the loop's beq @objdone (ldy obj is 2 bytes: obj is zero page); Z is ldy nobj's
:
@ol:    dey
        sty obj
        ; entry pointer = LV_OBJS + obj*6
        lda #(>LV_OBJS) >> 2        ; t16+1 seed: the two rols make it (>LV_OBJS) & $FC
        sta t16+1
        tya
        asl                         ; A = lo(2obj), C = obj.7
        rol t16+1                   ; C = 0: the seed is < $40
        adc obj                     ; A = lo(3obj), C = its carry (obj = Y, sty above)
        bcc @o3
        inc t16+1                   ; t16+1 = 2*seed + hi(3obj)
@o3:    asl                         ; A = lo(6obj), C = bit 8
        sta t16
        rol t16+1                   ; = 4*seed + hi(6obj); C = 0
  .assert ((>LV_OBJS) & 3) < 2, error, "LV_OBJS: the seed needs a second inc"
  .if (>LV_OBJS) & 1
        inc t16+1                   ; an odd page: the bit the seed's >> 2 dropped
  .endif
        ldazx t16                   ; lda (t16), Y kept: it is still obj (X is free
                                    ;  until jsr @x8: the Model B's (t16,x))
        sta otype
        sta O_TYPE,y                ; Y is still obj (sty obj at @ol; nothing since has touched Y)
        ldy #5                      ; the record's bytes 5..1 into q5..q1 (adjacent in zero
@rd:    lda (t16),y                 ;  page): q1 x tiles, q2 y tiles, q3..q5 e0..e2
        sta q1-1,y
        dey
        bne @rd                     ; A = byte 1: q1
        jsr @x8
        ldy obj
        sta O_XL,y
        txa
        sta O_XH,y
        lda q2
        jsr @x8
        ldy obj
        sta O_YL,y
        txa
        sta O_YH,y
        ; the state words O_AL..O_EH start at zero: the clear above covers every O_* array
  .assert 16*OBJN <= 2560, error, "level_init's clear must cover O_AL..O_EH"
        ; bounding box defaults: x0 = (x-1)>>3, y0 = y>>3, x1 = x>>3, y1 = (y+1)>>3
  .if BHW
        ldx q1                      ; max(q1-1, 0) through X (dead here: @box sets it)
        beq @g0
        dex
@g0:    txa
  .else
        lda q1
        beq :+                      ; submin0 1 open-coded: A=0 stays 0, else A-1
        dec a
  .endif
:       lsr
        lsr
        lsr
        sta gx0
        lda q1
        lsr
        lsr
        lsr
        sta gx1
        ldx q2                      ; X is dead here (@box sets it before use)
        txa
        lsr
        lsr
        lsr
        sta gy
        inx                         ; y+1, 8-bit as before
        txa
        lsr
        lsr
        lsr
        sta gy1
        ldy obj
        lda otype                   ; A = otype for the cmps below; X counts it down
        tax                         ;  (X is dead: the handlers and @box set it first)
        beq @t0
        dex
        beq @t1
        dex
        beq @t256a                  ; 2
        dex
        dex
        dex
        cpx #2                      ; 5, 6: X = 0, 1 (3, 4 wrap to $FE, $FF)
        bcs :+
@t256a: jmp @t256
:       cmp #3
        bne :+
        jmp @t3
:       cmp #4
        bne :+
        jmp @t4
:
        cmp #9
        bne :+
        jmp @t9
:
        cmp #11
        bne :+
        jmp @t11
:
        cmp #12
        bne :+
        jmp @t12
:
        jmp @t10                    ; 7, 10: defaults, and e0 into E
@t0:    jsr rnd                     ; (drawn as ever, so the enemies' draws follow as they were)
        lda q5                      ; e2: its phase in the spin, the packer's (balanced
        sta O_AL,y                  ;  over the stars a screen shows at once)
        inc stars
        lda gy                      ; the prologue already left q2>>3 in gy
        sta gy1
        lda q2
        beq :+
        deca                        ; A-1; the carry is dead (lsr follows)
:       lsr
        lsr
        lsr
        sta gy
        jmp @t10                    ; e0 (box class: 0 none/1 cyan/2 black), e1 (an enemy's range covers it) into E
@t1:    lda O_XL,y
        ora #4                      ; x*8 has bit 2 clear: +4 cannot carry into O_XH
        sta O_XL,y
        lda q1
        submin0 2
        lsr
        lsr
        lsr
        sta gx0
        lda q1
        inca                        ; A+1; the carry is dead (lsr follows)
        lsr
        lsr
        lsr
        sta gx1
        lda gy1
        sta gy
        jmp @t10                    ; e0 = its rest state's baked box id (0: none), e1 = an enemy's range covers it (assets.py): into E as for a star
@t256:  lda q3
        jsr @x8                     ; A = lo(q3*8), X = q3>>5 (Y clobbered)
        ldy obj
        sta O_AL,y
        txa
        sta O_AH,y
        jmp @g1                     ; gx1 = (q1 + q3)>>3: @t4's tail, then @box
@t3:    lda q2
        submin0 4
        lsr
        lsr
        lsr
        sta gy
        jmp @box
@rm:    ora #1                      ; A+1 for mod16: the low nibble is clear, so no carry
        sta t16b
        jsr rnd                     ; t16 = rnd16 & $0FFF, then t16 mod t16b
        sta t16
        jsr rnd
        and #$0F
        sta t16+1
        jmp mod16                   ; (it returns C = 0: bcc -> rts)
@t4:    lda q3
        lsr
        lsr
        lsr
        lsr
        sta O_AH,y
        sta t16b+1
        lda q3
        asl
        asl
        asl
        asl
        sta O_AL,y
        ; C = rnd % (A+1) ; D = rnd % (B+1)  (A,B < 4096) -> use rnd16 & mask then reduce
        jsr @rm
        lda t16
        sta O_CL,y
        lda t16+1
        sta O_CH,y
        lda q4
        lsr
        lsr
        lsr
        lsr
        sta O_BH,y
        sta t16b+1
        lda q4
        asl
        asl
        asl
        asl
        sta O_BL,y
        jsr @rm                     ; B+1, likewise
        lda t16
        sta O_DL,y
        lda t16+1
        sta O_DH,y
        lda q2
        beq :+                      ; submin0 1 specialised: max(q2-1, 0)
        sbc #0                      ; C = 0 from mod16's exit (bcc -> rts): A-1
:       lsr
        lsr
        lsr
        sta gy
        lda q2
        clc
        adc q4
        lsr
        lsr
        lsr
        sta gy1
@g1:    lda q1                      ; @t256 joins here
        clc
        adc q3
        lsr
        lsr
        lsr
        sta gx1
        bpl @box                    ; N = 0 after lsr
@t11:   lda gy
@gy1:   sta gy1
        bpl @box                    ; gy = q2>>3 < 32: N = 0
@t9:    lda q2
        submin0 2
        lsr
        lsr
        lsr
        ldx gy                      ; the prologue left q2>>3 in gy: that is gy1
        sta gy
        txa                         ; X is dead: @bx loads it
        bpl @gy1                    ; gy was q2>>3 < 32: N = 0
@t12:   lda q3
        sta O_AL,y
        lda q4
        sta O_BL,y
        lda q5
        sta O_CL,y
@t10:   lda q3                      ; e0, e1: a powerup's baked box id and its "an
        sta O_EL,y                  ;  enemy can reach it" (assets.py); the spike and
        lda q4                      ;  the switch (by @t12) never read E
        sta O_EH,y
@box:   ; insert into grid cells gx0..gx1 x gy..gy1
        ; gy <= gy1 for every object of the 16 levels (no wrap: maps are <= 128 tiles
        ;  high, and the type 4 extents keep q2+q4 < 256): at least one grid row
@bx:    lda gx0                     ; per grid row: gx = gx0, then
        sta gx                      ; cell = gx + (gy << gridsh): the gx loop below
        lda gy                      ; steps the cell index with inx instead of reshifting
        ldx gridsh                  ; >= 2: every map is >= 256 px wide (maplw >= 5)
:       asl
        dex
        bne :-
:       clc
        adc gx
        tax
@cell:  ldy bent
        lda obj
        sta LV_BOBJ,y
        lda LV_GRID,x
        sta LV_BNEXT,y
        tya
        sta LV_GRID,x
        inc bent
        inx                         ; the next cell (X and gx are dead past the row: @bx, @ol
        lda gx                      ;  and the bin walk reload them)
        inc gx
        cmp gx1                     ; the cell just filled was gx1: the row is done
        bne @cell
:       inc gy
        lda gy1                     ; C set <=> gy <= gy1: another grid row
        cmp gy
        bcs @bx
@nextobj:
        ldy obj
        beq @objdone
        jmp @ol
@objdone:
        ; player state
        ldx #4                      ; px, py = startx, starty; vx, vy, anim = 0 (Y = 0 on
@ps:    lda startx,x                ;  both ways in: ldy nobj / ldy obj).  X = 4 copies
        sta px,x                    ;  exitx into vx and clears anim; X = 0 and 1 clear
        sty vx,x                    ;  vx again after
        dex
        bpl @ps
        mov16 evframe, frame
        sty facing
        sty running
        sty firing
        sty bactive
        sty exiting
        sty frame
        sty frame+1
        iny                         ; Y = 1
        sty hurt
        sty control
        rts
; A = tiles -> A/X = px lo/hi
@x8:    tay
        lsr
        lsr
        lsr
        lsr
        lsr
        tax
        tya
        asl
        asl
        asl
        rts

; t16 = t16 mod t16b (unsigned 16 bit, t16 < 4096, t16b >= 1)
mod16:  lda t16
        sec
        sbc t16b
        tax
        lda t16+1
        sbc t16b+1
        bcc :+
        sta t16+1
        stx t16
        bcs mod16                   ; C = 1: the bcc above was not taken
:       rts

; ============================================================================
; Per frame update: one step, at twice the original's rates -- every speed, gravity,
; friction, counter and timer moves two of its steps' worth (frame counts rendered
; frames, so its timers are halved).  Fills the sprite list; sets wx/wy.
; ============================================================================
game_frame:
        inc frame
        bne :+
        inc frame+1
:
  .if BHW
        lda #0                      ; bounce = 0 first: A = 0 serves the clock's wrap
        sta bounce
  .endif
        ldx starclk                 ; the stars' clock: a step a frame, 0..11
        inx
        cpx #12
        bcc @sc0
  .if BHW
        tax                         ; A = 0 (lda #0 above)
  .else
        ldx #0
  .endif
@sc0:   stx starclk
  .if .not BHW
        stz bounce                  ; A is dead: lda health follows
  .endif
        ; ---- camera
        lda health
        beq @cam
        ; horizontal lookahead: ease the window's bias toward 40 (facing right, so
        ; Cleo sits 1/4 from the left and sees ahead) or 120 (facing left, 3/4) by two
        ; pixels a frame -- one character -- so she drifts to 3/4 of the way to her
        ; side of the screen without a visible snap.  (camoff starts at 80 and moves
        ; by 2: it stays even, as both targets are.)
        ldx #40
        lda facing                  ; 1 = left
        beq :+
        ldx #120
:       cpx camoff
        beq @offok
        lda camoff                  ; (C is still cpx's)
        bcs @offup                  ; target > camoff (cpx: C set when X >= camoff)
        sbc #1                      ; C = 0: camoff - 2
        bcs @offst                  ; C = 1: camoff > target >= 40, no borrow
@offup: adc #1                      ; C = 1: camoff + 2
@offst: sta camoff
@offok: lda px
        sec
        sbc camoff
        sta wx
        lda px+1
        sbc #0
        sta wx+1
        ; vertical: Cleo 46 px from the window's top, one for one
        lda py
        sec
        sbc #46
        sta wy
        lda py+1
        sbc #0
        sta wy+1
        jsr clamp_window
@cam:
        setbank BANK_LVL, BANK_LVL
        ; ---- bucket range (16-bit >> 6)
        lda wx                      ; gx0 = wx >> 6 (wx < 16384): shift the top
        asl                         ; two bits of the low byte into the high byte
        tax                         ; X = wx<<1: cpx #$80 below gives C = wx bit 6
        lda wx+1
        rol
        cpx #$80
        rol
        sta gx0
        txa                         ; gx1 = (wx + 159) >> 6 = gx0 + 2 + ((wx & 63) >= 33):
        and #$7E                    ;  X is still wx<<1, so test (wx & 63)*2 >= 66
        cmp #66                     ;  (159 = 2*64 + 31; exact mod 256 for any 16-bit wx)
        lda gx0
        adc #2
        sta gx1
        lda wy                      ; gy = wy >> 6
        asl
        tax                         ; X = wy<<1: cpx #$80 below gives C = wy bit 6
        lda wy+1
        rol
        cpx #$80
        rol
        sta gy
        txa                         ; gy1 = (wy + VISLINES/2-1) >> 6, from gy: + its 64s,
        and #$7E                    ;  + 1 if wy's remainder carries (X is still wy<<1:
        cmp #(64-((VISLINES/2-1) & 63))*2 ;  the remainder doubled)
        lda gy
        adc #(VISLINES/2-1)/64
        sta gy1
        ; ---- the object list, cached between steps.
        ; LV_GRID/LV_BOBJ/LV_BNEXT and every O_TYPE are written only by level_init, so
        ; which objects the walk yields depends on nothing but the bucket rectangle --
        ; and that is unchanged on 77% of frames on L0 and 95% on L6.  So walk the grid
        ; only when the rectangle moves, and keep the deduped list to step through
        ; otherwise.  Order is preserved exactly: it sets the sprite draw order, which
        ; box stars depend on (see convert.py).
        lda gx0
        cmp BINR
        bne @rebuild
        lda gx1                     ; BINOK holds the list's gx1, or 0 for no list: gx1 is
        cmp BINOK                   ;  never 0 (>= 2, wx >= 0), so this one test is both
        bne @rebuild
        lda gy
        cmp BINR+2
        bne @rebuild
        lda gy1
        cmp BINR+3
        bne @rebuild
        jmp @runlist                ; (the traversal between here and it is too far for
@rebuild:                           ;  a branch)
        lda gx0
        sta BINR
        lda gx1
        sta BINOK                   ; the list's gx1 (BINR+1 is not used)
        lda gy
        sta BINR+2
        lda gy1
        sta BINR+3
        zero NSTARL, NOTHL
@rows:  lda gx0
        sta gx
        lda gy                      ; row base = gy << gridsh, once per row
        ldx gridsh                  ; >= 2: every map is >= 256 px wide (maplw >= 5)
:       asl
        dex
        bne :-
        sta grow
@cells: lda grow
        clc
        adc gx
        tax
        lda LV_GRID,x
@walk:  cmp #$FF
        beq @cellend
        sta bent
        tax
        lda LV_BOBJ,x
        tay
        lda frame
        cmp O_STAMP,y
        beq @sk2                    ; already stamped: X is still bent, skip the reload
        sta O_STAMP,y
        lda O_TYPE,y                ; the walk only lists: @runlist processes, on a
        bne @apo                    ; rebuild as on a cached step, so the two take the
        ldx NSTARL                  ; same path through the handlers.  Stars go in their
        cpx #BINMAX                 ; own list: the run then reaches ob_star without
        bcs @full                   ; reading the type or going through the table.
        tya
        sta LV_BINSTAR,x
        inc NSTARL
        bne @skip                   ; NSTARL was < BINMAX: never 0
@apo:   ldx NOTHL
        cpx #BINMAX
        bcs @full
        tya
        sta LV_BINOTH,x
        inc NOTHL
        bne @skip                   ; NOTHL was < BINMAX: never 0
@full:  stz BINOK                   ; more objects than a list holds: process this one
        sty obj                     ; now and rebuild next step rather than lose it
        jsr process_object
        setbank BANK_LVL, BANK_LVL, 2
@skip:  ldx bent
@sk2:   lda LV_BNEXT,x
        jmp @walk
@cellend:
        lda gx
        cmp gx1
        beq :+
        inc gx
        bne @cells                  ; gx < gx1 <= 255: never 0
:       lda gy
        cmp gy1
        beq :+
        inc gy
        jmp @rows
:
@runlist:
        ; The stamp is written exactly as the traversal writes it.  It is only read when
        ; a list is rebuilt, but 'cmp frame' tests the low byte alone: let a stamp go 256
        ; steps stale and an object returning to range matches it and is skipped for
        ; the whole life of the cached list.
        ldx #0                      ; test at the bottom: BINI kept in step with X
        cpx NSTARL
        beq @rlo
@rls:   stx BINI
        ldy LV_BINSTAR,x
        lda frame
        sta O_STAMP,y
        jsr po_star                 ; no type read, no table, no obj (nothing a star
                                    ; runs reads it)
        ldx BINI
        inx
        cpx NSTARL
        bne @rls
@rlo:   ldx #0                      ; test at the bottom: BINI kept in step with X
        cpx NOTHL
        beq @rldone
@rl2:   stx BINI
        ldy LV_BINOTH,x
        lda frame
        sta O_STAMP,y
        sty obj
        jsr process_object
        ldx BINI
        inx
        cpx NOTHL
        bne @rl2
@rldone:
        ; ---- after objects
        lda bounce
        beq :+
        stz vy
        lda #>(-1280)
        sta vy+1
:       ; kill tile under player
  .ifdef DBGTILE                    ; debug build: the score shows the tile byte under
        mov16 qx, px                ; Cleo's feet (its id in the level's tile set;
        clc                         ; 254 cyan, 255 black), refreshed every step
        lda py
        adc #12
        sta qy
        lda py+1
        adc #0
        sta qy+1
        jsr tilexy
        bcc @dbgt
        jsr maptile
        tax                         ; (the readout: BCD)
        lda #0
        sta score
        sta score+1
        sta score+2
        tay
        jsr dbg_bcd
@dbgt:
  .endif
        lda health                  ; dead: nothing hits.  (It was health <> 0 OR hurt = 0:
        beq @nokill                 ;  a fall off the map leaves health 0 with hurt clear,
                                    ;  and a kill tile under her then took 0 to 255, alive.)
        mov16 qx, px                ; (alive, a kill tile hits through the invulnerability)
        clc
        lda py
        adc #12
        sta qy
        lda py+1
        adc #0                      ; A = qy+1, never stored: nothing reads it before it
        jsr gettileattr+2           ;  is next written; enter past gettileattr's lda qy+1
        bpl @nokill
        ; knockback by facing
        lda facing                  ; 0 or 1 (1 = left)
        lsr                         ; C = facing
        ror                         ; A = facing << 7: player_hit tests only hx+1's sign
        sta hx+1                    ; facing left -> hx negative -> vx = +768
  .ifdef DBGHIT
        lda #250                    ; the readout shows 25009 for a kill tile (obj and
        sta obj                     ; otype are free here: the walk is over for this step)
        lda #9
        sta otype
  .endif
        jsr player_hit
@nokill:
        lda health
        beq player_dead             ; in range (player_hit is ~60 bytes)
        jmp player_update



; ============================================================================
; player_hit: knock back. hx = relative x of the enemy (sign used)
; ============================================================================
player_hit:
  .ifdef DBGHIT                     ; debug build (DBGHIT=1 sh build.sh): the score
        lda #0                      ; shows obj*100 + otype of whatever hit us, and
        sta score                   ; addscore is a no-op so it stays until the next hit
        sta score+1
        sta score+2
        ldx obj
        ldy #1                      ; obj hundreds
        jsr dbg_bcd
        ldx otype
        ldy #0                      ; and otype ones
        jsr dbg_bcd
  .endif
        mov16 evframe, frame
        lda #1                      ; bar_touch, inlined
        sta BARDIRTY
        sta hurt
  .if BHW
        lda #0                      ; one zero for three stores and vx+1 below
  .else
        dec a
  .endif
        sta control
        sta vx                      ; both knockback speeds and -1280 have
        sta vy                      ; a zero low byte
        dec health                  ; Z: no health left
        beq :+                      ; A = 0: no knockback, vx+1 = 0
        lda #>768
        bit hx+1
        bmi :+
        lda #>(-768)                ; -768 is $FD00: the HIGH byte is the non-zero one
:       sta vx+1
        lda #>(-1280)
        sta vy+1
        lda #SFX_HIT
        sta SFXREQ
        rts

; ============================================================================
; player dead: fall, then respawn
; ============================================================================
player_dead:
        ; vy and py: the original's two steps (fall2)
        jsr fall2
        clc                         ; py += dpx: fall2 leaves A = dpx, X = dpx+1
        adc py
        sta py
        txa
        adc py+1
        sta py+1
        ; if (frame - evframe) > 30 -> respawn (the original's 60 steps; unsigned
        ; delta: wrap-safe)
        lda frame
        sec
        sbc evframe
        tax
        lda frame+1
        sbc evframe+1
        bne @respawn
        cpx #31
        bcc @draw
@respawn:
        mov16 px, startx
        mov16 py, starty
        mov16 evframe, frame
        lda #3
        sta health
        zero vx, vx+1, vy, vy+1, anim, dxl, dyl   ; (a respawn is no move to sweep;
                                    ;  the Model B's one zero serves the three below too:
                                    ;  dec lives keeps A)
        dec lives
        bne :+
        inc exiting                 ; 0 here (the loop leaves on nonzero): game over
        rts                         ; handled by caller (lives == 0)
:
        sta0 facing, running, firing   ; A = 0 still
        lda #1
        sta hurt
        sta control
        sta BARDIRTY                ; bar_touch, inlined
@draw:  mov16 spx, px
        mov16 spy, py
        lda #26
        jmp addsprite

; ---- the frame's vertical motion: one update a frame, its velocity and its move the
; original's two steps' exactly -- each its gravity, vy = (vy + 80) * 31 >> 5, then
; its move, (vy + 128) >> 8 (MAXDWY0 down at most) -- summed into dpx (MAXFALL down
; at most; X = dpx+1).  No position between them is kept: player_update makes the move
; against the map (the altitude, looked at again until the move is made), and the
; objects test the stretch it covered (dxl, dyl: csweep).  fall2: both with gravity;
; move2: a jump's or a stand's, the first without it and the second with it only if
; rising (the original's second step took @grav on vy < 0).  q5: the first move.
MAXDWY0 = 8                         ; the original's fall a step at most
fall2:  jsr gravity
        jsr step1
        sta q5
        jmp move2g                  ; the second gravity and move: move2's rising tail
move2:  jsr step1
        sta q5
        bit vy+1
        bpl fstep2
move2g: jsr gravity
fstep2: jsr step1
        ldx #$FF                    ; X = dpx+1: $FF up, 0 down
        clc
        adc q5                      ; the two moves (-40..16: a byte, signed)
        bmi @st                     ; up
        inx
        cmp #MAXFALL+1
        bcc @st
        lda #MAXFALL
@st:    sta dpx
        stx dpx+1
        rts
; A = (vy + 128) >> 8, signed: a step's move, at most MAXDWY0 down
step1:  lda vy                      ; C = the carry out of vy low + 128
        cmp #$80
        lda vy+1
        adc #0
        bmi @r
        cmp #MAXDWY0+1
        bcc @r
        lda #MAXDWY0
@r:     rts

; vy = (vy + 80) * 31 >> 5: the original's step of gravity
gravity:
        sec                         ; 2480 - vy is -(vy + 80) + 80*32, so its >> 5 is
        lda #<2480                  ; the original's -(vy + 80) >> 5 plus 80, and vy
        sbc vy                      ; plus it is (vy + 80) * 31 >> 5.  vy is -2048..2480
        sta t16                     ; (gravity's fixed point), so 2480 - vy is 0..4528:
        lda #>2480                  ; positive, under 8192, its >> 5 a byte
        sbc vy+1                    ; A:t16 = 2480 - vy
        .repeat 3
        asl t16                     ; three left shifts: A = (2480 - vy) >> 5, 0..141
        rol a
        .endrepeat
        adc vy                      ; C = 0: bit 13 of 2480 - vy, shifted out last
        sta vy
        bcc @hi
        inc vy+1
@hi:    rts


; ============================================================================
; player alive update
; ============================================================================
player_update:
        ; alt = getAltitude(px, py+16)
                                    ; qx = px already: the kill-tile test, the only way in, set it
        clc
        lda py
        adc #16
        sta qy
        lda py+1
        adc #0
        sta qy+1
        jsr getaltitude
        sta alt
        ; start throw?
        bne @nothrow
        lda keys                    ; down first: rarely held here
        and #K_DOWN
        beq @nothrow
        lda firing
        bne @nothrow
        lda control
        beq @nothrow
        lda bactive
        bne @nothrow
        sta anim                    ; A = 0: bactive, just tested
        inc firing                  ; 0 -> 1: firing was tested zero above
@nothrow:
        lda px                      ; where her move starts (dxl, dyl: at @hdone)
        sta pxs
        lda py
        sta pys
        ; vertical velocity
        bmi16 vy, @grav
        lda alt
        beq :+
        bpl @grav
:       stz vy                      ; both arms zero it: -1280 = $FB00, low byte zero
        ldx firing                  ; X, so A stays 0 (B: stz vy's lda #0)
        bne @stand
        lda control
        beq @stand
        lda keys
        and #(K_UP|K_FIRE)
        beq @stand
        lda #>(-1280)
        sta vy+1
        inx                         ; X = 1 = SFX_JUMP: firing, in X, tested 0 above
        stx SFXREQ
        bne @move                   ; always: X = 1
@grav:  jsr fall2
        bne @mvd                    ; always: fstep2 returns Z = 0 (dex to $FF, cmp unequal, or lda #MAXFALL)
@stand:
  .if BHW
        sta vy+1                    ; A = 0 on every way in
  .else
        stz vy+1
  .endif
        lda #1
        sta control                 ; and on into move2
@move:  jsr move2
@mvd:   txa                         ; X = dpx+1, 0 or $FF (fall2/move2)
        bpl @down
        clc                         ; up: py += dpx, dpx+1 = $FF
        lda py
        adc dpx
        sta py
        bcs @upl
        dec py+1
@upl:   clc                         ; qx = px still: getaltitude keeps it
        lda py
        adc #16
        sta qy
        lda py+1
        adc #0
        sta qy+1
        jsr getaltitude
        sta alt
        bpl @vdone
        inc py
        bne @upl
        inc py+1
        bpl @upl                    ; py+1 < $7F
@dland: sta dpx                     ; alt 0: on the ground, dy = 0 (alt and py stand)
        beq @vdone                  ; always: A = 0
@dlp:                               ; (the ':' below kept: the anonymous count)
:       tax                         ; 0 < alt <= dy: the altitude looks a tile ahead
        clc                         ;  at most, and a frame's fall (12) can reach it --
        adc py                      ;  go alt, and look again from
        sta py                      ;  there (else she stops short, alt 0 in the air:
        bcc :+                      ;  the standing frame)
        inc py+1
:       lda dpx
        stx dpx
        sec
        sbc dpx
        sta dpx                     ; dy - alt
        clc                         ; qx = px still: getaltitude keeps it
        lda py
        adc #16
        sta qy
        lda py+1
        adc #0
        sta qy+1
        jsr getaltitude
        sta alt
@down:  lda alt                     ; dy = min(dy, alt); dpx+1 = 0 here
        beq @dland
        cmp dpx
        beq @dlp
        bcc @dlp                    ; alt > dy (unsigned) falls on, C = 1
@dfit:  sbc dpx                     ; C = 1: cmp's no borrow
        sta alt
        clc                         ; py += dpx
        lda py
        adc dpx
        sta py
        bcc @vdone
        inc py+1
@vdone:
        sec                         ; fell: maph - py - 24 < 0
        lda maph
        sbc py
        tay
        lda maph+1
        sbc py+1
        cpy #24
        sbc #0
        bpl @push
@fell:  mov16 evframe, frame
        zero health, control, vx, vx+1
        jsr bar_touch
        lda #SFX_DIE
        sta SFXREQ
@push:  clc                         ; qx = px still; qy = py + 16 in one pass
        lda py
        adc #<16
        sta qy
        lda py+1
        adc #>16
        sta qy+1
        jsr gettileattr
        and #7
        sec
        sbc #3
        sta q6                      ; push (-2..2, 3 = none)
        ; friction
        ldx control                 ; X, not A: A keeps q6 for the push test
        beq @nofric                 ; (in reach: 126 bytes on)
:                                   ; (unreferenced: keeps the anonymous labels' count)
        ldx alt
        beq :+
        bpl @air
:
        cmp #3                      ; A = q6 (push), still
        beq @air
        ; ground: vx = vx*58>>6 + push*48 (two of the original's vx*61>>6 + push*24), as
        ; vx - ceil(3w/32) with w = vx - 512p: 3w = 3vx - 1536p, whose 32nds are 3vx's
        ; less 48p exactly (the push folded in; |3w| < 32768 as |vx| < 1820, |p| <= 2)
        asl                         ; A = q6 (push), still: 2p
        eor #$FF
        sec
        adc vx+1                    ; A = vx+1 - 2p: w's high byte (its low byte is vx's)
        sta t16+1
        lda vx
        asl
        tax                         ; X = 2*w low, C untouched by tax
        lda t16+1
        rol                         ; A = 2*w high
        tay
        txa
        clc
        adc vx
        sta t16                     ; t16 = 3w low (= 3vx low)
        ldx #0
        tya
        adc t16+1                   ; A = 3w high, N = its sign
        bpl :+
        dex
:       stx t16+1                   ; t16+1:A:t16 = 3w sign-extended to 24 bits
        asl t16                     ; three left shifts: t16+1:A = floor(3w/32)
        rol
        rol t16+1
        asl t16
        rol
        rol t16+1
        asl t16
        rol
        rol t16+1                   ; t16 = the dropped bits (3w & 31) << 3
        ldy #0
        cpy t16                     ; C = nothing dropped: floor == ceil
        eor #$FF
        adc vx                      ; vx + ~floor + C = vx - ceil(3w/32)
        sta vx
        lda vx+1
        sbc t16+1
        sta vx+1
:                                   ; (unreferenced: keeps the anonymous labels' count)
        jmp @nofric
@air:   ; vx = vx*3>>3 (two of the original's vx*5>>3): asr3(3vx), and 3vx fits 16 bits
        lda vx
        asl
        tax                         ; X = 2vx low (X and Y are dead past @nofric)
        lda vx+1
        rol                         ; A = 2vx high
        tay
        txa
        clc
        adc vx
        sta vx                      ; 3vx low, straight into vx: no add16 at the end
        tya
        adc vx+1                    ; A = 3vx high (vx+1 not written yet)
        cmp #$80                    ; asr16 x3, high byte held in A
        ror
        ror vx
        cmp #$80
        ror
        ror vx
        cmp #$80
        ror
        ror vx
        sta vx+1
@nofric:
        ; horizontal input
        lda control
        beq @norun
        lda keys
        and #(K_LEFT|K_RIGHT)
        beq @norun
        eor #(K_LEFT|K_RIGHT)       ; A = 2 left, 1 right; both held: A = 0, as on the
        beq @norun                  ; other two ways to @norun
        tax                         ; X = 2 left, 1 right: @acctab's index
        lsr                         ; A = 1 left, 0 right: the facing flag
        sta facing
        lda running
        ora firing
        bne :+
        sta anim                    ; A = running|firing = 0
:       ; accel = (alt > 0 || push == 3) ? 480 : 72: two of the original's 288 : 36
        ; through its friction (each pairs with one: 480 with vx*3>>3, 72 with
        ; vx*58>>6), which hold the original's top speed, 768, exactly
        lda alt
        beq :+
        bpl @acc480
:       lda q6
        cmp #3
        bne @acc72
@acc480:
        inx
        inx                         ; X = 4 left, 3 right: the 480 pair
@acc72: clc                         ; vx += the accel, negated for left: one add for both
        lda vx
        adc @acctab-1,x
        sta vx
        lda vx+1
        adc @acctab+3,x
        sta vx+1
        lda #1
        bne @norun                  ; Z = 0 from the load: running = 1
@acctab:                            ; by X-1: 72 right, 72 left, 480 right, 480 left
        .byte <72, <(-72), <480, <(-480)
        .byte >72, >(-72), >480, >(-480)
@norun: sta running                 ; A = 1 from the run, 0 on the three ways from above
@hmove:
        ; steps = ((vx + 128) >> 8) * 2: the frame's two ; dir = sign
        lda vx
        cmp #$80                    ; C = carry out of vx_lo + 128, without the clc
        lda vx+1
        adc #0                      ; A = high byte of vx + 128
        asl                         ; two steps' (|A| < 64)
        sta dpx
        beq @hdone                  ; dpx = 0: dpx+1 is dead after @hdone (vy_step rewrites dpx)
        and #$80
        beq :+
        lda #$FF
:       sta dpx+1                   ; qx = px and qy = py+16 already, set at @push
@hstep: bmi @hneg
        inc qx
        bne @hget
        inc qx+1
        bne @hget                   ; always: qx+1 <= 8 (px is inside the map, < 2048)
@hneg:  lda qx
        bne :+
        dec qx+1
:       dec qx
@hget:  jsr getaltitude
        bpl @hok                    ; N from getaltitude's closing sbc
        cmp #$FF
        bne @wall
@hok:   ldx qx                      ; px += dir: qx is px + dir already
        stx px                      ; (X is free: A still holds the altitude)
        ldx qx+1
        stx px+1
@hmoved:
        ; if a <= 1: py += a ; alt = 0 else alt = a   (a may be -1: step up a slope)
        tax                         ; N from the altitude
        bmi @stepn
        cmp #2
        bcs @alt
        adc py                      ; C is clear from the cmp: 0 or 1, addend high byte 0
        sta py
        bcc :+
        inc py+1
        bcs :+                      ; always: C = 1, the adc's carry
@stepn: clc                         ; negative: high byte of the addend is $FF
        adc py
        sta py
        bcs :+                      ; no borrow (255 times in 256): py+1 is unchanged
        dec py+1                    ; (C = 0: falls into the 0/1 case's zero)
:       lda #0                      ; alt = 0 (A is dead: @hnext reloads it)
@alt:   sta alt
@hnext: ; steps -= dir
        ldx dpx+1                   ; X holds the direction for @hl (X is dead here)
        bmi :+
        dec dpx
        bpl :++                     ; always: dpx was 1..$7F, so N is clear
:       inc dpx
:       beq @hdone      ; Z survives from the inc/dec
@hl:    clc                         ; qx = px already: @hok set px to it
        lda py
        adc #16
        sta qy
        lda py+1
        adc #0
        sta qy+1
        txa                         ; dpx+1, still in X: N for @hstep
        jmp @hstep
@wall:
        zero vx, vx+1               ; (A is dead: @hdone reloads)
@hdone: lda px                      ; dxl, dyl: her move this frame, all of it (across;
        sec                         ;  down: the fall, a slope's step), the stretch the
        sbc pxs                     ;  objects' tests sweep next frame (csweep)
        sta dxl
        lda py
        sec
        sbc pys
        sta dyl
        ; animation counters: two steps a frame (every test is of an even count)
        inc anim
        inc anim
        lda anim                    ; anim in A for every test below; the flags come
        ldx firing                  ; through X (X is dead: written before any read below)
        beq @notfiring
        cmp #4
        bne :+
        ; launch boomerang
        mov16 bx, px
        mov16 by, py
        zero bvx, bvy, bvy+1, bcnt
        lda #>3584
        ldx facing                  ; X is dead (written before any read below)
        beq @bdir
        lda #>(-3584)
@bdir:  sta bvx+1
        inc bactive                 ; 0 here: a throw starts only with bactive clear
        lda #SFX_THROW
        sta SFXREQ
        bne @animdone               ; always: SFX_THROW <> 0
:       cmp #12
        bne @animdone
        stz01 firing                ; 1 -> 0 (firing is only ever 0 or 1): Z = 1 on both
        beq @animdone               ;  (the Model B's dec; the cmp #12, which stz keeps)
@notfiring:
        ldx running                 ; A = anim still
        beq :+
        cmp #16
        bne @animdone
        beq @zanim                  ; always: Z = 1 from the cmp #16
:       cmp #128
        bne @animdone
@zanim: stz anim
@animdone:
        ; timers
        lda hurt
        beq @afterhurt
        ; clear after (frame - evframe) > 32 (the original's 64 steps), using an
        ; unsigned delta so it works
        ; across the 16-bit frame wrap (a signed compare stuck the flashing state)
@hdelta: lda frame                  ; (also hurt = 0 with control = 0: from @afterhurt)
        sec
        sbc evframe
        tax                         ; hold the low byte of the delta in X
        lda frame+1
        sbc evframe+1
        bne @clrhurt                ; elapsed >= 256 -> clear
        cpx #33
        bcs @clrhurt
        lda control                 ; hurt stands, so the delta is still in X and its
        bne @ctl                    ; high byte was zero: reuse it for the control
        cpx #13                     ; timer instead of subtracting frame-evframe twice
        bcc @noctl
        bcs @setctl                 ; always
@afterhurt:
        lda control
        bne @ctl
        beq @hdelta                 ; always: with hurt 0 the tests above decide the
                                    ; control alone (@clrhurt finds hurt 0 already)
@clrhurt:
        stz hurt
        lda control                 ; the delta is >= 33, so past 13: set control if
        bne @ctl                    ; clear, as a second subtraction would
@setctl:
        inc control                 ; control is 0 on every way in
        bne @ctl                    ; always: it is 1 now
@noctl:
        ldx #22
        lda vx+1
        bmi @spr2
        lda vx
        beq @spr2
        inx                         ; 23
@spr2:  txa                         ; the frame in A for @spr
        bne @spr                    ; always: 22 or 23
@ctl:   lda firing
        beq @nofire
        lda anim
        cmp #4
        bcc @f14
        sbc #6                      ; C = 1: anim 6..9 -> 0..3, 4..5 wrap to $FE..$FF
        cmp #4
        lda #16                     ; anim 4..5 or 10 up: 16 (lda keeps C)
        bcs @sprf
        lda #18                     ; anim 6..9: 18
        bne @sprf
@f14:   lda #14
        bne @sprf
@nofire:
        bmi16 vy, @jump
        lda alt
        beq @ground
        bpl @jump
@ground:
        lda anim
        ldx running                 ; X dead: @spr keeps the frame in A (or tax)
        beq @standing
        lsr
        and #$FE                    ; (anim >> 2) << 1 with one shift, not three
        bpl @sprf                   ; N=0: lsr cleared bit 7
@standing:
        cmp #93
        bcc @s8
        sbc #109                    ; C = 1: anim 109..112 -> 0..3, 93..108 wrap to $E8..$FF
        cmp #4
        lda #10                     ; anim 93..108 or 113 up: 10 (lda keeps C)
        bcs @sprf
        lda #12                     ; anim 109..112: 12
        bne @sprf
@s8:    lda #8
        bne @sprf
@jump:  bpl @jpos                   ; N = vy's sign both ways in (bit vy+1 / lda alt > 0)
        lda vy                      ; vy < 0: vy <= -384 is vy < $FE81 unsigned
        cmp #<(-383)
        lda vy+1
        sbc #>(-383)
        lda #20                     ; (lda keeps C)
        bcc @sprf
@j22:   lda #22
        bne @sprf
@jpos:  lda vy                      ; vy >= 0: vy >= 384 unsigned
        cmp #<384
        lda vy+1
        sbc #>384
        bcc @j22
        lda #24
@sprf:  ora facing
@spr:   ldy hurt                    ; the frame stays in A (Y is dead: see below)
        beq @drawp
        tax                         ; flashing: hold the frame in X for the test
        lda frame
        and #1
        bne @boom
        txa
@drawp: ldy px                      ; Y, not A: A holds the frame for addsprite
        sty spx
        ldy px+1
        sty spx+1
        ldy py
        sty spy
        ldy py+1
        sty spy+1
        jsr addsprite
@boom:  ; ---- boomerang: one flight step a frame.  Its move is made 8 px at most at a
        ; time, stopping in the first solid, so it cannot fly through a wall; the catch,
        ; like the objects' hits (bsweep), tests the box between where it was and where
        ; it is -- no position between a frame's ends is tested.
        lda #0
        sta bdx                     ; its move this frame (none unless it flies)
        sta bdy
        lda bactive
        bne :+
        jmp @bdone
:       lda bcnt
        cmp #8
        bcc @bfly
        jmp @bcount                 ; hit or stopped: it no longer flies
@bfly:  jsr brel                    ; the pull toward Cleo
        ldx #0                      ; the two axes' velocities, and their moves
        jsr bstep
        sta bmx
        ldx #2
        jsr bstep
        sta bmy
@bm:    lda bmx                     ; a part of the move: 8 px at most each way
        jsr clamp8
        tax
        eor #$FF                    ; bmx -= it
        sec
        adc bmx
        sta bmx
        txa
        clc
        adc bdx
        sta bdx
        txa
        ldx #0
        jsr bmove                   ; bx += it, and qx = bx
        lda bmy
        jsr clamp8
        tax
        eor #$FF
        sec
        adc bmy
        sta bmy
        txa
        clc
        adc bdy
        sta bdy
        txa
        ldx #2
        jsr bmove                   ; by += it, and qy = by
        jsr getaltitude             ; in a solid: it stops there
        bpl :+
        lda #8
        sta bcnt
        bne @bcount                 ; always
:       lda bmx
        ora bmy
        bne @bm
@bcount: lda bcnt                   ; two counts a frame: in flight 0, 2, 4, 6 and round
        clc                         ;  again (its spin); hit or stopped, from 8 to 14, gone
        adc #2
        cmp #8
        bne :+
        lda #0
:       sta bcnt
        cmp #14
        bne :+
        lda #0
        sta bactive
        beq @bdone                  ; always
:       jsr brel                    ; caught?  The box it crossed meets Cleo's: rx, ry
        ldx #4                      ;  in -7..7 (quad 4: a star's -8..8 band, open)
        jsr bsweep
        bcc @bdraw
        stz01 bactive               ; bactive is 1 here (0/1 flag, nonzero on entry)
@bdraw: lda bactive
        beq @bdone
        mov16 spx, bx
        mov16 spy, by
        lda bcnt
        clc
        adc #54
        lsr                         ; (bcnt + 54) >> 1 = bcnt/2 + 27
        jsr addsprite
@bdone:
        ; ---- exit reached?
        lda px                      ; inside the exit box is 0 <= px-exitx < 16 and
        sec                         ; 0 <= py-exity < 24: one 16-bit subtract each,
        sbc exitx                   ; high byte zero (so the difference is 0..255)
        tax                         ; and low byte under the width
        lda px+1
        sbc exitx+1
        bne @noexit
        cpx #16
        bcs @noexit
        lda py
        sec
        sbc exity
        tax
        lda py+1
        sbc exity+1
        bne @noexit
        cpx #24
        bcs @noexit
        inc exiting                 ; 0 here in play: the loop leaves on any nonzero
@noexit:
        rts


; ============================================================================
; Object processing.  Y = object index (obj).  Every type shares the prologue --
; spx/spy (where it draws) and rx/ry (relative to Cleo) -- then goes to its entry in
; @tab.  The handlers work on the object's arrays in place (O_AL..O_EH,y), with Y the
; index -- reloaded from obj after anything that changes it (addscore and bar_touch,
; player_hit, a handler's own scratch) -- and stage into zero page only what they
; use hard (the bat's velocity, for its move and chase).  The vanishing platform and
; the switch, rare and busy with Y over the map, keep wrappers (os_*) that copy in
; and back just the fields they touch.  ox/oy: spx/spy's copies, for those that
; read the position after moving spx/spy.
; ============================================================================
process_object:
  .if ::BHW
        ldx O_TYPE,y                ; X = otype, the dispatch index (split tables)
        stx otype
  .else
        lda O_TYPE,y
        sta otype
        asl                         ; X = otype*2, the dispatch index
        tax
  .endif
        lda O_XL,y                  ; rx/ry = object relative to the player
        sta spx                     ; spx/spy = where it draws: sta touches no flags,
        sec                         ; so the source byte can be banked on the way past
        sbc px
        sta rx
        lda O_XH,y
        sta spx+1                   ; sta touches no flags, so C survives for the sbc
        sbc px+1
        sta rx+1
        lda O_YL,y
        sta spy
        sec
        sbc py
        sta ry
        lda O_YH,y
        sta spy+1
        sbc py+1
        sta ry+1
@call:                              ; tail dispatch: the handler returns to our caller
  .if ::BHW                         ; jmp (abs,x) by hand, through jv (the 6502 has no
        lda @tlo,x                  ;  such form); A is clobbered: every handler loads it first
        sta jv
        lda @thi,x
        sta jv+1
        jmp (jv)
@tlo:   .lobytes ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .lobytes ob_spike, ob_none, ob_flame, ob_powerup, os_vanish, os_switch
@thi:   .hibytes ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .hibytes ob_spike, ob_none, ob_flame, ob_powerup, os_vanish, os_switch
  .else
        jmp (@tab,x)
@tab:   .word ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .word ob_spike, ob_none, ob_flame, ob_powerup, os_vanish, os_switch
  .endif

; ---- the staged types' wrappers.  OIN f, field: the object's field into zero page
; (fa..fe from O_AL..O_EH); OOUT the other way; Y = obj throughout the copies.
.macro OIN f, lo
        lda lo,y
        sta f
.endmacro
.macro OOUT f, lo
        lda f
        sta lo,y
.endmacro
os_vanish:                          ; fe low, ox, oy
        OIN fe, O_EL
        jsr os_oxy
        jsr ob_vanish               ; the frame's two steps: its count's map writes
        jsr ob_vanish               ;  fall on every fourth
        ldy obj
        OOUT fe, O_EL
        rts
os_switch:                          ; fa, fb, fc, fd: the low bytes
        OIN fa, O_AL
        OIN fb, O_BL
        OIN fc, O_CL
        OIN fd, O_DL
        jsr ob_switch
        ldy obj
                                    ; (fa..fc need no copy back: ob_switch only reads them)
        OOUT fd, O_DL
ob_none:                            ; (type 8, nothing to do: os_switch's rts)
        rts
os_oxy: lda spx                     ; ox, oy: the object's position (the prologue's spx,
        sta ox                      ; spy)
        lda spx+1
        sta ox+1
        lda spy
        sta oy
        lda spy+1
        sta oy+1
        rts

; range check: rx > lo && rx < hi && ry > lo2 && ry < hi2 ; X = offset of the limit
; quad in RNGTAB (limits stored +128 so the test is an unsigned byte compare on r^$80,
; after checking r fits in -128..127 - anything wider fails every limit anyway).
; Returns carry set if inside. Clobbers A, X.
inrange:
        lda rx                      ; r fits -128..127 iff hi + (lo's sign) = 0 mod 256
        asl                         ; C = the low byte's sign
        lda rx+1
        adc #0                      ; $FF+1 and 0+0 are 0; nothing else is
        bne @nc                     ; (C = 0: adc #0 carries only into 0)
        lda rx
        eor #$80
        cmp RNGTAB,x
        bcc @nc
        beq @no                     ; rx > lo
        cmp RNGTAB+1,x
        bcs @no                     ; rx < hi
        lda ry
        asl
        lda ry+1
        adc #0
        bne @nc                     ; (C = 0, as above)
        lda ry
        eor #$80
        cmp RNGTAB+2,x
        bcc @nc
        beq @no
        cmp RNGTAB+3,x
        bcs @no
        sec
        rts
@no:    clc
@nc:    rts                         ; (C already 0)


;---- The swept tests: no position between a frame's ends is tested, only the
; stretch between them.  span: does r .. r + swd (r: A low, Y high, signed) meet
; (RNGTAB+o, RNGTAB+o+1) at X, open at both ends?  C = 1 if it does; X kept.
span:   sta swl
        sty swh
        jsr rbias                   ; one end, biased
        sta swa
        lda swd                     ; the other: r + swd
        ldy #0
        ora #0
        bpl :+
        dey
:       clc
        adc swl
        pha
        tya
        adc swh
        tay
        pla
        jsr rbias
        cmp swa                     ; A the high end, swa the low
        bcs :+
        ldy swa
        sta swa
        tya
:       cmp RNGTAB,x                ; high end > lo
        beq @no
        bcc @no
        lda swa
        cmp RNGTAB+1,x              ; low end < hi
        bcs @no
        sec
        rts
@no:    clc
        rts
; rbias: A = low, Y = high of a signed 16-bit r -> A = r clamped to -128..127, + 128
; (as inrange compares: a value past either end stays past every limit)
rbias:  cpy #$FF
        beq @n
        cpy #0
        bne @far
        cmp #$80                    ; 0..255: past 127 is 127
        bcc @in
@hi:    lda #$FF
        rts
@n:     cmp #$80                    ; -256..-1: under -128 is -128
        bcs @in
@lo:    lda #0
        rts
@far:   tya
        bmi @lo
        bpl @hi                     ; always
@in:    eor #$80
        rts
; csweep: Cleo's test, over her last move (dxl, dyl: where she was is r + d, rx/ry
; being the object less her): where she is, else the box between where she was and
; where she is meets the quad's -- the corner a diagonal move cuts, the 8-px trampoline
; band a 12-px fall would cross.  X and Y kept; C = 1 if inside.
csweep: jsr inrange                 ; where she is: the hits, and quick
        bcs @r
        lda dxl
        ora dyl
        bne @go
@r:     rts                         ; (C = 0: she did not move)
@go:    sty swy
        lda dyl
        sta swe
        lda dxl
        bcc sweep                   ; always: C = 0 from inrange's miss
; bsweep: the boomerang's hit test, over its last move (bdx, bdy: where it was is
; r + bd, rx/ry being the object less the boomerang): the box between where it was and
; where it is meets the quad's.  X and Y kept; C = 1 if it does.
bsweep: sty swy
        lda bdy
        sta swe
        lda bdx
; sweep: rx over A, ry over swe (the move across and down), against quad X; Y back from
; swy.  C = 1 if both meet it.
sweep:  sta swd
        lda rx
        ldy rx+1
        jsr span
        bcc @n
        inx
        inx
        lda swe
        sta swd
        lda ry
        ldy ry+1
        jsr span
        dex
        dex
@n:     ldy swy
        rts

; bstep: the boomerang's flight on one axis, X = 0 (x) or 2 (y): bv -= bv/16 + bv/64
; + bv/128 (the original's two steps of 61/64 in one), bv += 4*r (r: rx or ry, the
; pull toward Cleo), A = the move, 2 * ((bv + 128) >> 8) (signed).  X kept.  (Against
; the original's two steps, thrown on the flat: 108 px out to its 105, back the same
; frame; its drift down settles at 10 px to its 9.)
bstep:  lda bvx+1,x                 ; t16 = bv >> 4
        sta t16+1
        lda bvx,x
        ldy #4
:       pha
        lda t16+1
        cmp #$80
        ror a
        sta t16+1
        pla
        ror a
        dey
        bne :-
        sta t16
        ldy #3                      ; bv -= bv>>4, then >>6, then >>7
@d:     sec
        lda bvx,x
        sbc t16
        sta bvx,x
        lda bvx+1,x
        sbc t16+1
        sta bvx+1,x
        lda t16+1                   ; t16 >>= 2, then 1
        cmp #$80
        ror t16+1
        ror t16
        cpy #3
        bne :+
        lda t16+1
        cmp #$80
        ror t16+1
        ror t16
:       dey
        bne @d
        lda rx,x                    ; bv += 4*r
        sta t16
        lda rx+1,x
        asl t16
        rol a
        asl t16
        rol a
        sta t16+1
        clc
        lda bvx,x
        adc t16
        sta bvx,x
        lda bvx+1,x
        adc t16+1
        sta bvx+1,x
        lda bvx,x                   ; A = 2 * ((bv + 128) >> 8): the original's step's
        cmp #$80                    ;  move, twice -- as its two steps rounded it (a slow
        lda bvx+1,x                 ;  pull stays put until it would move a pixel a step)
        adc #0
        asl a
        rts
; brel: rx = px - bx, ry = py - by + 8: Cleo less the boomerang (its pull, its catch)
brel:   sec
        lda px
        sbc bx
        sta rx
        lda px+1
        sbc bx+1
        sta rx+1
        sec
        lda py
        sbc by
        tax
        lda py+1
        sbc by+1
        sta ry+1
        txa
        clc
        adc #8
        sta ry
        bcc :+
        inc ry+1
:       rts
; bmove: bx (X = 0) or by (X = 2) += A (signed), and qx/qy = it
bmove:  ldy #0
        ora #0
        bpl :+
        dey
:       clc
        adc bx,x
        sta bx,x
        sta qx,x
        tya
        adc bx+1,x
        sta bx+1,x
        sta qx+1,x
        rts
; clamp8: A (signed) to -8..8
clamp8: bmi @n
        cmp #9
        bcc @r
        lda #8
        rts
@n:     cmp #<-8
        bcs @r
        lda #<-8
@r:     rts

; boomerang-relative position: rx = spx - bx ; ry = spy - by  (spx/spy: the object's draw pos)
boomrel:
        dif16 rx, spx, bx
        dif16 ry, spy, by
        rts
; boomerang hit test helper: bactive && bcnt < 8 -> carry set
boomready:
        lda bactive
        beq @no
        lda #7
        cmp bcnt                    ; C = 7 >= bcnt = bcnt < 8
        rts
@no:    clc
        rts
addscore:                           ; A = points, BCD; X and Y kept
  .if .defined(DBGHIT) .or .defined(DBGTILE)
        rts                         ; (debug: the score is a readout)
  .endif
        sed                         ; (every interrupt clears D for itself: low.s, and the
        clc                         ;  65C02 by its own)
        adc score
        sta score
        lda score+1
        adc #0
        sta score+1
        lda score+2
        adc #0
        sta score+2
        cld
        jmp bar_touch

; ---------------------------------------------------------------- STAR (0)
; Cleo's two tests on a star -- the collect (RNGTAB quad 0) and box_safe's (quad 64,
; grown by a frame's move) -- can only pass with rx in -29..25.  So the star list's prologue (po_star) tests
; rx against that first, and outside it sets q2 (Cleo far): both tests are skipped,
; and ry, which only they read, is not worked out.  The boomerang's tests set rx and
; ry themselves (boomrel), and clear q2, as does every other way in.
po_star:                            ; the star list's: Y = the star
        lda O_YL,y
        sta spy
        lda O_YH,y
        sta spy+1
        lda O_XL,y
        sta spx
        sec
        sbc px
        sta rx
        lda O_XH,y
        sta spx+1
        sbc px+1
        sta rx+1                    ; A = rx+1
        beq @pos
        cmp #$FF
        bne @far
        lda rx
        cmp #<-29
        bcs @near                   ; -29..-1
@far:   lda #1
        bne star_q2                 ; always
@pos:   lda rx
        cmp #26
        bcs @far                    ; 0..25 fall through
@near:  lda spy
        sec
        sbc py
        sta ry
        lda spy+1
        sbc py+1
        sta ry+1
ob_star:                            ; the object table's way in (the list full: rare):
        lda #0                      ;  rx and ry are process_object's, q2 = 0
star_q2:
        sta q2
ob_star1:
        lda O_CL,y
        beq @live
        ; ---- collected: the sparkle, its own count 12..18, a step a frame (the
        ; original's on even steps)
        lda O_AL,y
        cmp #18                     ; cap: a collected star's A must not wrap 8-bit
        bcs @anim                   ; (it would make the star reappear ~every 20s)
        adc #1                      ; C = 0: the bcs was not taken
        sta O_AL,y
        bcc @anim                   ; always: A <= 18
@live:  lda health
        beq @tryboom
        lda q2
        bne @tryboom                ; Cleo far: the collect cannot pass
        ldx #0
        jsr csweep
        bcs @collect
@tryboom:
        lda bactive
        beq @phase
        lda q2                      ; box_safe's Cleo test, now: boomrel takes rx, ry
        bne @tbr                    ; (Cleo far: q2 says so already)
        ldx #64
        jsr inrange                 ; C = 1: she overlaps the box's guard band
        lda #2                      ; q2: 1 safe of her, $81 not (box_safe reads
        ror                         ;  only its sign and zero): C in at the top
:       sta q2                      ; (label kept unused: the anonymous count)
@tbr:   jsr boomrel
        ldx #4
        jsr bsweep
        bcc @phase
@collect:
        lda #1
        sta O_CL,y
        dec stars
  .if .defined(DBGHIT) .or .defined(DBGTILE)
        jsr bar_touch               ; (debug: addscore stops short of it)
  .endif
        jsr addscore                ; A = 1 still; it ends in jmp bar_touch (Y kept)
        lda #SFX_STAR
        sta SFXREQ
        lda #12                     ; the sparkle's first step: its count, and A
        sta O_AL,y                  ;  for @anim
        bne @anim                   ; always
        ; ---- the spin: the level's star clock plus this star's phase (A, the
        ; packer's), mod 12 -- a star out of the bin window keeps its place in step
@phase: lda O_AL,y
        clc
        adc starclk
        cmp #12
        bcc @spin                   ; A < 12: the cmp #18 cannot pass
        sbc #12                     ; C = 1: the bcc was not taken
@anim:  cmp #18
        bcs @done
@spin:  lsr
        ldx O_EL,y                  ; the star's first box id (0: none -- its masked frames):
        beq @regc                   ; the sky's, black's, or its own baked six (assets.py)
        cmp #6                      ; (carry unknown on the beq's path: forced there)
        bcs @reg                    ; C = 1 here, so @reg can assume it
        adc O_EL,y                  ; (C = 0: the bcs was not taken)
        ldx #64                     ; box_safe: Cleo's RNGTAB quad (the boomerang's is +4)
        bne box_safe                ; always: Z = 0 from the ldx
@regc:  sec
@reg:   adc #33                     ; C = 1: +34
        jmp addsprite
@done:  rts

; A box star is an opaque rectangle, so if the same frame is already on screen in the
; same place its pixels are still right -- unless something has been drawn through
; them.  The converter marks the stars an enemy's range covers; the rest can still be
; walked through by Cleo or the boomerang, which the collect check tests for with a
; band widened from "close enough to pick up" to "the rectangles touch".  Safe ones
; are drawn under an alias id BOXN above the real one.  The trampoline box is opaque
; the same way; both go through box_safe (at the end of ob_tramp).

; ---------------------------------------------------------------- TRAMPOLINE (1)
ob_tramp:                           ; A (O_AL) its spring's count: 2, 4 .. 10, two steps a frame
        lda O_AL,y
        beq :+
        cmp #8                      ; 2, 4, 6: + 2; 8: on to 10, which is 0
        bcc @up
        lda #$FD                    ; C = 1: $FD + 2 + 1 wraps to 0
@up:    adc #2                      ; (C = 0 on the bcc's way: + 2)
        sta O_AL,y
:       lda health
        beq @draw
        ldx #8
        jsr csweep
        bcc @draw
        lda vy+1                    ; bmi16 vy and beq16 vy from one load
        bmi @draw
        ora vy
        beq @draw
        lda #2
        sta O_AL,y
        stz vy                      ; vy = -2048 (A dead: the lda below)
        lda #>(-2048)
        sta vy+1
        lda spy                     ; on its surface, 6 px into the band, where the
        sbc #6                      ;  original's step-a-time test found her: a frame's
                                    ;  two steps may carry her deeper or through it
                                    ;  (C = 1: csweep's, the bcc @draw not taken)
        sta py
        lda spy+1
        sbc #0
        sta py+1
        lda #SFX_JUMP
        sta SFXREQ
@draw:  lda O_AL,y                  ; at rest (0): its rest state's baked box, if it has
        bne @bounce                 ; one (assets.py: an id a trampoline; 0 for none)
        lda O_EL,y
        bne @rest
@bounce:                            ; (A = O_AL, or 0: frame 0; A even, so the carry in
                                    ;  cannot change A/4 -- no clc)
        adc #2+4*43                 ; (A + 2)/4 + 43 as one add: A <= 8, so no carry out
        lsr
        lsr                         ; bounce frame 0..2: the masked frames, ids 43..45
        jmp addsprite
@rest:
        stzx q2                     ; (box_safe's Cleo test: rx, ry are hers; A live)
        ldx #72                     ; box_safe: Cleo's RNGTAB quad (the boomerang's is +4)
                                    ; (no clc: q2 = 0, so box_safe's inrange sets C first)
        ; fall through
; A = frame, X = the RNGTAB quad for Cleo (64 star, 72 trampoline; the boomerang's is
; X+4 -- inrange and boomrel leave X alone), C = 0, q2: 0 test Cleo (rx, ry are hers),
; 1 she is clear, $80 she is not (a star's prologue, or its boomerang test, which
; takes rx, ry).  Adds BOXN if nothing can draw through the box, then tail-calls
; addsprite.
box_safe:
        sta q1
        lda O_EH,y                  ; an enemy's range covers it
        bne @no
        lda q2
        bmi @no                     ; Cleo overlaps (the star's boomerang test found)
        bne @cfar                   ; Cleo clear
        jsr inrange                 ; Cleo overlaps its rectangle
        bcs @no
@cfar:  lda bactive
        bne @bt
        lda firing                  ; a throw that launches this frame (Cleo's step runs
        beq @yes                    ;  after the objects, anim 2 -> 4) starts from her
        lda anim                    ;  place: test it there (bx, by are dead until the
        eor #2                      ;  launch writes them; eor keeps C clear)
        bne @yes
        mov16 bx, px
        mov16 by, py
@bt:    jsr boomrel
        txa
        ora #4
        tax
        jsr inrange                 ; the boomerang overlaps it
        bcs @no
@yes:   lda q1                      ; both ways in fall through a 'bcs @no' that was not
        adc #BOXN                   ; taken, so C is already clear here
        bcc @add                    ; always: id + BOXN < 256 (ids < BOXID0+BOXN)
@no:    lda q1
@add:   jmp addsprite

; ---------------------------------------------------------------- GREEN SNAKE (2)
ob_snake:                           ; in place: Y = obj throughout (reloaded after
                                    ; addscore, whose bar_touch changes it).  Fields:
                                    ; A (O_AL/AH) the turn point, B (O_BL/BH) the offset,
                                    ; C (O_CL) the state, E (O_EL) the counter
        jsr @adv                    ; the frame's two steps of its state machine (the
        jsr @adv                    ;  turn is an exact B = A)
@coll:  clc                         ; rx and spx += B
        lda rx
        adc O_BL,y
        sta rx
        lda rx+1
        adc O_BH,y
        sta rx+1
        clc
        lda spx
        adc O_BL,y
        sta spx
        lda spx+1
        adc O_BH,y
        sta spx+1
        lda health
        beq @boom
        ldx #12
        jsr csweep
        bcc @boom
        lda O_CL,y
        cmp #4
        bcs @boom
        cmp #2                      ; C = C >= 2 for both arms: no op below touches C
        lda ry+1
        bmi @nostomp
        ora ry
        beq @nostomp
        lda vy+1
        bmi @nostomp
        ora vy
        beq @nostomp
        ; stomped: the carry is still C >= 2 (nothing down to the bcs touches it)
        ldx O_CL,y                  ; C += 2 through X (C is 0..3 here): inx leaves the carry
        inx
        inx
        txa
        sta O_CL,y
        lda #1
        sta bounce
        bcs @ks                     ; 2 and 3 (now 4 and 5): 5 points
        bcc @kz                     ; always
@nostomp:
                                    ; C = C >= 2 still: the cmp #2 above the stomp tests
        bcs @boom
        lda hurt
        bne @boom
        mov16 hx, rx
        jsr player_hit
        ldy obj
@boom:  jsr boomready
        bcc @draw
        jsr boomrel
        ldx #16
        jsr bsweep
        bcc @draw
        lda O_CL,y
        cmp #4
        bcs @draw
        lda bvx+1                   ; C = the boomerang's sign: state 4, or 5 moving left
        asl
        lda #2
        rol
        sta O_CL,y
        lda #8                      ; bcnt = 8: boomready now fails, so the bne @boom
        sta bcnt                    ;  below goes straight on to @draw
@ks:    lda #5                      ; the two kills' shared tail (addscore keeps X and Y)
        jsr addscore
@kz:    lda #0
        sta O_EL,y
        lda #SFX_KILL
        sta SFXREQ
        bne @boom                   ; always: A = SFX_KILL (5), Z = 0
@draw:  ldx O_BL,y                  ; B <= -128: not drawn (ble16i's bias form)
        cpx #<(-127)
        lda O_BH,y
        eor #$80
        sbc #(>(-127) ^ $80)
        bcc @done
        txa                         ; B - A against 128, as @c4 (C = 1: the bcc fell through)
        sbc O_AL,y
        tax
        lda O_BH,y
        sbc O_AH,y
        eor #$80
        cpx #<128
        sbc #(>128 ^ $80)
        bcs @done
        lda O_CL,y
        cmp #2
        and #1                      ; and leaves C from the cmp: both arms want C & 1
        bcs @f6
        ldx O_EL,y                  ; E is 0..11 whenever C < 2; the 0..63 ladder @s23
        ora @ftab,x                 ; runs only while C >= 2, and that takes @f6.  A is
        jmp addsprite               ; C & 1: cmp/and/bcs/ldx leave it
@f6:    ora #46+6                   ; the base is even: ora is the add
        jmp addsprite
@ftab:  .byte 46+0,46+0,46+0,46+2,46+2,46+2,46+4,46+4,46+4,46+2,46+2,46+2
@done:  rts
@adv:   lda O_EL,y                  ; both arms step the counter
        clc
        adc #1
        sta O_EL,y
        ldx O_CL,y                  ; X is free here (the handler never reads it before a load)
        cpx #2
        bcs @s23
        cmp #12
        beq @z                      ; E = 12: back to 0, a pause frame (no step)
        cmp #0                      ; the pause frames 0, 3, 6, 9: no step
        beq @ar
        cmp #3
        beq @ar
        cmp #6
        beq @ar
        cmp #9
        beq @ar
        clc                         ; C = 0 for both steps (txa, bne leave it)
        txa
        bne @c1
@c0:    lda O_BL,y                  ; B + 1
        adc #1
        sta O_BL,y
        bcc @c0c                    ; A = O_BL already (the sta keeps it)
        lda O_BH,y
        adc #0                      ; C = 1: + 1
        sta O_BH,y
        lda #0                      ; the low byte the carry left
@c0c:   cmp O_AL,y                  ; B = A: on to state 1
        bne @ar
        lda O_BH,y
        cmp O_AH,y
        bne @ar
        lda #1                      ; 0 -> 1, Z = 0
        bne @cset
@c1:    lda O_BL,y                  ; B - 1 (C = 0): a borrow leaves C = 0 and the low
        sbc #0                      ;  byte $FF, so B is not 0
        sta O_BL,y
        bcc @dech                   ; the borrow: @c5's tail takes it from the high byte
        bne @ar                     ; Z from the sbc
        lda O_BH,y                  ; B = 0: back to state 0
        bne @ar
@cset:  sta O_CL,y                  ; A = 0 (the bne above was not taken), or 1 from @c0
@ar:    rts
@s23:   cmp #64
        bne @s45
        txa                         ; C & 1: back to state 0 or 1
        and #1
        sta O_CL,y
@z:     lda #0                      ; E = 0 is a pause frame: neither state steps on it
        sta O_EL,y
@rt:    rts
; states 2 and 3 do nothing; 4 and 5, the snake dying (X = O_CL)
@s45:   cpx #4
        bcc @rt
        bne @c5                     ; carry set; Z: the state is 4
@c4:    ; if B < A + 128: B += 16
                                    ; C = 1 here (cpx #4 / bne @c5): B - A against the
        lda O_BL,y                  ; immediate 128, as @c5 tests its own limit
        sbc O_AL,y
        tax
        lda O_BH,y
        sbc O_AH,y
        eor #$80
        cpx #<128
        sbc #(>128 ^ $80)
        bcs @cj
        lda O_BL,y                  ; C = 0: the bcs @cj above was not taken
        adc #16
        sta O_BL,y
        bcc @cj
        lda O_BH,y
        adc #0                      ; C = 1: + 1
        sta O_BH,y
        rts
@c5:    ldx O_BL,y                  ; B <= -128: to @coll (ble16i's bias form; X is
        cpx #<(-127)                ;  dead after @adv, as @c4's tax already assumes)
        lda O_BH,y
        eor #$80
        sbc #(>(-127) ^ $80)
        bcc @cj
        txa                         ; C = 1: the bcc was not taken
        sbc #16
        sta O_BL,y
        bcs @cj
@dech:  lda O_BH,y                  ; (and @c1's borrow, C = 0 there too)
        sbc #0                      ; C = 0: - 1
        sta O_BH,y
@cj:    rts

; ---------------------------------------------------------------- RED SNAKE in basket (3)
ob_rsnake:                          ; in place: Y = obj (reloaded after the calls and
                                    ; the scratch that change it).  Fields: A (O_AL) the
                                    ; dormancy counter, B (O_BL/BH) knocked (1 or 2: its
                                    ; side), C and D (O_CL/CH, O_DL/DH) the knock's flight.
                                    ; ox/oy: the position (it draws twice, moving spx/spy)
        lda spx
        sta ox
        lda spx+1
        sta ox+1
        lda spy
        sta oy
        lda spy+1
        sta oy+1
        lda O_BL,y                  ; B: 0, or 1 or 2 knocked (its high byte stays 0)
        beq @up
        jmp @knocked
@up:
        ; A is a dormancy counter running -127..17 (CleoApp.run case 3: A++, and at 17
        ; A = -(rnd&63)-64) -- the same idiom as the spike, and a signed byte holds it.
        lda O_AL,y                  ; (two steps a frame: past 17 as well as at it)
        clc
        adc #2
        sta O_AL,y
        bmi @norst
        cmp #17
        bcc @norst
        jsr rnd
        and #63
        eor #63
        clc
        adc #129                    ; 192-r: the byte form of -(r&63)-64
        sta O_AL,y
@norst: ; rise = (A*A >> 3) - 28 while the snake is up: baked (risetab).
        ; The reference skips when A <= -16 (CleoApp.run 2865: bipush -16, if_icmple),
        ; so it is up for A >= -15.
                                    ; A = the counter on both ways in
        eor #$80                    ; bias the signed byte so the compare can be unsigned
        cmp #113                    ; -15 -> 113: at -16 the rise is +4 and the tall
        bcc @nowarm                 ; frame's tail shows 4 px under the basket; at -15
                                    ; it is 0 and the snake is flush with its bottom
        and #$1F                    ; (the bias is bit 7's: A & 31 is the counter's,
        tax                         ;  -15..16 -> 17..31, 0..16)
        lda risetab,x
        sta rise
        ldx #0                      ; its high byte: the sign
        ora #0
        bpl :+
        dex
:       stx rise+1
        lda #1                      ; snake visible
        bne @vis                    ; always: A = 1
@nowarm:
        lda #0
@vis:   sta q6
@boom:  jsr boomready
        bcc @hitp
        jsr boomrel
        ldx #20
        jsr bsweep
        bcc @hitp
        lda #4
        jsr addscore
        ldy obj
        ldx #1
        bgt16 ox, px, @kx
        ldx #2
@kx:    txa                         ; B's high byte is already 0: @up runs only
        sta O_BL,y                  ; when B = 0, and nothing since has written it
        lda q6
        beq @kr
        lda rise                    ; C = the rise
        sta O_CL,y
        lda rise+1
        sta O_CH,y
@kr:    lda #8
        sta bcnt
        lda #SFX_KILL
        sta SFXREQ
@hitp:  dif16 rx, ox, px            ; afresh: the boomerang test above may leave rx
        lda q6                      ; boomerang-relative, and a boomerang passing the
        beq @draw                   ; snake while Cleo stood at its height would read
                                    ; as Cleo touching it
        lda health
        beq @draw
        sec                         ; ry = oy - py + rise, in one pass: the
        lda oy                      ; difference waits in X (low) and Y (high)
        sbc py
        tax
        lda oy+1
        sbc py+1
        tay
        clc
        txa
        adc rise
        sta ry
        tya
        adc rise+1
        sta ry+1
        ldy obj
        ldx #24
        jsr csweep
        bcc @draw
        lda hurt
        bne @draw
        mov16 hx, rx
        jsr player_hit
        ldy obj
@draw:  lda q6
        beq @basket
        ldx #54
        lda O_AL,y
        bmi @fr
        ldx #56
        cmp #0                      ; A still holds the counter; ldx did not touch it
        beq @fr
        ldx #58
@fr:    stx q1
        bge16 px, ox, @fr1
        inc q1
@fr1:   mov16 spy, oy
        add16 spy, rise             ; snake Y = oy + parabola
        lda q1
        jsr addsprite
@basket:                            ; spx = ox still: ox was copied from it on entry
        mov16 spy, oy               ; and nothing since writes spx
        lda #60
        jmp addsprite
@knocked:                           ; (in place: C and D the flight)
        lda O_CL,y                  ; C > -256 (bgt16i's bias form), or done
        cmp #<(-255)
        lda O_CH,y
        eor #$80
        sbc #(>(-255) ^ $80)
        bcs @k1
        rts
@k1:    lda O_CL,y                  ; C -= 32: two steps' 16
        sec
        sbc #32
        sta O_CL,y
        lda O_CH,y
        sbc #0
        sta O_CH,y
        lda O_BL,y
        cmp #1
        bne @kl
        lda O_DL,y                  ; D += 32
        clc
        adc #32
        sta O_DL,y
        lda O_DH,y
        adc #0
        sta O_DH,y
        jmp @kf
@kl:    lda O_DL,y                  ; D -= 32
        sec
        sbc #32
        sta O_DL,y
        lda O_DH,y
        sbc #0
        sta O_DH,y
@kf:    ldx #55
        bgt16 ox, px, @kf1
        ldx #54
@kf1:   clc                         ; spy = oy + C in one pass (as spx = ox + D below)
        lda oy
        adc O_CL,y
        sta spy
        lda oy+1
        adc O_CH,y
        sta spy+1
        txa                         ; the frame is still in X
        jsr addsprite               ; (Y kept)
        clc
        lda ox                      ; spx = ox + D: the pot flies too (@basket draws 60
        adc O_DL,y                  ;  at spx, which it otherwise takes to be ox)
        sta spx
        lda ox+1
        adc O_DH,y
        sta spx+1
        jmp @basket


; ---------------------------------------------------------------- BAT (4)
ob_bat:                             ; Y = obj.  C and D (O_CL/CH, O_DL/DH: the velocity)
                                    ; are staged into fc/fd for the move and the chase
                                    ; and put back straight after it; the rest -- A and
                                    ; B (the chase's limits), E (the counter), the
                                    ; falling -- in place, Y reloaded after the calls
                                    ; that change it (addscore, player_hit)
        lda O_EL,y
        cmp #8
        bcc @alive
        jmp @dead
@alive: adc #2                      ; A = E < 8 and C = 0 from the bcc:
        and #7                      ; E = (E + 2) & 7: two steps
        sta O_EL,y
        lda O_DL,y
        sta fd
        lda O_DH,y
        sta fd+1
        lda O_CL,y
        sta fc
        lda O_CH,y
        sta fc+1
        ; rx += C>>1 ; ry += D>>1 (Y is scratch here)
                                    ; A = fc+1: X:Y = fc >> 1 (arithmetic); rx += it, spx += it
        cmp #$80
        ror a
        tax
        lda fc
        ror a
        tay
        clc
        adc rx
        sta rx
        txa
        adc rx+1
        sta rx+1
        clc
        tya
        adc spx
        sta spx
        txa
        adc spx+1
        sta spx+1
        lda fd+1                    ; and fd >> 1 into ry, spy
        cmp #$80
        ror a
        tax
        lda fd
        ror a
        tay
        clc
        adc ry
        sta ry
        txa
        adc ry+1
        sta ry+1
        clc
        tya
        adc spy
        sta spy
        txa
        adc spy+1
        sta spy+1
        ; chase: the frame's two steps of it (each limited)
        ldx #2                      ; the step count in X (the loop leaves X alone)
        ldy obj
@chase: bpl16 rx, @rxpos
        lda fc                      ; C >= A (bge16's signed compare): no faster
        cmp O_AL,y
        lda fc+1
        sbc O_AH,y
        bvc @cv
        eor #$80
@cv:    bpl @ydir
        inc fc
        bne @ydir
        inc fc+1
        bne @ydir                   ; fc + 1 = 0 only when fc became 0: @rxpos then finds
                                    ;  rx <> 0 (negative) and fc = 0, and goes to @ydir
@rxpos: beq16 rx, @ydir
        beq16 fc, @ydir
        ; (C >= 0 always: it stays in 0..A, so no sign test)
        lda fc
        bne :+
        dec fc+1
:       dec fc
@ydir:  bpl16 ry, @rypos
        lda fd                      ; D >= B: no faster
        cmp O_BL,y
        lda fd+1
        sbc O_BH,y
        bvc @dv2
        eor #$80
@dv2:   bpl @vput
        inc fd
        bne @vput
        inc fd+1
        bne @vput                   ; fd + 1 = 0 only when fd became 0: @rypos then finds
                                    ;  ry <> 0 (negative) and fd = 0, and goes to @vput
@rypos: beq16 ry, @vput
        lda fd+1                    ; (D >= 0 always: it stays in 0..B, so no sign test)
        ora fd
        beq @vput
        lda fd
        bne @dl
        dec fd+1
@dl:    dec fd
@vput:  dex
        bne @chase
        lda fc                      ; the velocity back
        sta O_CL,y
        lda fc+1
        sta O_CH,y
        lda fd
        sta O_DL,y
        lda fd+1
        sta O_DH,y
@boom:  jsr boomready
        bcc @player
        lda rx                      ; rx, ry (Cleo's) kept on the stack across the
        pha                         ;  boomerang's test: her tests below read them
        lda rx+1
        pha
        lda ry
        pha
        lda ry+1
        pha
        jsr boomrel
        ldx #28
        jsr bsweep
        pla                         ; pla/sta do not touch carry
        sta ry+1
        pla
        sta ry
        pla
        sta rx+1
        pla
        sta rx
        bcc @player
        lda #8                      ; bcnt first: the kill does not read it
        sta bcnt
@kill:  lda #6
        jsr addscore
        ldy obj
        lda #<(-640)                ; A = -640: the fall's
        sta O_AL,y
        lda #>(-640)
        sta O_AH,y
        lda #8
        sta O_EL,y
        lda #SFX_KILL
        sta SFXREQ
        bne @draw                   ; SFX_KILL <> 0
@player:
        lda health
        beq @draw
        ldx #32
        jsr csweep
        bcc @draw
        lda ry                      ; a stomp if she was above it where her last move
        clc                         ;  started (ry + dyl > 4): a frame's fall (12) can
        adc dyl                     ;  take her from over it to level with it
        tax
        lda dyl                     ; (dyl's sign into the high byte)
        and #$80
        beq :+
        lda #$FF
:       adc ry+1
        bmi @nostomp
        bne :+
        cpx #5
        bcc @nostomp
:       lda vy+1                    ; bmi16 vy, then beq16 vy, from one load
        bmi @nostomp
        ora vy
        beq @nostomp
        lda #1                      ; bounce first: the kill does not read it
        sta bounce
        bne @kill                   ; A = 1
@nostomp:
        lda hurt
        bne @draw
        ldx #36
        jsr csweep
        bcc @draw
        mov16 hx, rx
        jsr player_hit
        ldy obj
@draw:  lda O_EL,y
        cmp #6                      ; C: E >= 6 draws 65
        and #2                      ; else 61, or 63 for fe 2..3 (61 has bit 1 clear)
        ora #61
        bcc @fr
        lda #65
@fr:    sta q1
        bge16 px, spx, @wob         ; spx > px: one frame on
        inc q1
@wob:   ; wobble: x += BAT_OFFSET[(s + obj*5) & 15] ; y += BAT_OFFSET[((5*s>>2) + obj*7) & 15],
        ; s = 2*frame: the original's step count
        lda frame
        asl
        sta t16b                    ; s (low byte: all the indices use)
        lda obj
        asl
        asl
        clc
        adc obj
        adc t16b
        and #15
        tax
        lda batoff,x
        bpl @wx1                    ; spx += a signed byte, without building the word:
        dec spx+1                   ; pre-borrow the high byte when it is negative
@wx1:   clc
        adc spx
        sta spx
        bcc @wx2
        inc spx+1
@wx2:   lda t16b
        asl
        asl                         ; A = 5*s, low byte only: the high byte of 5*s is
                                    ; dead (the >>2 below shifts the low byte alone,
                                    ; no clc: s and 4s are even, so a carry in only sets
                                    ; bit 0, which the >>2 drops;
        adc t16b                    ; and only t16's low byte is used)
        lsr
        lsr
        sta t16
        lda obj
        asl
        asl
        asl                         ; 8*obj: mod 16 only bit 3 is left, so eor adds it
        eor t16
        sec
        sbc obj                     ; q + 8*obj - obj = q + 7*obj (mod 16)
        and #15
        tax
        lda batoff,x
        bpl @wy1
        dec spy+1
@wy1:   clc
        adc spy
        sta spy
        bcc @wy2
        inc spy+1
@wy2:   lda q1
        jmp addsprite
@dead:  ; falling (in place)
        lda O_DL,y                  ; D - B's high byte: D >= B + 256 is that >= 1, signed
        cmp O_BL,y                  ; (B = 16*q4 <= 4080 and D -6..~4600 while falling:
        lda O_DH,y                  ;  no overflow, and the high byte stays -36..18)
        sbc O_BH,y
        cmp #1
        bpl @done
        clc                         ; A += 240 (two steps' 120), the new low byte in X
        lda O_AL,y
        adc #240
        sta O_AL,y
        tax
        lda O_AH,y
        adc #0
        sta O_AH,y                  ; want only the high byte of A + 128:
        cpx #$80                    ; C = carry out of A_lo + 128
        adc #0                      ; the step, signed
        ldx #0                      ; X = the step's sign extension (ldx leaves C)
        asl                         ; two (N its sign)
        bpl @dpos
        dex
@dpos:  clc                         ; D += it, sign extended
        adc O_DL,y
        sta O_DL,y
        txa
        adc O_DH,y
        sta O_DH,y
@fdok:                              ; A = O_DH,y: both ways in end on its sta
        cmp #$80                    ; spy += D >> 1 (arith)
        ror a
        tax                         ; the high half waits in X (dead: addsprite loads it)
        lda O_DL,y
        ror a
        clc
        adc spy
        sta spy
        txa
        adc spy+1
        sta spy+1
        lda O_CH,y                  ; same again for C into spx
        cmp #$80
        ror a
        tax
        lda O_CL,y
        ror a
        clc
        adc spx
        sta spx
        txa
        adc spx+1
        sta spx+1
        bgt16 spx, px, @f66
        lda #65
        bne @fgo                    ; always: Z = 0 from the lda #65
@f66:   lda #66
@fgo:   jmp addsprite
@done:  rts
batoff: .byte 0,1,1,2,2,2,1,1,0,<-1,<-1,<-2,<-2,<-2,<-1,<-1

; ---------------------------------------------------------------- MASK (5) / MUMMY (6)
ob_walker:                          ; in place: Y = obj throughout (reloaded after
                                    ; player_hit).  Fields: A (O_AL/AH) the far end, B
                                    ; (O_BL/BH) the offset, C (O_CL) the direction, E
                                    ; (O_EL) the counter
        lda O_EL,y                  ; E + 2 (two steps), 12 back to 0: E is even, 0..10
        cmp #10
        bcc @e                      ; C = 0: E + 2
        lda #$FD                    ; C = 1 (E = 10): $FD + 2 + 1 = 0
@e:     adc #2
        sta O_EL,y
        lda O_CL,y                  ; the step is 3, a frame's: the original's 1 and 2
        bne @left
        lda O_BL,y                  ; walking right.  B can be -1 coming in (the left
        sec                         ; path rests one past the near end), and the carry
        adc #2                      ; out of the add is what clears its sign byte -- drop
        sta O_BL,y                  ; that and -1 + 3 becomes -254, not 2.  (sec: the + 1)
        bcc @r1
        lda #0                      ; the carry: B was -2 or -1 (high byte $FF), now 1
        sta O_BH,y                  ; or 2.  A = 0 is below A (48..192) as 1 or 2 is
@r1:    cmp O_AL,y                  ; past here B's high byte is 0 and B is 0..194, so
        bcc @coll                   ; the unsigned compare says what the signed 16-bit did
        lda #1                      ; C = 0 here (bne @left fell through): now 1
        bne @cset                   ; always: the store is @stop's
@left:  lda O_BL,y
        clc                         ; B - 3: the step (C = 0 is the - 1)
        sbc #2
        sta O_BL,y
        beq @stop                   ; B reached 0 (a borrow never leaves zero: >= 254)
        bcs @coll                   ; no borrow, not zero: still walking
        lda #$FF                    ; borrow == B went negative: that IS the bmi16 test.
        sta O_BH,y                  ; B was 1 or 2 (high byte 0), so the high byte is $FF
@stop:  lda #0
@cset:  sta O_CL,y
@coll:  clc                         ; rx and spx += B
        lda rx
        adc O_BL,y
        sta rx
        lda rx+1
        adc O_BH,y
        sta rx+1
        clc
        lda spx
        adc O_BL,y
        sta spx
        lda spx+1
        adc O_BH,y
        sta spx+1
        lda health
        beq @boom
        ldx #40
        jsr csweep
        bcc @boom
        lda hurt
        bne @boom
        mov16 hx, rx
        jsr player_hit
        ldy obj
@boom:  jsr boomready
        bcc @draw
        jsr boomrel
        ldx #44
        jsr bsweep
        bcc @draw
        bit bvx+1
        bmi @bleft
        ; bvx > 0: if B < A: C = 0.  A is 48..192 (its high byte 0) and B -2..194,
        ; so B < A is B negative, or its low byte below A's
        lda O_BH,y
        bmi @bc0
        lda O_BL,y
        cmp O_AL,y
        bcs @bset
@bc0:   lda #0
        beq @bsc                    ; always
@bleft: ; bvx < 0: if B > 0: C = 1
        lda O_BH,y
        bmi @bset
        lda O_BL,y
        beq @bset
        lda #1
@bsc:   sta O_CL,y
@bset:  lda #8
        sta bcnt
@draw:  lda O_BH,y                  ; standing frame at either end.  Past the sign test
        bmi @f8                     ; B's high byte is 0, so the rest is an 8-bit compare
        lda O_BL,y
        beq @f8
        cmp O_AL,y
        bcs @f8
        ldx O_EL,y                  ; E in X, so each arm can load its frame early
        cpx #3
        bcc @f0
        cpx #6
        bcc @f2
        cpx #9
        lda #4
        bcc @fr                     ; C = 0: C + 4
        lda #5                      ; C = 1 (cpx #9 fell through): C + 6
@fr:    adc O_CL,y
@sp:    ldx otype                   ; the frame stays in A: no round trip through q1
        cpx #6                      ; otype is 5 or 6 (the walker's two table entries)
        bne @s5                     ; 5: C = 0 from the cpx
        adc #8                      ; 6: C = 1, so A + 9, and C = 0 again
@s5:    adc #67
        jmp addsprite
@f0:    lda O_CL,y                  ; C = 0: the bcc
        bcc @sp
@f2:    lda #2                      ; C = 0: the bcc
        bcc @fr
@f8:    lda #8
        bne @sp

; ---------------------------------------------------------------- SPIKE (7)
ob_spike:
        ; A is a dormancy counter running -127..24 (CleoApp.run case 7: A++, and at 24
        ; A = -(rnd&63)-64).  That fits a signed byte exactly, so the byte IS the value
        ; and the high half was only ever its sign extension.  In place: O_AL, Y = obj
        ; (reloaded after player_hit).
        lda O_AL,y                  ; (two steps a frame: past 24 as well as at it)
        clc
        adc #2
        sta O_AL,y
        bmi @nowrap
        cmp #24
        bcc @nowrap
        jsr rnd
        and #63
        eor #63                     ; 63-r, then +129, is 192-r: the byte form of
        clc                         ; -(r&63)-64, i.e. -64 down to -127
        adc #129
        sta O_AL,y
@nowrap:
        ldx health                  ; A = the counter on both ways in, and ldx keeps it
        beq @draw
        cmp #8                      ; unsigned: a dormant (negative) A is >= 8 too
        bcs @draw
        ; rx > -8 && rx < (A+1)*2 && ry > -24 && ry < 8
        asl                         ; A < 8 and C = 0 (bcs fell through): 2A, C = 0
        adc #130                    ; (fa+1)*2 biased by $80
        sta RNGTAB+49
        ldx #48
        jsr csweep
        bcc @draw
        lda hurt
        bne @draw
        lda rx+1                    ; only hx+1 goes over: player_hit reads just its sign
        sta hx+1                    ;  and hx's low byte is read nowhere.  The original knocks
        ora rx                      ; Cleo right when rx <= 0 (CleoApp.run case 7: rx > 0 is
        bne @ph                     ; -768, else +768), player_hit only when hx < 0: level
        dec hx+1
@ph:    jsr player_hit              ; with the spike (rx = 0), hx = -256 says so
        ldy obj
@draw:  lda O_AL,y
        bmi @done
        cmp #8
        bcc @fu
        eor #$FF                    ; A (8..23), C = 1: 255-A+23+1 = 23-A, C = 1
        adc #23
        lsr
        clc                         ; only the lsr can leave C set; bcc arrives with C=0
@fu:    adc #85
        jmp addsprite
@done:  rts

; ---------------------------------------------------------------- FLAME (9)
ob_flame:                           ; in place: E (O_EL) the frame, a step every other
        lda frame                   ;  frame (the original's every fourth step)
        lsr                         ; C = the frame's low bit; the lda keeps it
        lda O_EL,y
        bcs @f                      ; odd frame: C = 1, so adc #92 is E + 93
        adc #1                      ; C = 0: the bcs fell through
        and #3
        sta O_EL,y
        sec                         ; C = 1 for the shared adc, whatever the step left
@f:     adc #92
        jmp addsprite

; ---------------------------------------------------------------- POWERUP (10)
ob_powerup:                         ; in place: A (O_AL) the pickup's progress; Y = obj
        lda O_AL,y                  ; (reloaded after bar_touch)
        bne @adv
        ldx health                  ; health 1 or 2 only: 0 wraps to 255
        dex
        cpx #2
        bcs @draw
        ldx #52
        jsr csweep
        bcc @draw
        lda #3
        sta health
        jsr bar_touch               ; A = 1 on return and Y kept (lda #1 / sta BARDIRTY)
        sta O_AL,y                  ; the pickup starts (O_AL was 0: bne @adv fell through)
        lda #SFX_POWER
        sta SFXREQ
        bne @draw                   ; Z = 0: SFX_POWER is 6
@adv:   cmp #6
        bcs @done
        adc #2                      ; C = 0: the bcs was not taken; two steps
        sta O_AL,y
@draw:  lda O_AL,y
        lsr
        bne @pk                     ; picking up: its frames
        sta q2                      ; A = 0 (the bne fell through): box_safe tests Cleo
        lda O_EL,y                  ; at rest: its baked box (every powerup has one: the
        ldx #80                     ;  full dither, its reds kept -- assets.py), kept still
                                    ;  as the stars' and trampolines' are (box_safe: rx, ry
                                    ;  are Cleo's; her band, the boomerang's +4)
        clc
        jmp box_safe
@pk:    cmp #3
        bcs @done
        adc #97
        jmp addsprite
@done:  rts

; ---------------------------------------------------------------- VANISHING BLOCK (11)
ob_vanish:
        lda fe
        bne @count
        ; rx > -16 && rx <= 0 && ry == 16 && vy == 0
        ldx #56
        jsr csweep
        bcc @ret
        lda vy
        ora vy+1
        bne @ret
        inc fe                      ; fe was 0: bne @count fell through
@ret:   rts
@count: inc fe
        lda fe
  .if ::BHW
        and #3                      ; bitimm's save and restore of A are not needed:
        bne @ret                    ; A is reloaded
        lda fe
  .else
        bit #3
        bne @ret
  .endif
        cmp #12
        bcc @half                   ; fe < 12: fe >> 1
        cmp #37
        lda #6                      ; lda keeps C from the cmp
        bcc @set
        lda #48
        sbc fe                      ; carry is already set: bcc fell through
@half:  lsr
@set:   sta q1
        ; the tiles at (ox>>3, oy>>3) and one right: the frame's ids from the header
        mov16 qx, ox
        mov16 qy, oy
        jsr tilexy                  ; X = tile x, A = tile y
        sta q5                      ; tile y (q4/q5: gx/gy are the live grid-walk cursor)
        jsr maptile                 ; sets mapptr, Y = tx; X kept, bank 7 back
        ldx q1
        lda LV_HDR+HDR_SPECIAL,x
        jsr mapput                  ; X and Y kept
        iny
        lda LV_HDR+HDR_SPECIAL+1,x
        jsr mapput
        dey
        lda fe                      ; the count's wrap first (mark_dirty leaves fe
        eor #48                     ;  alone), so the marks can be the tail
        bne @mk                     ; A = 0 when fe = 48
        sta fe
@mk:    tya                         ; tile x
        ldx q5                      ; (falls into mark_pair; A, X, Y dead on return)

; mark tiles (A, X) and (A+1, X) dirty, in that order: the vanishing block's and the
; switch's pairs.  mark_dirty keeps its tmp = A, tmp2 = X.  A, X, Y clobbered.
mark_pair:
        ldy #0                      ; the map has changed: no map memo (getaltitude)
        sty mok                     ;  (Y is free: mark_dirty takes A and X)
        jsr mark_dirty
        ldx tmp
        inx
        txa
        ldx tmp2
        jmp mark_dirty

; ---------------------------------------------------------------- SWITCH (12)
ob_switch:
        lda fd
        bne @draw
        ldx #60
        jsr csweep
        bcc @draw
        lda #$20                    ; (BCD)
        jsr addscore
        lda #SFX_POWER
        sta SFXREQ
        ; copy map columns (A-2, A-1) -> (A, A+1) for rows B .. B+C-1
        lda fc
        beq @set
        sta q4
        lda fb
        sta q5                      ; row counter (q5: the grid-walk cursor must stay intact)
@rl:    ldx fa
        dex
        dex
        lda q5
        jsr maptile                 ; mapptr = row, Y = X = fa-2, A = (row),fa-2
        iny
        iny
        jsr mapput                  ; -> (row),fa
        dey
        jsr mapbyte                 ; A = (row),fa-1
        iny
        iny
        jsr mapput                  ; -> (row),fa+1
        lda fa
        ldx q5
        jsr mark_pair               ; (row),fa and (row),fa+1
        inc q5
        dec q4
        bne @rl
@set:   inc fd                      ; fd = 0 here (bne @draw fell through): now 1
@draw:  lda fd
        clc
        adc #100
        jmp addsprite

; ============================================================================
; Status bar digits (drawn straight into the bar, from bank 7's packed digits)
; ============================================================================
        .segment "GAMECODE"         ; bank 7, with the digit art
; draw digit A at bar pixel column X (even), digit slot Y (0..8): its 16 packed bytes
; become 64 bytes of the bar.
;
; The bar remembers the nine values it was last drawn with, because redraw_hud redraws
; all nine whenever anything changes and a score tick usually moves only one of them --
; the other eight were copies for no pixels (5.0K cycles a render on an L0 run, 3.2% of
; the frame, when measured).  The bank is BANK_LVL on entry and on exit, so the skip
; path must not touch it.
draw_health:                        ; falls into bar_digit
        lda health
        ldx #46
        ldy #1
bar_digit:
        cmp BARCACHE,y              ; one bar, so one cache: no curbuf in the index
        beq bd_same
        sta BARCACHE,y
        asl                         ; d * 16: the digit's packed bytes (assets.py:
        asl                         ; a nibble per byte column and two game rows)
        asl
        asl
        sta tmp4
        stx ptr                     ; x is even at every call: x * 4 = char * 8
        lda #0                      ; the high byte, built in A
        asl ptr
        rol a
        asl ptr
        rol a                       ; C = 0: A was 0 or 1, so this rol shifted a 0 out
  .assert <BARADDR = 0, error, "bar_digit: the low-byte add was dropped"
        adc #>BARADDR               ; (<BARADDR = 0: nothing to add to the low byte)
        sta ptr+1
        jsr @row                    ; the top char row, then the one below it
        add16i ptr, 640
@row:   ldy #0                      ; 8 packed bytes -> 32: each byte column's four
@b:     ldx tmp4                    ; line pairs, top line and bottom from DIGTOP/BOT
        lda digits_art,x
        inc tmp4
        pha
        lsr
        lsr
        lsr
        lsr
        tax
        lda DIGTOP,x
        sta (ptr),y
        iny
        lda DIGBOT,x
        sta (ptr),y
        iny
        pla
        and #$0F
        tax
        lda DIGTOP,x
        sta (ptr),y
        iny
        lda DIGBOT,x
        sta (ptr),y
        iny
        cpy #32
        bne @b
bd_same:
        rts

  .if .defined(DBGHIT) .or .defined(DBGTILE)
; (debug) score += X, counted in the BCD byte score+Y (0 ones, 1 hundreds); X, Y
; clobbered
dbg_bcd:
        txa
        beq @r
        sed
@l:     tya
        pha
        sec                         ; + 1, carried up
@c:     lda score,y
        adc #0
        sta score,y
        iny
        bcc @n
        cpy #3
        bcc @c
@n:     pla
        tay
        dex
        bne @l
        cld
@r:     rts
  .endif
bar_touch:
        lda #1
        sta BARDIRTY
        rts


redraw_hud:                         ; lives and stars inlined (redraw_hud was their one caller)
        lda lives                   ; lives: 1 digit at 18
        ldx #18
        ldy #0
        jsr bar_digit
        jsr draw_health
        lda stars                   ; stars remaining: 2 digits at 74, 82
        ldx #0                      ; X = A / 10, q1 = A mod 10 (div10, inlined)
:       cmp #10
        bcc :+
        sbc #10
        inx
        bcs :-                      ; always: A >= 10 went in, so C = 1
:       sta q1
        txa
        ldx #74
        ldy #2
        jsr bar_digit
        lda q1
        ldx #82
        ldy #3
        jsr bar_digit               ; and falls into draw_score
draw_score:                         ; 5 digits at 108..140: the BCD score's nibbles,
        ldx #8                      ; slots 8..4, the ones first
@d:     stx q1                      ; the slot (bar_digit keeps q1)
        lda #8
        sec
        sbc q1                      ; the digit's number, 0..4: its byte, and C = the high
        lsr                         ;  nibble's
        tay
        lda score,y
        bcc :+
        lsr
        lsr
        lsr
        lsr
:       and #$0F
        pha
        lda q1
        tay                         ; Y = the slot (the cache's)
        asl
        asl
        asl                         ; C = 0: slot*8 < 128
        adc #76                     ; slot*8 + 76 = 108..140
        tax
        pla
        jsr bar_digit
        ldx q1
        dex
        cpx #4
        bcs @d
        rts
        .segment "GAMECODE"
; ============================================================================
; bar_bg: the bar has a fixed home outside the ring, so it stays put however the
; window scrolls and is only written when its contents change (in the ring it would
; move with every vertical scroll: 1280 bytes to copy again, 13,310 cycles).  Its
; template (icons, labels, blank digit slots) is the BAR file, which the
; loader puts in place with the game's image (ldprog.s) and nothing redraws.  The template
; buries the digits, so this resets the digit cache: its "already drawn" values are
; no longer true.  One bar, one cache: not one per buffer.
; ============================================================================
bar_bg:
        ldx #8                      ; A = LDOP_GAME ($80) from ldprog's one call: never a
                                    ; digit, so every slot reads as not drawn
@bci:   sta BARCACHE,x
        dex
        bpl @bci
        rts

; ============================================================================
; Random
; ============================================================================
rnd:    lsr seed+1
        ror seed
        bcc :+
        lda seed+1
        eor #$B4
        sta seed+1
:       lda seed
        rts

; The map's row addresses (level_init) and inrange's limits: tables whose reads are
; hot, each in a page.
        .segment "GAMEBSS"
BARCACHE:  .res 16                  ; bar_bg resets it, bar_digit keeps it
; (the small variables in the room before MROWH's half page)
mok:       .res 1                   ; the map memo (getaltitude): 0 for none; where it is
mkx:       .res 1                   ;  (the tile's qx & $F8, qx+1, qy & $F8, qy+1); the
mkxh:      .res 1                   ;  tile, and the tiles above and below it
mky:       .res 1
mkyh:      .res 1
mt:        .res 1
ma:        .res 1
mb:        .res 1
pxs:       .res 1                   ; Cleo's px, py at her move's start (player_update),
pys:       .res 1                   ;  and her move that frame, across and down: the
dxl:       .res 1                   ;  stretch csweep tests
dyl:       .res 1
bdx:       .res 1                   ; the boomerang's move this frame (bsweep's stretch)
bdy:       .res 1
bmx:       .res 1                   ; and what of it is still to make (8 px at a time)
bmy:       .res 1
swd:       .res 1                   ; span's: the stretch, its low end, r, and Y kept
swa:       .res 1
swl:       .res 1
swh:       .res 1
swy:       .res 1
swe:       .res 1                   ; (sweep's: the move down)
        .align 128                  ; (GAMEBSS is page aligned: MROWH in one page, and
MROWH:     .res 128                 ;  LV_OBJST on the next; the row addresses' high bytes)
        .segment "GAMELVL"          ; $8220-$82FF: bank 7 below the image's variables
RNGTAB:    .res 88                  ; inrange's limits: the level file's header tail
        .assert RNGTAB = LV_HDR + 32, error, "RNGTAB: where the loader puts the header's tail"
MROWL:     .res 128                 ; the row addresses' low bytes
; The red snake's rise above its basket, by its counter A & 31 (A = -15..16 while it
; is up): (A*A >> 3) - 28, the reference's parabola (CleoApp.run), baked
        .segment "GAMEDATA"
risetab:
        .repeat 32, i
          .if i < 17
        .byte <((i*i >> 3) - 28)
          .else
        .byte <(((32-i)*(32-i) >> 3) - 28)
          .endif
        .endrepeat
; The score and the hi-score: BCD, ones first, five digits shown (a sixth in the
; top byte's high nibble is room).  Resident -- bank 7's last page, kept through
; both images: the menus show them and set the hi-score; the game keeps them.
        .segment "GAMEHI"
score:     .res 3
hiscore:   .res 3
        .assert hiscore = score + 3, error, "draw_number: Y = 0 score, 3 hi-score"
        .assert >MROWL = >(MROWL+127) && >MROWH = >(MROWH+127), warning, "MROWL/MROWH cross a page: their reads +1"

        .segment "GAMECODE"      
; ============================================================================
; Sound effect ids
; ============================================================================
SFX_JUMP  = 1
SFX_STAR  = 2
SFX_THROW = 3
SFX_HIT   = 4
SFX_KILL  = 5
SFX_POWER = 6
SFX_DIE   = 7
