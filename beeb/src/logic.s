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
        bvc :+
        eor #$80
:      bmi label
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
        bvc :+
        eor #$80
:      bpl label
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
score:    .res 2
hiscore:  .res 2
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
q1x:      .res 1
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

; getaltitude: A = altitude (signed) at pixel (qx, qy)  [qy modified; tp clobbered]
; It reads the tile at (qx, qy) and at most one of the tiles above and below it, so
; the three come from one visit to the map (mapcol) and the rest is arithmetic.  A
; pixel off the map takes the general way (@off), a read at a time through getinfo.
getaltitude:
        lda qy+1                    ; tilexy's, in line, the row into X and the column
        cmp maph+1                  ; into Y
        bcs @offj
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
        bcs @offj
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
        ALTOF
        tax                         ; X = n3 (the alt byte)
        and #15
        sta q3                      ; n3 & 15
        lda qy
        and #7
        sta q5                      ; n5
        cmp q3
        bcc @fnb                    ; n5 < (n3 & 15)
        lda qy                      ; C = 1 from the cmp: +7 is +8
        adc #7
        sta qy
        bcc @fb1
        inc qy+1
@fb1:   lda qy+1                    ; the pixel 8 below: the tile below, or getinfo's 8
        cmp maph+1                  ; past the map's bottom (tilexy's test)
        lda #8
        bcs @fb2
        lda tp+1
        ALTOF
@fb2:   lsr
        lsr
        lsr
        lsr
        clc
        adc #9                      ; as @b1's
        sbc q5
        rts
@offj:  jmp @off                    ; (a pixel off the map: out of the tests' reach)
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
        bcs @fn1
        dec qy+1
@fn1:   lda qy+1                    ; the pixel 8 above: the tile above, or getinfo's 8
        cmp maph+1                  ; above the map's top (qy+1 = $FF) or past it
        lda #8
        bcs @fn2
        lda tp
        ALTOF
@fn2:   jmp @nb2
@off:   lda #8                      ; getinfo's for a pixel off the map
        tax                         ; X = n3 (the alt byte)
        and #15
        sta q3                      ; n3 & 15
        lda qy
        and #7
        sta q5                      ; n5
        cmp q3
        bcc @notbelow               ; n5 < (n3 & 15)
@below: lda qy                      ; C = 1 from the cmp: +7 is +8
        adc #7
        sta qy
        bcc @b1
        inc qy+1
@b1:    jsr getinfo
        lsr
        lsr
        lsr
        lsr
        clc
        adc #9                      ; the extra 1 pays the borrow: A <= 24 so adc leaves
        sbc q5                      ; C = 0, and (A+9) - q5 - 1 is the (A+8) - q5 wanted
        rts
@notbelow:
        txa
        lsr
        lsr
        lsr
        lsr                         ; n4
        bne @d2
        lda qy
        sec
        sbc #8
        sta qy
        bcs :+
        dec qy+1
:       jsr getinfo
@nb2:   tax
        and #15
        cmp #8
        beq @eq
        lda #0                      ; n4, which was 0
        beq @d2
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
        cmp maph+1                  ; column into Y
        bcs @out
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
        tay
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
        lda LV_HDR+HDR_STARTX
        jsr @x8
        sta startx
        stx startx+1
        lda LV_HDR+HDR_STARTY
        jsr @x8
        sta starty
        stx starty+1
        lda LV_HDR+HDR_EXITX
        jsr @x8
        sta exitx
        stx exitx+1
        lda LV_HDR+HDR_EXITY
        jsr @x8
        sta exity
        stx exity+1
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
        ldx #RNGTABN-1              ; inrange's limits, into their page (RNGTAB0)
@rng:   lda RNGTAB0,x
        sta RNGTAB,x
        dex
        bpl @rng
        lda #80                     ; the camera starts centred; the lookahead eases in
        sta camoff
        ; clear object state, then grid
        lda #0
        tax
        sta BINOK                   ; the cached object list belongs to the old level
        sta starclk                 ; the stars' clock: every phase from the level's start
        sta stars
        sta bent
:       sta O_STAMP,x
        sta O_STAMP+256,x
        sta O_STAMP+512,x
        sta O_STAMP+768,x
        sta O_STAMP+1024,x
        sta O_STAMP+1280,x
        sta O_STAMP+1536,x
        sta O_STAMP+1792,x
        sta O_STAMP+2048,x
        sta O_STAMP+2304,x
        inx
        bne :-
        dex                         ; X = $FF: the stamp loop left X = 0
        txa                         ; A = $FF
:       sta LV_GRID-128,x           ; X = $FF..$80: LV_GRID+127 down to +0
        dex
        bmi :-
        ; objects, last to first
        ldy nobj
        bne :+
        jmp @objdone
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
  .if BHW
        ldx #0                      ; X is free until jsr @x8: (t16,x) is (t16), Y kept
        lda (t16,x)
  .else
        lda (t16)                   ; lda (t16), Y kept: it is still obj
  .endif
        sta otype
        sta O_TYPE,y                ; Y is still obj (sty obj at @ol; nothing since has touched Y)
        ldy #1
        lda (t16),y
        sta q1                      ; x tiles
        jsr @x8
        ldy obj
        sta O_XL,y
        txa
        sta O_XH,y
        ldy #2
        lda (t16),y
        sta q2                      ; y tiles
        jsr @x8
        ldy obj
        sta O_YL,y
        txa
        sta O_YH,y
        ; all state words start at zero (the level pack only covers the record; O_* is bare RAM)
        lda #0
        sta O_AL,y
        sta O_AH,y
        sta O_BL,y
        sta O_BH,y
        sta O_CL,y
        sta O_CH,y
        sta O_DL,y
        sta O_DH,y
        sta O_EL,y
        sta O_EH,y
        ldy #3
        lda (t16),y
        sta q3                      ; e0
        iny
        lda (t16),y
        sta q4                      ; e1
        iny
        lda (t16),y
        sta q5                      ; e2
        ; bounding box defaults: x0 = (x-1)>>3, y0 = y>>3, x1 = x>>3, y1 = (y+1)>>3
        lda q1
        beq :+                      ; submin0 1 open-coded: A=0 stays 0, else A-1
  .if BHW
        clc                         ; A - 1: the carry dies at the lsr
        adc #$FF
  .else
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
        lda q2
        lsr
        lsr
        lsr
        sta gy
        lda q2
  .if BHW
        clc                         ; A + 1: the carry dies at the lsr
        adc #1
  .else
        inc a
  .endif
        lsr
        lsr
        lsr
        sta gy1
        ldy obj
        lda otype
        beq @t0
        cmp #1
        beq @t1
        cmp #2
        beq @t256a
        cmp #5
        beq @t256a
        cmp #6
        bne :+
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
        jmp @box                    ; 7, 10: defaults
@t0:    lda q3
        sta O_EL,y                  ; e0 = box class from the converter (0 none/1 cyan/2 black)
        lda q4
        sta O_EH,y                  ; e1 = an enemy's range covers this one
        jsr rnd                     ; (drawn as ever, so the enemies' draws follow as they were)
        lda q5                      ; e2: its phase in the spin, the packer's (balanced
        sta O_AL,y                  ;  over the stars a screen shows at once)
        inc stars
        lda gy                      ; the prologue already left q2>>3 in gy
        sta gy1
        lda q2
        beq :+
  .if ::BHW
        sec                         ; A-1; the carry is dead (lsr follows)
        sbc #1
  .else
        dec a
  .endif
:       lsr
        lsr
        lsr
        sta gy
        jmp @box
@t1:    lda q3                      ; e0 = its rest state's baked box id (0: none), e1 =
        sta O_EL,y                  ; an enemy's range covers it (assets.py) -- stored as
        lda q4                      ; @t0 does for a star (a trampoline never had them:
        sta O_EH,y                  ; its black boxes were never drawn)
        lda O_XL,y
        ora #4                      ; x*8 has bit 2 clear: +4 cannot carry into O_XH
        sta O_XL,y
        lda q1
        submin0 2
        lsr
        lsr
        lsr
        sta gx0
        lda q1
  .if ::BHW
        clc                         ; A+1; the carry is dead (lsr follows)
        adc #1
  .else
        inc a
  .endif
        lsr
        lsr
        lsr
        sta gx1
        lda gy1
        sta gy
        jmp @box
@t256:  lda q3
        asl
        asl
        asl
        sta O_AL,y
        lda q3
        lsr
        lsr
        lsr
        lsr
        lsr
        sta O_AH,y
        lda q1
        clc
        adc q3
        lsr
        lsr
        lsr
        sta gx1
        jmp @box
@t3:    lda q2
        submin0 4
        lsr
        lsr
        lsr
        sta gy
        jmp @box
@t4:    lda q3
        asl
        asl
        asl
        asl
        sta O_AL,y
        ora #1                      ; A+1 for mod16: the low nibble is clear, so no carry
        sta t16b
        lda q3
        lsr
        lsr
        lsr
        lsr
        sta O_AH,y
        sta t16b+1
        ; C = rnd % (A+1) ; D = rnd % (B+1)  (A,B < 4096) -> use rnd16 & mask then reduce
        jsr rnd
        sta t16
        jsr rnd
        and #$0F
        sta t16+1
        jsr mod16
        lda t16
        sta O_CL,y
        lda t16+1
        sta O_CH,y
        lda q4
        asl
        asl
        asl
        asl
        sta O_BL,y
        ora #1                      ; B+1, likewise
        sta t16b
        lda q4
        lsr
        lsr
        lsr
        lsr
        sta O_BH,y
        sta t16b+1
        jsr rnd
        sta t16
        jsr rnd
        and #$0F
        sta t16+1
        jsr mod16
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
        lda q1
        clc
        adc q3
        lsr
        lsr
        lsr
        sta gx1
        lda q2
        clc
        adc q4
        lsr
        lsr
        lsr
        sta gy1
        bpl @box                    ; N = 0 after lsr
@t9:    lda gy                      ; the prologue left q2>>3 in gy: that is gy1
        sta gy1
        lda q2
        submin0 2
        lsr
        lsr
        lsr
        sta gy
        bpl @box                    ; N = 0 after lsr
@t11:   lda gy
        sta gy1
        bpl @box                    ; gy = q2>>3 < 32: N = 0
@t12:   lda q3
        sta O_AL,y
        lda q4
        sta O_BL,y
        lda q5
        sta O_CL,y
@box:   ; insert into grid cells gx0..gx1 x gy..gy1
        lda gy1
        cmp gy                      ; branch out iff gy1 < gy, i.e. gy > gy1
        bcc @nextobj
@bx:    lda gx0                     ; per grid row: gx = gx0, then
        sta gx                      ; cell = gx + (gy << gridsh): the gx loop below
        lda gy                      ; steps the cell index with inx instead of reshifting
        ldx gridsh
        beq :++
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
        lda gx
        cmp gx1
        beq :+
        inc gx
        inx
        bne @cell                   ; X = cell+1 in 1..128: never 0
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
        mov16 px, startx
        mov16 py, starty
        sty vx                      ; Y = 0 on both ways in (ldy nobj / ldy obj)
        sty vx+1
        sty vy
        sty vy+1
        sty anim
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
; Per frame update.  Fills the sprite list; sets wx/wy.
; ============================================================================
game_frame:
        inc frame
        bne :+
        inc frame+1
:       lda frame                   ; the stars' clock: a step on even frames, 0..11
        lsr
        bcs @sc1
        lda starclk
        adc #1                      ; C = 0: the bcs was not taken
        cmp #12
        bcc @sc0
        lda #0
@sc0:   sta starclk
@sc1:   stz bounce                  ; A is dead: lda health follows
        ; ---- camera
        lda health
        beq @cam
        ; horizontal lookahead: ease the window's bias toward 40 (facing right, so
        ; Cleo sits 1/4 from the left and sees ahead) or 120 (facing left, 3/4) by one
        ; pixel a logic step -- one character a rendered frame -- so she drifts to 3/4
        ; of the way to her side of the screen without a visible snap.
        ldx #40
        lda facing                  ; 1 = left
        beq :+
        ldx #120
:       cpx camoff
        beq @offok
        bcs @offup                  ; target > camoff (cpx: C set when X >= camoff)
        dec camoff
        bcc @offok                  ; C = 0: the bcs above was not taken
@offup: inc camoff
@offok: lda px
        sec
        sbc camoff
        sta wx
        lda px+1
        sbc #0
        sta wx+1
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
        sta t16
        lda wx+1
        rol
        asl t16
        rol
        sta gx0
        lda wx                      ; gx1 = (wx + 159) >> 6
        clc
        adc #159
        sta t16
        lda wx+1
        adc #0
        asl t16
        rol
        asl t16
        rol
        sta gx1
        lda wy                      ; gy = wy >> 6
        asl
        sta t16
        lda wy+1
        rol
        asl t16
        rol
        sta gy
        lda wy                      ; gy1 = (wy + VISLINES/2-1) >> 6
        clc
        adc #VISLINES/2-1
        sta t16
        lda wy+1
        adc #0
        asl t16
        rol
        asl t16
        rol
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
        lda gx1
        cmp BINR+1
        bne @rebuild
        lda gy
        cmp BINR+2
        bne @rebuild
        lda gy1
        cmp BINR+3
        bne @rebuild
        lda BINOK
        beq @rebuild
        jmp @runlist                ; (the traversal between here and it is too far for
@rebuild:                           ;  a branch)
        lda gx0
        sta BINR
        lda gx1
        sta BINR+1
        lda gy
        sta BINR+2
        lda gy1
        sta BINR+3
  .if BHW
        lda #0                      ; one zero for both
        sta NSTARL
        sta NOTHL
  .else
        stz NSTARL
        stz NOTHL
  .endif
        lda #1
        sta BINOK
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
        stz BINI
@rls:   ldx BINI
        cpx NSTARL
        beq @rlo
        ldy LV_BINSTAR,x
        lda frame
        sta O_STAMP,y
        jsr po_star                 ; no type read, no table, no obj (nothing a star
                                    ; runs reads it)
        inc BINI
        bne @rls                    ; BINI < NSTARL <= 255: never 0
@rlo:   stz BINI
@rl2:   ldx BINI
        cpx NOTHL
        beq @rldone
        ldy LV_BINOTH,x
        lda frame
        sta O_STAMP,y
        sty obj
        jsr process_object
        inc BINI
        bne @rl2                    ; BINI < NOTHL <= 255: never 0
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
        sta score
        stz score+1
@dbgt:
  .endif
        lda health
        bne :+
        lda hurt
        bne @nokill
:       mov16 qx, px
        clc
        lda py
        adc #12
        sta qy
        lda py+1
        adc #0
        sta qy+1
        jsr gettileattr
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
        ldx obj
        beq @dh1
@dh0:   lda score
        clc
        adc #100
        sta score
        bcc @dh2
        inc score+1
@dh2:   dex
        bne @dh0
@dh1:   lda otype
        clc
        adc score
        sta score
        bcc @dh3
        inc score+1
@dh3:
  .endif
        mov16 evframe, frame
        dec health
        lda #1                      ; bar_touch, inlined
        sta BARDIRTY
        sta hurt
  .if BHW
        lda #0                      ; one zero for three stores
        sta control
        sta vx
        sta vy
  .else
        stz control
        stz vx                      ; both knockback speeds and -1280 have
        stz vy                      ; a zero low byte
  .endif
        lda health
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
        ; vy = (vy + 80) * 31 >> 5 ; py += (vy+128)>>8
        jsr gravity
        jsr vy_step
        add16 py, dpx
        ; if (frame - evframe) > 60 -> respawn (unsigned delta: wrap-safe)
        lda frame
        sec
        sbc evframe
        tax
        lda frame+1
        sbc evframe+1
        bne @respawn
        cpx #61
        bcc @draw
@respawn:
        mov16 px, startx
        mov16 py, starty
  .if BHW
        lda #0
        sta vx
        sta vx+1
        sta vy
        sta vy+1
        sta anim
  .else
        stz vx
        stz vx+1
        stz vy
        stz vy+1
        stz anim
  .endif
        mov16 evframe, frame
        lda #3
        sta health
        dec lives
        bne :+
        lda #1
        sta exiting                 ; game over handled by caller (lives == 0)
        rts
:
  .if BHW
        lda #0
        sta facing
        sta running
        sta firing
  .else
        stz facing
        stz running
        stz firing
  .endif
        lda #1
        sta hurt
        sta control
        sta BARDIRTY                ; bar_touch, inlined
@draw:  mov16 spx, px
        mov16 spy, py
        lda #26
        jmp addsprite

; vy = (vy + 80) * 31 >> 5
gravity:
        add16i vy, 80
        sec
        lda #0
        sbc vy
        sta t16
        lda #0
        sbc vy+1                    ; A = high byte of -vy, not yet stored
        .repeat 5
        cmp #$80                    ; C = sign of the current high byte
        ror a                       ; arithmetic shift of the high byte, in A
        ror t16                     ; and of the low byte, in place
        .endrepeat
        tax                         ; the step's high byte
        clc
        lda vy
        adc t16
        sta vy
        txa
        adc vy+1
        sta vy+1
        rts

; dpx = (vy + 128) >> 8 (signed)
vy_step:
        ldx #0                      ; X = dpx+1, the sign extension
        lda vy                      ; C = the carry out of vy low + 128
        cmp #$80
        lda vy+1
        adc #0                      ; A = (vy + 128) >> 8
        bmi @up
        cmp #MAXDWY+1
        bcc @st
        lda #MAXDWY
@st:    sta dpx
        stx dpx+1
        rts
@up:    dex                         ; dpx+1 = $FF
        cmp #<-MAXDWY
        bcs @st
        lda #<-MAXDWY
        bcc @st                     ; C = 0 from the compare

; ============================================================================
; player alive update
; ============================================================================
player_update:
        ; alt = getAltitude(px, py+16)
        mov16 qx, px
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
        lda firing
        bne @nothrow
        lda control
        beq @nothrow
        lda keys
        and #K_DOWN
        beq @nothrow
        lda bactive
        bne @nothrow
        sta anim                    ; A = 0: bactive, just tested
        inc firing                  ; 0 -> 1: firing was tested zero above
@nothrow:
        ; vertical velocity
        bmi16 vy, @grav
        lda alt
        beq :+
        bpl @grav
:       stz vy                      ; both arms zero it: -1280 = $FB00, low byte zero
        lda firing
        bne @stand
        lda control
        beq @stand
        lda keys
        and #(K_UP|K_FIRE)
        beq @stand
        lda #>(-1280)
        sta vy+1
        lda #SFX_JUMP
        sta SFXREQ
        bne @move                   ; always: SFX_JUMP = 1
@stand: stz vy+1
        lda #1
        sta control
        bne @move                   ; always: A = 1
@grav:  jsr gravity
@move:  jsr vy_step
        bpl16 dpx, @down            ; dpx+1 is 0 or $FF (vy_step)
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
@down:  lda alt                     ; dy = min(dy, alt); dpx+1 = 0 here
        cmp dpx
        bcs :+
        sta dpx
:       sec
        sbc dpx
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
  .if BHW
        lda #0
        sta health
        sta control
        sta vx
        sta vx+1
  .else
        stz health
        stz control
        stz vx
        stz vx+1
  .endif
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
        bne :+
        jmp @nofric
:
        ldx alt
        beq :+
        bpl @air
:
        cmp #3                      ; A = q6 (push), still
        beq @air
        ; ground: vx = vx*61>>6 + push*24
        lda vx
        asl
        tax                         ; X = 2*vx low, C untouched by tax
        lda vx+1
        rol                         ; A = 2*vx high
        tay
        txa
        clc
        adc vx
        sta t16                     ; t16 = 3vx low
        ldx #0
        tya
        adc vx+1                    ; A = 3vx high, N = its sign
        bpl :+
        dex
:       stx t16+1                   ; t16+1:A:t16 = 3vx sign-extended to 24 bits
        asl t16                     ; two left shifts: t16+1:A = floor(3vx/64)
        rol
        rol t16+1
        asl t16
        rol
        rol t16+1                   ; t16 = the dropped bits (3vx & 63) << 2
        ldy #0
        cpy t16                     ; C = nothing dropped: floor == ceil
        eor #$FF
        adc vx                      ; vx + ~floor + C = vx - ceil(3vx/64)
        sta vx
        lda vx+1
        sbc t16+1
        sta vx+1
        ; * 24: |24*q6| <= 96, so it fits in 8 bits and needs one sign extension
        lda q6
        asl
        asl
        asl
        sta t16                     ; 8p
        asl                         ; 16p
        clc
        adc t16                     ; 24p, N = its sign
        bpl :+
        dey                         ; Y = 0 from above: now the sign fill
:       clc
        adc vx
        sta vx
        tya
        adc vx+1
        sta vx+1
        jmp @nofric
@air:   ; vx = vx*5>>3 : vx + asr3(-3vx) == asr3(5vx), and 5vx still fits 16 bits
        lda vx+1
        sta t16+1
        lda vx
        asl
        rol t16+1
        asl
        rol t16+1                   ; A:t16+1 = 4vx (low in A, t16 not written)
        clc
        adc vx
        sta vx                      ; 5vx low, straight into vx: no add16 at the end
        lda t16+1
        adc vx+1                    ; A = 5vx high (vx+1 not written yet)
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
        cmp #(K_LEFT|K_RIGHT)
        beq @norun
        tax
        lda running
        ora firing
        bne :+
        sta anim                    ; A = running|firing = 0
:       ; accel = (alt > 0 || push == 3) ? 288 : 36
        lda alt
        beq :+
        bpl @acc288
:       lda q6
        cmp #3
        beq @acc288
        stz t16+1                   ; A dead: loaded next
        lda #36
        bne @acclo                  ; Z = 0 from the load
@acc288:
        lda #>288
        sta t16+1
        lda #<288
@acclo: sta t16
@acc:   txa
        and #K_LEFT                 ; A = 1 left, 0 right: the facing flag
        sta facing
        beq @right
        sub16 vx, t16
        jmp @run
@right: add16 vx, t16
@run:   lda #1
        sta running
        bne @hmove                  ; Z = 0 from the load
@norun: stz running                 ; A dead: @hmove reloads it
@hmove:
        ; steps = (vx + 128) >> 8 ; dir = sign
        lda vx
        cmp #$80                    ; C = carry out of vx_lo + 128, without the clc
        lda vx+1
        adc #0                      ; A = high byte of vx + 128
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
:       stz alt                     ; A is dead: @hnext reloads it
        jmp @hnext
@stepn: clc                         ; negative: high byte of the addend is $FF
        adc py
        sta py
        bcs :-                      ; no borrow (255 times in 256): py+1 is unchanged,
        dec py+1                    ; so join the 0/1 case's tail instead of adding $FF
        jmp :-
@alt:   sta alt
@hnext: ; steps -= dir
        lda dpx+1
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
        lda dpx+1
        jmp @hstep
@wall:
  .if BHW
        lda #0                      ; one zero for both (A is dead: @hdone reloads)
        sta vx
        sta vx+1
  .else
        stz vx
        stz vx+1
  .endif
@hdone:
        ; animation counters
        inc anim
        lda firing
        beq @notfiring
        lda anim
        cmp #4
        bne :+
        ; launch boomerang
        mov16 bx, px
        mov16 by, py
  .if BHW
        lda #0                      ; one zero for the four clears
        sta bvx
        sta bvy
        sta bvy+1
        sta bcnt
  .else
        stz bvx
        stz bvy
        stz bvy+1
        stz bcnt
  .endif
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
        stz firing                  ; A dead; Z = 1 after it on both (cmp #12 equal /
        beq @animdone               ; Model B's lda #0)
@notfiring:
        lda running
        beq :+
        lda anim
        cmp #16
        bne @animdone
        stz anim                    ; A dead; Z = 1 after it on both (cmp #16 equal /
        beq @animdone               ; Model B's lda #0)
:       lda anim
        cmp #128
        bne @animdone
        stz anim
@animdone:
        ; timers
        lda hurt
        beq @afterhurt
        ; clear after (frame - evframe) > 64, using an unsigned delta so it works
        ; across the 16-bit frame wrap (a signed compare stuck the flashing state)
        lda frame
        sec
        sbc evframe
        tax                         ; hold the low byte of the delta in X
        lda frame+1
        sbc evframe+1
        bne @clrhurt                ; elapsed >= 256 -> clear
        cpx #65
        bcs @clrhurt
        lda control                 ; hurt stands, so the delta is still in X and its
        bne @ctl                    ; high byte was zero: reuse it for the control
        cpx #25                     ; timer instead of subtracting frame-evframe twice
        bcc @noctl
        bcs @setctl                 ; always
@clrhurt:
        stz hurt
@afterhurt:
        lda control
        bne @ctl
        lda frame
        sec
        sbc evframe
        tax                         ; hold the low byte of the delta in X
        lda frame+1
        sbc evframe+1
        bne @setctl
        cpx #25
        bcc @noctl
@setctl:
        inc control                 ; control is 0 on both ways in
        bne @ctl                    ; always: it is 1 now
@noctl:
        ldx #22
        lda vx+1
        bmi @spr2
        lda vx
        beq @spr2
        inx                         ; 23
@spr2:  jmp @spr+1                  ; past @spr's tax: the frame is in X already
@ctl:   lda firing
        beq @nofire
        lda anim
        cmp #4
        bcc @f14
        cmp #6
        bcc @f16
        cmp #10
        bcc @f18
@f16:   lda #16
        bne @sprf
@f14:   lda #14
        bne @sprf
@f18:   lda #18
        bne @sprf
@nofire:
        bmi16 vy, @jump
        lda alt
        beq @ground
        bpl @jump
@ground:
        lda anim
        ldx running                 ; X dead: @sprf ends in tax
        beq @standing
        lsr
        and #$FE                    ; (anim >> 2) << 1 with one shift, not three
        bpl @sprf                   ; N=0: lsr cleared bit 7
@standing:
        cmp #93
        bcc @s8
        cmp #109
        bcc @s10
        cmp #113
        bcc @s12
@s10:   lda #10
        bne @sprf
@s8:    lda #8
        bne @sprf
@s12:   lda #12
        bne @sprf
@jump:  ble16i vy, -384, @j20
        bge16i vy, 384, @j24
        lda #22
        bne @sprf
@j20:   lda #20
        bne @sprf                   ; always: Z = 0 from the load
@j24:   lda #24
@sprf:  ora facing
@spr:   tax
        lda hurt
        beq @drawp
        lda frame
        and #3
        bne @boom
@drawp: mov16 spx, px
        mov16 spy, py
        txa
        jsr addsprite
@boom:  ; ---- boomerang
        lda bactive
        bne :+
        jmp @bdone
:
        dif16 rx, px, bx            ; rx = px - bx
        sec                         ; ry = (py - by) + 8: one carry chain, not two
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
        bcc @ry8
        inc ry+1
@ry8:
        ; caught?
        lda rx                      ; rx in -7..7 iff rx+7 is 0..14 unsigned
        cmp #$F9                    ; C = carry out of rx+7's low byte
        lda rx+1
        adc #0                      ; A = high byte of rx+7
        bne @nocatch
        bcs @xin                    ; rx+1 was $FF: rx = -7..-1
        lda rx                      ; rx+1 was 0: rx = 0..248
        cmp #8
        bcs @nocatch
@xin:   lda ry                      ; the same for ry, whose low byte less 8 is still in X
        cmp #$F9
        lda ry+1
        adc #0                      ; A = high byte of ry+7
        bne @nocatch
        cpx #$F1                    ; low(ry+7) = X+15 < 15 iff X >= $F1
        bcc @nocatch
.if BHW
        dec bactive                 ; bactive is 1 here (0/1 flag, nonzero on entry)
.else
        stz bactive
.endif
@nocatch:
        lda bcnt
        cmp #8
        bcc :+
        jmp @bfly
:
        ; bvx = bvx*61>>6 + rx*2 ; bx += (bvx+128)>>8
        sec                         ; t16 = -bvx: negate first, then double in place
        lda #0
        sbc bvx
        sta t16
        lda #0
        sbc bvx+1                   ; A = high byte of -bvx
        asl t16
        rol                         ; A = high byte of -2*bvx
        tax
        sec
        lda t16
        sbc bvx
        sta t16
        txa
        sbc bvx+1                   ; A = high byte of -3*bvx
        ldx #6
:       cmp #$80
        ror
        ror t16
        dex
        bne :-
        tax
        clc
        lda bvx
        adc t16
        sta bvx
        txa
        adc bvx+1
        sta bvx+1
        asl16 rx
        add16 bvx, rx
        lda bvx
        cmp #$80                    ; C = bit 7 of bvx = carry out of (bvx + 128)
        lda bvx+1
        ldx #0                      ; X = sign of the delta (N from the adc)
        adc #0                      ; A = high byte of bvx + 128
        bpl :+
        dex
:       clc                         ; bx += the delta, and qx = bx for getaltitude
        adc bx
        sta bx
        sta qx
        txa
        adc bx+1
        sta bx+1
        sta qx+1
        sec                         ; t16 = -bvy, same shape as the bvx block above
        lda #0
        sbc bvy
        sta t16
        lda #0
        sbc bvy+1                   ; A = high byte of -bvy
        asl t16                     ; -2*bvy: high byte in A, then X
        rol
        tax
        sec
        lda t16
        sbc bvy
        sta t16
        txa
        sbc bvy+1                   ; A = high byte of -3*bvy
        ldx #6
:       cmp #$80
        ror
        ror t16
        dex
        bne :-
        sta t16+1
        add16 bvy, t16
        asl16 ry
        add16 bvy, ry
        lda bvy                     ; only the high byte of bvy+128 is ever used
        asl                         ; C = bit 7 of bvy
        lda bvy+1
        adc #0
        bpl :+                      ; X = 0 from the loop: sign-extend the delta into it
        dex
:       clc
        adc by
        sta by
        sta qy
        txa
        adc by+1
        sta by+1
        sta qy+1
        jsr getaltitude
        bpl @bfly
        lda #8
        sta bcnt
@bfly:  inc bcnt
        lda bcnt
        cmp #8
        bne :+
        stz bcnt                    ; (Model B: A = 0, and 0 fails cmp #14 as 8 does)
:       cmp #14
        bne :+
        stz bactive
:       lda bactive
        beq @bdone
        mov16 spx, bx
        mov16 spy, by
        lda bcnt
        lsr
        clc
        adc #27
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
        lda O_TYPE,y
        sta otype
        asl                         ; X = otype*2, the dispatch index
        tax
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
  .if ::BHW                         ; jmpx less its pha/pla: every handler loads A before
        lda @tab,x                  ; reading it
        sta jv
        lda @tab+1,x
        sta jv+1
        jmp (jv)
  .else
        jmp (@tab,x)
  .endif
@tab:   .word ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .word ob_spike, ob_none, ob_flame, ob_powerup, os_vanish, os_switch

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
        jsr ob_vanish
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
        OOUT fa, O_AL
        OOUT fb, O_BL
        OOUT fc, O_CL
        OOUT fd, O_DL
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
ob_none:
        rts

; (RNGTAB0 is the table's source: level_init copies it to RNGTAB, in GAMELVL's page
; ($82) where no code change can move it, as inrange's reads are hot.)
RNGTAB0:                            ; inrange limit quads: lo, hi, lo2, hi2, each +128
        .byte 112, 144, 112, 148        ; 0: <-16, 16, <-16, 20
        .byte 120, 136, 120, 136        ; 4: <-8, 8, <-8, 8
        .byte 119, 145, 128, 136        ; 8: <-9, 17, 0, 8
        .byte 112, 144, 104, 140        ; 12: <-16, 16, <-24, 12
        .byte 120, 136, 112, 132        ; 16: <-8, 8, <-16, 4
        .byte 116, 140, 110, 130        ; 20: <-12, 12, <-18, 2
        .byte 118, 138, 120, 144        ; 24: <-10, 10, <-8, 16
        .byte 116, 140, 116, 140        ; 28: <-12, 12, <-12, 12
        .byte 112, 144, 116, 144        ; 32: <-16, 16, <-12, 16
        .byte 116, 140, 0, 255          ; 36: <-12, 12, <-128, 127
        .byte 112, 144, 104, 148        ; 40: <-16, 16, <-24, 20
        .byte 118, 138, 112, 136        ; 44: <-10, 10, <-16, 8
        .byte 120, 128, 104, 136        ; 48: <-8, 0, <-24, 8
        .byte 112, 144, 104, 140        ; 52: <-16, 16, <-24, 12
        .byte 112, 129, 143, 145        ; 56: <-16, 1, 15, 17
        .byte 112, 144, 104, 140        ; 60: <-16, 16, <-24, 12
        ; Guard bands: not "close enough to collect" but "the drawn rectangles touch".
        ; Append new quads, never insert: callers hold fixed offsets, and a quad put in
        ; mid-table once shifted every later one under them (the bat read Cleo's band,
        ; the vanishing platforms never saw her feet).
        .byte 105, 147, 113, 152        ; 64: Cleo      <-23, 19, <-15, 24
        .byte 111, 144, 118, 143        ; 68: boomerang <-17, 16, <-10, 15
        ; trampoline guard bands (its box (-16..8, 8..16) grown by the disturber's box,
        ; which the star bands imply is Cleo x(-15,13) y(-11,16), boomerang x(-9,10) y(-6,7))
        .byte 105, 157, 101, 136        ; 72: Cleo      <-23, 29, <-27, 8
        .byte 111, 154, 106, 127        ; 76: boomerang <-17, 26, <-22, -1
RNGTABN = * - RNGTAB0
        .assert RNGTABN <= 80, error, "RNGTAB0 has outgrown its copy (gamedata.s RNGTAB)"
        .assert >RNGTAB = >(RNGTAB+RNGTABN-1), warning, "RNGTAB crosses a page (+1 cycle an inrange read)"

; range check: rx > lo && rx < hi && ry > lo2 && ry < hi2 ; X = offset of the limit
; quad in RNGTAB (limits stored +128 so the test is an unsigned byte compare on r^$80,
; after checking r fits in -128..127 - anything wider fails every limit anyway).
; Returns carry set if inside. Clobbers A, X.
inrange:
        lda rx                      ; r fits -128..127 iff hi + (lo's sign) = 0 mod 256
        asl                         ; C = the low byte's sign
        lda rx+1
        adc #0                      ; $FF+1 and 0+0 are 0; nothing else is
        bne @no
        lda rx
        eor #$80
        cmp RNGTAB,x
        bcc @no
        beq @no                     ; rx > lo
        cmp RNGTAB+1,x
        bcs @no                     ; rx < hi
        lda ry
        asl
        lda ry+1
        adc #0
        bne @no
        lda ry
        eor #$80
        cmp RNGTAB+2,x
        bcc @no
        beq @no
        cmp RNGTAB+3,x
        bcs @no
        sec
        rts
@no:    clc
        rts


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
addscore:                           ; A = points
  .if .defined(DBGHIT) .or .defined(DBGTILE)
        rts                         ; (debug: the score is a readout)
  .endif
        clc
        adc score
        sta score
        bcc :+
        inc score+1
:       jmp bar_touch

; ---------------------------------------------------------------- STAR (0)
; Cleo's two tests on a star -- the collect (RNGTAB quad 0) and box_safe's (quad 64)
; -- can only pass with rx in -22..18.  So the star list's prologue (po_star) tests
; rx against that first, and outside it sets q2 (Cleo far): both tests are skipped,
; and ry, which only they read, is not worked out.  The boomerang's tests set rx and
; ry themselves (boomrel), and clear q2, as does every other way in.
ob_star:                            ; the object table's way in (the list full: rare)
        lda #0
        sta q2
        beq ob_star1                ; always: Z from the lda
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
        bne @neg
        lda rx
        cmp #19
        bcc @near                   ; 0..18
        bcs @far
@neg:   cmp #$FF
        bne @far
        lda rx
        cmp #<-22
        bcs @near                   ; -22..-1
@far:   lda #1
        sta q2
        bne ob_star1                ; always
@near:  lda spy
        sec
        sbc py
        sta ry
        lda spy+1
        sbc py+1
        sta ry+1
        lda #0
        sta q2
ob_star1:
        lda O_CL,y
        beq @live
        ; ---- collected: the sparkle, its own count 12..18, a step on even frames
        lda frame
        lsr                         ; C = frame bit 0: odd frames do not step
        lda O_AL,y
        bcs @anim
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
        jsr inrange
        bcs @collect
@tryboom:
        lda bactive
        beq @phase
        jsr boomrel
        lda #0
        sta q2                      ; rx, ry are the boomerang's: box_safe tests them
        ldx #4
        jsr inrange
        bcc @phase
@collect:
        lda #12
        sta O_AL,y
        lda #1
        sta O_CL,y
        dec stars
  .if .defined(DBGHIT) .or .defined(DBGTILE)
        jsr bar_touch               ; (debug: addscore stops short of it)
  .endif
        jsr addscore                ; A = 1 still; it ends in jmp bar_touch
        lda #SFX_STAR
        sta SFXREQ
        lda #12                     ; the sparkle's first step
        bne @anim                   ; always
        ; ---- the spin: the level's star clock plus this star's phase (A, the
        ; packer's), mod 12 -- a star out of the bin window keeps its place in step
@phase: lda O_AL,y
        clc
        adc starclk
        cmp #12
        bcc @anim
        sbc #12                     ; C = 1: the bcc was not taken
@anim:  cmp #18
        bcs @done
        lsr
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
ob_tramp:
        lda O_AL,y
        beq :+
  .if BHW
        clc                         ; the carry is dead: cmp #10 below sets it
        adc #1                      ; (inca would keep it, through mtmp, at 6 bytes)
  .else
        inc a                       ; there is no inc abs,y, and A holds it anyway
  .endif
        sta O_AL,y
        cmp #10
        bne :+
        lda #0                      ; nor stz abs,y
        sta O_AL,y
:       lda health
        beq @draw
        ldx #8
        jsr inrange
        bcc @draw
        lda vy+1                    ; bmi16 vy and beq16 vy from one load
        bmi @draw
        ora vy
        beq @draw
        lda #1
        sta O_AL,y
        mov16i vy, -2048
        lda #SFX_JUMP
        sta SFXREQ
@draw:  lda O_AL,y                  ; at rest (0): its rest state's baked box, if it has
        bne @bounce                 ; one (assets.py: an id a trampoline; 0 for none)
        lda O_EL,y
        bne @rest
@bounce: clc                        ; (A = O_AL, or 0: frame 0)
        adc #2
        lsr
        lsr                         ; bounce frame 0..2: the masked frames
        clc
        adc #43
        jmp addsprite
@rest:  ldx #0
        stx q2                      ; (box_safe's Cleo test: rx, ry are hers)
        ldx #72                     ; box_safe: Cleo's RNGTAB quad (the boomerang's is +4)
        clc
        ; fall through
; A = frame, X = the RNGTAB quad for Cleo (64 star, 72 trampoline; the boomerang's is
; X+4 -- inrange and boomrel leave X alone), C = 0.  Adds BOXN if nothing can draw
; through the box, then tail-calls addsprite.  (For the trampoline rx/ry are still
; Cleo-relative: ob_tramp does not call boomrel.)
box_safe:
        sta q1
        lda O_EH,y                  ; an enemy's range covers it
        bne @no
        lda q2
        bne @cfar                   ; Cleo far (a star's prologue said so)
        jsr inrange                 ; Cleo overlaps its rectangle
        bcs @no
@cfar:  lda bactive
        beq @yes
        jsr boomrel
        txa
        ora #4
        tax
        jsr inrange                 ; the boomerang overlaps it
        bcs @no
@yes:   lda q1                      ; both ways in fall through a 'bcs @no' that was not
        adc #BOXN                   ; taken, so C is already clear here
        sta q1
@no:    lda q1
        jmp addsprite

; ---------------------------------------------------------------- GREEN SNAKE (2)
ob_snake:                           ; in place: Y = obj throughout (reloaded after
                                    ; addscore, whose bar_touch changes it).  Fields:
                                    ; A (O_AL/AH) the turn point, B (O_BL/BH) the offset,
                                    ; C (O_CL) the state, E (O_EL) the counter
        lda O_EL,y                  ; both arms step the counter
        clc
        adc #1
        sta O_EL,y
        ldx O_CL,y                  ; X is free here (the handler never reads it before a load)
        cpx #2
        bcs @s23
        cmp #12
        bne @st
        beq @z                      ; E = 12: back to 0
@s23:   cmp #64
        bne @st
        txa                         ; C
        and #1
        sta O_CL,y
@z:     lda #0
        sta O_EL,y
@st:    lda O_CL,y
        beq @c0
        cmp #1
        beq @c1
        cmp #4
        bcc @coll                   ; 2, 3
        jmp @c45                    ; 4, 5: dying, out of line
@c0:    jsr @pausef
        bcs @coll
        lda O_BL,y                  ; B + 1 (C = 0: the bcs was not taken)
        adc #1
        sta O_BL,y
        bcc @c0b
        lda O_BH,y
        adc #0                      ; C = 1: + 1
        sta O_BH,y
@c0b:   lda O_BL,y                  ; B = A: on to state 1
        cmp O_AL,y
        bne @coll
        lda O_BH,y
        cmp O_AH,y
        bne @coll
        lda #1                      ; C = 0 here (we came by beq @c0): 0 -> 1, Z = 0
        sta O_CL,y
        bne @coll
@c1:    jsr @pausef
        bcs @coll
        lda O_BL,y                  ; B - 1
        bne @c1b
        lda O_BH,y                  ; the low byte is 0: borrow from the high one
        sbc #0                      ; (C = 0: the bcs was not taken, so this is - 1)
        sta O_BH,y
        lda #0
@c1b:   sec
        sbc #1
        sta O_BL,y
        bne @coll
        lda O_BH,y                  ; B = 0: back to state 0
        bne @coll
        sta O_CL,y                  ; A = 0 (the bne above was not taken)
        beq @coll                   ; and Z = 1 from that load
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
        jsr inrange
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
        ; stomped
        bcc @st2
        lda #5
        jsr addscore
        ldy obj
@st2:   lda O_CL,y
        clc
        adc #2
        sta O_CL,y
        lda #1
        sta bounce
        lsr                         ; A = 0
        sta O_EL,y
        lda #SFX_KILL
        sta SFXREQ
        bne @boom                   ; always: A = SFX_KILL (5), Z = 0
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
        jsr inrange
        bcc @draw
        lda O_CL,y
        cmp #4
        bcs @draw
        lda #5
        jsr addscore
        ldy obj
        lda #4
        bit bvx+1
        bpl @b4
        lda #5
@b4:    sta O_CL,y
        lda #0
        sta O_EL,y
        lda #8
        sta bcnt
        lda #SFX_KILL
        sta SFXREQ
@draw:  lda O_BL,y                  ; B <= -128: not drawn (ble16i's bias form)
        cmp #<(-127)
        lda O_BH,y
        eor #$80
        sbc #(>(-127) ^ $80)
        bcc @done
        lda O_BL,y                  ; B - A against 128, as @c4 (C = 1: the bcc fell through)
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
; states 4 and 5, the snake dying: out of line (C = O_CL,y in A)
@c45:   cmp #4                      ; (A = C: 4 or 5)
        bne @c5
@c4:    ; if B < A + 128: B += 16
                                    ; C = 1 here (cmp #4 / bne @c5): B - A against the
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
        jmp @coll
@c5:    lda O_BL,y                  ; B <= -128: to @coll (ble16i's bias form)
        cmp #<(-127)
        lda O_BH,y
        eor #$80
        sbc #(>(-127) ^ $80)
        bcc @cj
        lda O_BL,y                  ; C = 1: the bcc was not taken
        sbc #16
        sta O_BL,y
        bcs @cj
        lda O_BH,y
        sbc #0                      ; C = 0: - 1
        sta O_BH,y
@cj:    jmp @coll
; carry set if the counter (E) is one of the pause frames 0,3,6,9
@pausef:
        lda O_EL,y
        beq @p1
        cmp #3
        beq @p1
        cmp #6
        beq @p1
        cmp #9
        beq @p1
        clc
        rts
@p1:    sec
        rts

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
        lda O_BL,y
        ora O_BH,y
        beq @up
        jmp @knocked
@up:
        ; A is a dormancy counter running -127..17 (CleoApp.run case 3: A++, and at 17
        ; A = -(rnd&63)-64) -- the same idiom as the spike, and a signed byte holds it.
        lda O_AL,y
        clc
        adc #1
        sta O_AL,y
        cmp #17
        bne @norst
        jsr rnd
        and #63
        eor #63
        clc
        adc #129                    ; 192-r: the byte form of -(r&63)-64
        sta O_AL,y
@norst: ; rise = (A*A >> 3) - 28 while the snake is up.
        ; The reference skips when A <= -16 (CleoApp.run 2865: bipush -16, if_icmple),
        ; so it is up for A >= -15.
                                    ; A = the counter on both ways in
        eor #$80                    ; bias the signed byte so the compare can be unsigned
        cmp #113                    ; -15 -> 113: at -16 the rise is +4 and the tall
        bcc @nowarm                 ; frame's tail shows 4 px under the basket; at -15
                                    ; it is 0 and the snake is flush with its bottom
@calc:  lda O_AL,y
        bpl @sq
        eor #$FF
        adc #0                      ; C = 1: the cmp #113 fell through (inca is 6 bytes)
@sq:    jsr square                  ; returns A = t16, the low byte (X only: Y kept)
        lsr t16+1                   ; rise = (A*A >> 3) - 28, the low byte shifted in A;
        ror a                       ; t16 itself is dead after this
        lsr t16+1
        ror a
        lsr t16+1
        ror a
        sec
        sbc #28
        sta rise
        lda t16+1
        sbc #0
        sta rise+1
        lda #1
        sta q6                      ; snake visible
        bne @boom                   ; always: A = 1
@nowarm:
        lda #0
        sta q6
@boom:  jsr boomready
        bcc @hitp
        jsr boomrel
        ldx #20
        jsr inrange
        bcc @hitp
        lda #4
        jsr addscore
        ldy obj
        ldx #1
        bgt16 ox, px, @kx
        ldx #2
@kx:    txa
        sta O_BL,y
        lda #0
        sta O_BH,y
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
        jsr inrange
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
@basket:
        mov16 spx, ox
        mov16 spy, oy
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
@k1:    lda O_CL,y                  ; C -= 16
        sec
        sbc #16
        sta O_CL,y
        lda O_CH,y
        sbc #0
        sta O_CH,y
        lda O_BL,y
        cmp #1
        bne @kl
        lda O_DL,y                  ; D += 16
        clc
        adc #16
        sta O_DL,y
        lda O_DH,y
        adc #0
        sta O_DH,y
        jmp @kf
@kl:    lda O_DL,y                  ; D -= 16
        sec
        sbc #16
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
        lda ox
        adc O_DL,y
        sta spx
        lda ox+1
        adc O_DH,y
        sta spx+1
        mov16 spy, oy
        lda #60
        jmp addsprite


; t16 = A * A (A unsigned 0..128)
square: sta q1
        sta q1x
        lda #0                      ; accumulator low byte lives in A
        sta t16+1                   ; and the high byte starts at the same zero
        ldx #8
@l:     asl
        rol t16+1
        asl q1
        bcc :+
        clc
        adc q1x
        bcc :+
        inc t16+1
:       dex
        bne @l
        sta t16
        rts
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
@alive: adc #1                      ; A = E < 8 and C = 0 from the bcc:
        and #7                      ; E = (E + 1) & 7
        sta O_EL,y
        lda O_CL,y
        sta fc
        lda O_CH,y
        sta fc+1
        lda O_DL,y
        sta fd
        lda O_DH,y
        sta fd+1
        ; rx += C>>1 ; ry += D>>1 (Y is scratch here)
        lda fc+1                    ; X:Y = fc >> 1 (arithmetic); rx += it, spx += it
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
        ; chase
        ldy obj
        bpl16 rx, @rxpos
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
        jmp @ydir
@rxpos: beq16 rx, @ydir
        beq16 fc, @ydir
        bmi16 fc, @ydir
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
        jmp @vput
@rypos: beq16 ry, @vput
        lda fd+1
        bmi @vput
        ora fd
        beq @vput
        lda fd
        bne @dl
        dec fd+1
@dl:    dec fd
@vput:  lda fc                      ; the velocity back
        sta O_CL,y
        lda fc+1
        sta O_CH,y
        lda fd
        sta O_DL,y
        lda fd+1
        sta O_DH,y
@boom:  jsr boomready
        bcc @player
        mov16 t16, rx
        mov16 t16b, ry
        jsr boomrel
        ldx #28
        jsr inrange
        mov16 rx, t16               ; lda/sta do not touch carry
        mov16 ry, t16b
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
        jsr inrange
        bcc @draw
        ble16i ry, 4, @nostomp
        lda vy+1                    ; bmi16 vy, then beq16 vy, from one load
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
        jsr inrange
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
@wob:   ; wobble: x += BAT_OFFSET[(frame + obj*5) & 15] ; y += BAT_OFFSET[((5*frame>>2) + obj*7) & 15]
        lda obj
        asl
        asl
        clc
        adc obj
        adc frame
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
@wx2:   lda frame
        asl
        asl                         ; A = 5*frame, low byte only: the high byte of
        clc                         ; 5*frame is dead (the >>2 below shifts the low
        adc frame                   ; byte alone, and only t16's low byte is used)
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
        ldx O_BH,y                  ; t16+1 = B's high byte + 1; the low byte is B's own
        inx
        stx t16+1
        lda O_DL,y
        cmp O_BL,y
        lda O_DH,y
        sbc t16+1
        bvc @dv
        eor #$80
@dv:    bpl @done
        clc                         ; A += 120, keeping the new low byte in X
        lda O_AL,y
        adc #120
        sta O_AL,y
        tax
        lda O_AH,y
        adc #0
        sta O_AH,y                  ; want only the high byte of A + 128:
        cpx #$80                    ; C = carry out of A_lo + 128
        adc #0                      ; the step, signed (N from the adc)
        bmi @dneg
        clc                         ; D += it
        adc O_DL,y
        sta O_DL,y
        lda O_DH,y
        adc #0
        sta O_DH,y
        jmp @fdok
@dneg:  clc                         ; D += it, sign extended
        adc O_DL,y
        sta O_DL,y
        lda O_DH,y
        adc #$FF
        sta O_DH,y
@fdok:
        lda O_CH,y                  ; spx += C >> 1 (arith)
        cmp #$80
        ror a
        tax                         ; the high half waits in X (dead: addsprite loads it)
        lda O_CL,y
        ror a
        clc
        adc spx
        sta spx
        txa
        adc spx+1
        sta spx+1
        lda O_DH,y                  ; same again for D into spy
        cmp #$80
        ror a
        tax
        lda O_DL,y
        ror a
        clc
        adc spy
        sta spy
        txa
        adc spy+1
        sta spy+1
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
        lda O_EL,y                  ; E + 1, 12 back to 0
        clc
        adc #1
        cmp #12
        bne @e
        lda #0
@e:     sta O_EL,y
        lda frame
        and #1
        sta q1                      ; frame & 1: the step is q1 + 1, the + 1 the carry's
        lda O_CL,y
        bne @left
        lda O_BL,y                  ; walking right.  B can be -1 coming in (the left
        sec                         ; path rests one past the near end), and the carry
        adc q1                      ; out of the add is what clears its sign byte -- drop
        sta O_BL,y                  ; that and -1 + 2 becomes -255, not 1.  (sec: the + 1)
        bcc @r1
        lda O_BH,y
        adc #0                      ; C = 1: + 1
        sta O_BH,y
        lda O_BL,y
@r1:    cmp O_AL,y                  ; past here B's high byte is 0 and B is 0..194, so
        bcc @coll                   ; the unsigned compare says what the signed 16-bit did
        lda #1                      ; C = 0 here (bne @left fell through): now 1
        sta O_CL,y
        bne @coll                   ; always
@left:  lda O_BL,y
        clc                         ; B - q1 - 1: the step (C = 0 is the - 1)
        sbc q1
        sta O_BL,y
        beq @stop                   ; B reached 0 (a borrow never leaves zero: >= 254)
        bcs @coll                   ; no borrow, not zero: still walking
        lda O_BH,y                  ; borrow == B went negative: that IS the bmi16 test
        sbc #0                      ; (C = 0: - 1)
        sta O_BH,y
@stop:  lda #0
        sta O_CL,y
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
        jsr inrange
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
        jsr inrange
        bcc @draw
        bit bvx+1
        bmi @bleft
        ; bvx > 0: if B < A: C = 0 (bge16's signed compare)
        lda O_BL,y
        cmp O_AL,y
        lda O_BH,y
        sbc O_AH,y
        bvc @bv
        eor #$80
@bv:    bpl @bset
        lda #0
        sta O_CL,y
        beq @bset                   ; always
@bleft: ; bvx < 0: if B > 0: C = 1
        lda O_BH,y
        bmi @bset
        lda O_BL,y
        beq @bset
        lda #1
        sta O_CL,y
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
        lda O_AL,y
        clc
        adc #1
        sta O_AL,y
        cmp #24
        bne @nowrap
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
        jsr inrange
        bcc @draw
        lda hurt
        bne @draw
        mov16 hx, rx
        ora hx                      ; (A = rx+1 from the mov16) the original knocks Cleo
        bne @ph                     ; right when rx <= 0 (CleoApp.run case 7: rx > 0 is
        dec hx+1                    ; -768, else +768), player_hit only when hx < 0: level
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
ob_flame:                           ; in place: E (O_EL) the frame
        lda frame
        and #3
        bne @f
        lda O_EL,y
        clc
        adc #1
        and #3
        sta O_EL,y
@f:     lda O_EL,y
        clc
        adc #93
        jmp addsprite

; ---------------------------------------------------------------- POWERUP (10)
ob_powerup:                         ; in place: A (O_AL) the pickup's progress; Y = obj
        lda O_AL,y                  ; (reloaded after bar_touch)
        bne @adv
        lda health
        beq @draw
        cmp #3
        bcs @draw
        ldx #52
        jsr inrange
        bcc @draw
        lda #1                      ; A was 0: bne @adv fell through
        sta O_AL,y
        lda #3
        sta health
        jsr bar_touch
        ldy obj
        lda #SFX_POWER
        sta SFXREQ
        bne @draw                   ; Z = 0: SFX_POWER is 6
@adv:   cmp #6
        bcs @done
        adc #1                      ; C = 0: the bcs was not taken
        sta O_AL,y
@draw:  lda O_AL,y
        lsr
        cmp #3
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
        jsr inrange
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
        bne @done                   ; A is reloaded
        lda fe
  .else
        bit #3
        bne @done
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
        sty q4                      ; tile x + 1
        lda LV_HDR+HDR_SPECIAL+1,x
        jsr mapput
        dey
        tya                         ; tile x
        ldx q5
        jsr mark_dirty
        lda q4
        ldx q5
        jsr mark_dirty
        lda fe
        eor #48                     ; A = 0 when fe = 48 (A and C dead on return)
        bne @done
        sta fe
@done:  rts

; ---------------------------------------------------------------- SWITCH (12)
ob_switch:
        lda fd
        bne @draw
        ldx #60
        jsr inrange
        bcc @draw
        lda #20
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
        lda q5
        jsr maptile                 ; mapptr = row, Y = A
        dey
        dey
        jsr mapbyte                 ; A = (row),fa-2
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
        jsr mark_dirty
  .if BHW
        ldx fa                      ; inca is 6 bytes here
        inx
        txa
  .else
        lda fa
        inc a
  .endif
        ldx q5
        jsr mark_dirty
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
        lda #0
        sta ptr+1                   ; for the x * 4 below
        txa                         ; x is even at every call: x * 4 = char * 8
        asl
        rol ptr+1
        asl
        rol ptr+1
  .assert <BARADDR = 0, error, "bar_digit: the low-byte add was dropped"
        sta ptr                     ; (<BARADDR = 0 and C = 0: nothing to add)
        lda ptr+1                   ; C is already clear: ptr+1 was 0 or 1 before the second
        adc #>BARADDR               ; rol, so that rol shifted a 0 out
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

bar_touch:
        lda #1
        sta BARDIRTY
        rts


draw_lives:
        lda lives
        ldx #18
        ldy #0
        jmp bar_digit
draw_stars:                         ; stars remaining: 2 digits at 74, 82
        lda stars
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
        jmp bar_digit
redraw_hud:
        jsr draw_lives
        jsr draw_health
        jsr draw_stars              ; and falls into draw_score
draw_score:                         ; 5 digits at 108..140
        mov16 t16, score
        ldx #8                      ; X = digit slot 8..4 (div10_16 keeps X)
@d:     jsr div10_16                ; t16 /= 10 -> remainder
        txa                         ; not phx/txa: on a 6502 that is txa/pha/txa
        pha
        tay                         ; score digits are slots 4..8
        asl
        asl
        asl                         ; C = 0: slot*4 < 128
        adc #76                     ; slot*8 + 76 = 108..140
        tax
        lda q1
        jsr bar_digit
        plx
        dex
        cpx #4
        bcs @d
        rts
; t16 = t16 / 10 ; q1 = remainder (X kept)
        .segment "KRNCODE"          ; the kernel: the menus' too
div10_16:
        lda #0                      ; remainder lives in A for the whole loop
        ldy #16                     ; Y, not X: draw_score keeps its slot in X
@l:     asl t16
        rol t16+1
        rol a
        cmp #10
        bcc :+
        sbc #10
        inc t16
:       dey
        bne @l
        sta q1
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
        ldx #8
        lda #$FF
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

        .segment "LOWBSS"           ; (low RAM: the engine's segment, the game's bytes)
BARCACHE:  .res 16                  ; bar_bg resets it, bar_digit keeps it
; The map's row addresses (level_init) and inrange's limits: tables whose reads are
; hot, each in a page, outside the image's variables (so those end a page sooner)
        .segment "GAMELVL"          ; $8220-$82FF: bank 7 below the image's variables
RNGTAB:    .res 80                  ; inrange's limits (RNGTAB0, level_init's copy)
MROWL:     .res 128                 ; the row addresses' low bytes
        .segment "GAMEHI"           ; bank 7's last page, after the kernel's KRNHW
MROWH:     .res 128                 ; and their high bytes
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
