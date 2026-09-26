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
:                                   ; placeholder - keeps the anonymous-label count
        bcs label
.endmacro
; branch if var < imm
        ; branch if var < imm
.macro blt16i var, imm, label
        lda var
        cmp #<(imm)
        lda var+1
        eor #$80                    ; bias both sides by $8000 and compare unsigned:
        sbc #(>(imm) ^ $80)         ; the bias on the constant is free at assembly time
:                                   ; placeholder - keeps the anonymous-label count
        bcc label
.endmacro
        ; branch if var >= imm
.macro bge16i var, imm, label
        lda var
        cmp #<(imm)
        lda var+1
        eor #$80
        sbc #(>(imm) ^ $80)
:                                   ; placeholder - keeps the anonymous-label count
        bcs label
.endmacro
; branch if var <= imm
        ; branch if var <= imm
.macro ble16i var, imm, label
        lda var                     ; var <= imm is var < imm+1, so this is blt16i's
        cmp #<((imm)+1)             ; bias form: one instruction and no V fixup
        lda var+1
        eor #$80
        sbc #(>((imm)+1) ^ $80)
:                                   ; placeholder - keeps the anonymous-label count
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
NLEAN   = 2                        ; object types below this take the lean path in
                                   ; process_object: no zero-page staging at all
OBJN    = 149                      ; the most objects a level has (L7B); both targets
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
  .if .not MODELB                  ; (Model B: labels in bank 6, page aligned)
LV_MAPROWLO = $A900               ; bank 6: 256 : tile row -> map row address
LV_MAPROWHI = $AA00
  .endif

; ---------------------------------------------------------------- game state (zero page, persistent)
        .zeropage
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
pausing:  .res 1
exiting:  .res 1
level:    .res 1
lives:    .res 1
health:   .res 1
score:    .res 2
hiscore:  .res 2
maxlevel: .res 1
lastkeys: .res 1
logicvs:  .res 1
lsteps:   .res 1
gridsh:   .res 1                  ; log2 of the collision grid width
camoff:   .res 1                  ; window bias: px - camoff = window left (eased 40..120)

; transient temps (not preserved across disc loads)
ox      = $A8
oy      = $AA
fa      = $AC
fb      = $AE
fc      = $B0
fd      = $B2
fe      = $B4
rx      = $B6
ry      = $B8
sx      = $BA
sy      = $BC
qx      = $BE
qy      = $C0
alt     = $C2
q1      = $C3
q2      = $C4
q3      = $C5
q4      = $C6
q5      = $C7
q6      = $C8
obj     = $C9
gx      = $CA
gy      = $CB
grow    = $DE                   ; bucket walk: gy << gridsh
gx0     = $CC
gx1     = $CD
gy1     = $CE
bent    = $CF
otype   = $D0
t16     = $D1                     ; 2 bytes
t16b    = $D3                     ; 2 bytes
dpx     = $D5                     ; 2 bytes: player step count etc
hx      = $D7                     ; 2 bytes: rx used for hit direction
mapptr  = $D9                     ; 2 bytes
q1x     = $DB
rise    = $DC                     ; 2 bytes

        PLACE "LOGIC", "LGCCODE"

; ============================================================================
; Map queries.  The map is in bank 6 with the row tables and the row-page table,
; so these select it and put bank 7 back; maptilew leaves bank 6 selected for a
; caller that is about to write through mapptr.
; ============================================================================
; get map byte at tile (X = tx, A = ty) -> A = byte, q1 = page (0/1).  The per-page
; alt-class and attribute tables are 256 bytes apart (q1 used to be page*2, which sent
; every page-1 row's altitude lookup into LV_MAPROWLO: no ground, Cleo fell through
; the floor at the Vineyards spawn and wherever else those levels use page 1)
maptile:
        jsr maprow                  ; main RAM: the map is in bank 6 and this code is
        txa                         ; in bank 7, so every touch goes through a helper
        tay
        jmp mapbyte

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
        bcc :+
        lda #8
        rts
:       jsr maptile
        ; alt class = LV_ALTCLS[tile id]
        tay
        lda LV_ALTCLS,y
        ; ALTTAB[cls*8 + (qx&7)]
        asl
        asl
        asl
        eor qx                      ; (A & $F8) | (qx & 7): A's low 3 bits are 0
        and #$F8
        eor qx
        tay
        lda LV_ALTTAB,y
        rts

; getaltitude: A = altitude (signed) at pixel (qx, qy)  [qy modified]
getaltitude:
        jsr getinfo
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
        tax
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
        jsr tilexy                  ; X = qx>>3, A = qy>>3
        bcc :+
        lda #3
        rts
:       jsr maptile
        tay
        lda LV_ATTR0,y
        rts

; ============================================================================
; Level initialisation (level pack already loaded in bank 7)
; ============================================================================
level_init:
  .if .not MODELB
        jsr init_maprows            ; main RAM: the row tables live with the map
  .endif                            ; (Model B: none -- the row address is arithmetic)
        ; header
        lda LV_HDR+2
        jsr @x8
        sta startx
        stx startx+1
        lda LV_HDR+3
        jsr @x8
        sta starty
        stx starty+1
        lda LV_HDR+4
        jsr @x8
        sta exitx
        stx exitx+1
        lda LV_HDR+5
        jsr @x8
        sta exity
        stx exity+1
        lda LV_HDR+6
        sta nobj
        lda maplw
        sec
        sbc #3
        sta gridsh
        lda #80                     ; the camera starts centred; the lookahead eases in
        sta camoff
        ; clear object state, then grid
        lda #0
        tax
        sta BINOK                   ; the cached object list belongs to the old level
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
        inc t16+1                   ; Master $81: the bit the seed's >> 2 dropped
  .endif
  .if MODELB
        ldx #0                      ; X is free until jsr @x8: (t16,x) is (t16), Y kept
        lda (t16,x)
  .else
        ldazy t16                   ; lda (t16), Y kept: it is still obj
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
  .if MODELB
        clc                         ; A - 1: the carry dies at the lsr
        adc #$FF
  .else
        deca
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
  .if MODELB
        clc                         ; A + 1: the carry dies at the lsr
        adc #1
  .else
        inca
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
        jsr m_rnd
        jsr mod12
        sta O_AL,y
        inc stars
        lda gy                      ; the prologue already left q2>>3 in gy
        sta gy1
        lda q2
        beq :+
  .if ::MODELB
        sec                         ; A-1; the carry is dead (lsr follows)
        sbc #1
  .else
        deca
  .endif
:       lsr
        lsr
        lsr
        sta gy
        jmp @box
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
  .if ::MODELB
        clc                         ; A+1; the carry is dead (lsr follows)
        adc #1
  .else
        inca
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
        jsr m_rnd
        sta t16
        jsr m_rnd
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
        jsr m_rnd
        sta t16
        jsr m_rnd
        and #$0F
        sta t16+1
:                                   ; placeholder - keeps the anonymous-label count
        jsr mod16
        lda t16
        sta O_DL,y
        lda t16+1
        sta O_DH,y
        lda q2
        beq :+                      ; submin0 1 specialised: max(q2-1, 0)
.if MODELB
        sbc #0                      ; C = 0 from mod16's exit (bcc -> rts): A-1
.else
        deca
.endif
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
:                                   ; placeholder - keeps the anonymous-label count
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
        sty pausing
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

; A = A mod 12 (A unsigned)
mod12:  and #$7F
:       cmp #12
        bcc :+
        sbc #12
        bcs :-                      ; C = 1: cmp found A >= 12, so the sbc does not borrow
:       rts

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
:       stz bounce                  ; A is dead: lda health follows
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
        jsr m_clamp_window
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
  .if MODELB
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
:       sta grow
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
        lda O_TYPE,y
        bne @apo                    ; that, so a cached step and a rebuilt one take the
        ldx NSTARL                  ; same path through the handlers.  Stars go in their
        cpx #BINMAX                 ; own list: the walk then reaches ob_star without
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
        bra @walk
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
        bra @rows
:
@runlist:
        ; The stamp is written exactly as the traversal wrote it.  It is only read when
        ; a list is rebuilt, but 'cmp frame' tests the low byte alone: let a stamp go 256
        ; steps stale and an object returning to range matches it and is skipped -- for
        ; one step before, but for the whole life of a cached list now.
        stz BINI
@rls:   ldx BINI
        cpx NSTARL
        beq @rlo
        ldy LV_BINSTAR,x
        lda frame
        sta O_STAMP,y
        sty obj
        jsr po_star                 ; no type read, no table
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
:       sta hx+1                    ; facing left -> hx negative -> vx = +768
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
  .if MODELB
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
  .if MODELB
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
  .if MODELB
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
        jmp m_addsprite

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
:                                   ; placeholder - keeps the anonymous-label count
        bpl @push
@fell:  mov16 evframe, frame
  .if MODELB
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
:       cmp #3                      ; A = q6 (push), still
        beq @air
:
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
        bra @nofric
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
        bra @run
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
  .if ::MODELB
        beq @hnext                  ; the 6502 stz is lda #0 / sta: Z = 1
  .else
        bra @hnext
  .endif
@stepn: clc                         ; negative: high byte of the addend is $FF
        adc py
        sta py
        bcs :-                      ; no borrow (255 times in 256): py+1 is unchanged,
        dec py+1                    ; so join the 0/1 case's tail instead of adding $FF
        bra :-
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
        bra @hstep
@wall:
  .if MODELB
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
  .if MODELB
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
@spr2:  bra @spr+1                  ; past @spr's tax: the frame is in X already
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
        bne @sprf                   ; A = 14, Z = 0
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
        jsr m_addsprite
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
.if MODELB
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
        jsr m_addsprite
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
; Object processing.  Y = object index (obj).  Loads fields into zp, dispatches, stores back.
; ============================================================================
process_object:
        lda O_TYPE,y
        sta otype
        asl                         ; X = otype*2, the dispatch index, for both paths:
        tax                         ; neither prologue below touches X
        cmp #NLEAN*2                ; types below NLEAN read and write the arrays in
        bcs @gen                    ; place; the rest are still staged through zero page
@lean:  ; Nothing staged.  Y is the object index throughout -- none of these handlers,
        ; nor anything they call, touches it -- so each reads and writes its own fields
        ; where they live: one cycle over a zero-page access, against seven to fetch a
        ; field and eight to put it back.  Every object field is 8-bit (tools/objaudit.py
        ; and tools/objfields.mjs are how that was established per handler).
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
  .if ::MODELB                      ; jmpx less its pha/pla: every handler loads A before
        lda @tab,x                  ; reading it (ob_none returns to a setbank or to
        sta jv                      ; the lean path's caller, which only gets types 0/1)
        lda @tab+1,x
        sta jv+1
        jmp (jv)
  .else
        jmpx @tab
  .endif
        ; (@call is the jsr entry for the staged path)
@gen:   lda O_XL,y
        sta ox
        sta spx
        sec
        sbc px
        sta rx
        lda O_XH,y
        sta ox+1
        sta spx+1
        sbc px+1
        sta rx+1
        lda O_YL,y
        sta oy
        sta spy
        sec
        sbc py
        sta ry
        lda O_YH,y
        sta oy+1
        sta spy+1
        sbc py+1
        sta ry+1
        lda O_AL,y
        sta fa
        lda O_AH,y
        sta fa+1
        lda O_BL,y
        sta fb
        lda O_BH,y
        sta fb+1
        lda O_CL,y
        sta fc
        lda O_CH,y
        sta fc+1
        lda O_DL,y
        sta fd
        lda O_DH,y
        sta fd+1
        lda O_EL,y
        sta fe
        lda O_EH,y
        sta fe+1
        jsr @call
        ; store back
        setbank BANK_LVL, BANK_LVL
        ldy obj
        lda fa
        sta O_AL,y
        lda fa+1
        sta O_AH,y
        lda fb
        sta O_BL,y
        lda fb+1
        sta O_BH,y
        lda fc
        sta O_CL,y
        lda fc+1
        sta O_CH,y
        lda fd
        sta O_DL,y
        lda fd+1
        sta O_DH,y
        lda fe
        sta O_EL,y
        lda fe+1
        sta O_EH,y
        rts
@tab:   .word ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .word ob_spike, ob_none, ob_flame, ob_powerup, ob_vanish, ob_switch
po_star:                            ; the lean prologue, then straight in: the star list
        lda O_XL,y
        sta spx
        sec
        sbc px
        sta rx
        lda O_XH,y
        sta spx+1
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
        jmp ob_star
ob_none:
        rts

; range check: rx > lo && rx < hi && ry > lo2 && ry < hi2 ; X = offset of the limit
; quad in RNGTAB (limits stored +128 so the test is an unsigned byte compare on r^$80,
; after checking r fits in -128..127 - anything wider fails every limit anyway).
; Returns carry set if inside. Clobbers A, X.
inrange:
  .if ::MODELB                      ; r fits -128..127 iff hi + (lo's sign) = 0 mod 256
        lda rx
        asl                         ; C = the low byte's sign
        lda rx+1
        adc #0                      ; $FF+1 and 0+0 are 0; nothing else is
        bne @no
  .else
        lda rx+1
        inca                         ; $FF -> 0, 0 -> 1, anything else >= 2
        cmp #2
        bcs @no
        lda rx
        eor rx+1                    ; low byte sign must agree with the high byte
        bmi @no
  .endif
        lda rx
        eor #$80
        cmp RNGTAB,x
        bcc @no
        beq @no                     ; rx > lo
        cmp RNGTAB+1,x
        bcs @no                     ; rx < hi
  .if ::MODELB
        lda ry
        asl
        lda ry+1
        adc #0
        bne @no
  .else
        lda ry+1
        inca
        cmp #2
        bcs @no
        lda ry
        eor ry+1
        bmi @no
  .endif
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
RNGTAB:                             ; inrange limit quads: lo, hi, lo2, hi2, each +128
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
        ; (These sat at 32/36 for a while, which pushed every quad after them along by
        ; eight without moving their callers: the bat read Cleo's band, the vanishing
        ; platforms never saw her feet, and the spike and powerup boxes were wrong.)
        .byte 105, 147, 113, 152        ; 64: Cleo      <-23, 19, <-15, 24
        .byte 111, 144, 118, 143        ; 68: boomerang <-17, 16, <-10, 15
        ; trampoline guard bands (its box (-16..8, 8..16) grown by the disturber's box,
        ; which the star bands imply is Cleo x(-15,13) y(-11,16), boomerang x(-9,10) y(-6,7))
        .byte 105, 157, 101, 136        ; 72: Cleo      <-23, 29, <-27, 8
        .byte 111, 154, 106, 127        ; 76: boomerang <-17, 26, <-22, -1

; boomerang-relative position: sx = spx - bx ; sy = spy - by  (uses spx/spy as the object's draw pos)
boomrel:
        dif16 sx, spx, bx
        dif16 sy, spy, by
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
ob_star:
        lda frame
        lsr                         ; C = frame bit 0: odd frames do not step
        lda O_AL,y                  ; A = the star's A on every way to @nostep
        bcs @nostep
        cmp #18                     ; cap: a collected star's A must not wrap 8-bit
        bcs @nostep                 ; (it would make the star reappear ~every 20s).
  .if ::MODELB
        adc #1                      ; C = 0: the bcs was not taken
  .else
        inca                        ; A still holds it: there is no inc abs,y
  .endif
        sta O_AL,y
@nostep:
        cmp #12
        bne :+
        lda O_CL,y
        bne @anim                   ; (the reload at : would take the same branch)
        sta O_AL,y                  ; A = 0 (no stz abs,y either)
:       lda O_CL,y
        bne @anim
        lda health
        beq @tryboom
        ldx #0
        jsr inrange
        bcs @collect
@tryboom:
        lda bactive
        beq @anim
        jsr boomrel
        mov16 rx, sx
        mov16 ry, sy
        ldx #4
        jsr inrange
        bcc @anim
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
@anim:  lda O_AL,y
        cmp #18
        bcs @done
        lsr
        ldx O_EL,y
        beq @regc                   ; carry unknown on this path: force it
        cmp #6
        bcs @reg                    ; C = 1 here, so @reg can assume it
        adc boxbase-1,x
        ldx #64                     ; box_safe: Cleo's RNGTAB quad (the boomerang's is +4)
        bne box_safe                ; always: Z = 0 from the ldx
@regc:  sec
@reg:   adc #33                     ; +33 with C=1 is the old +34 with C=0
        jmp m_addsprite
@done:  rts
boxbase: .byte 103, 109

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
  .if MODELB
        clc                         ; the carry is dead: cmp #10 below sets it
        adc #1                      ; (inca would keep it, through mtmp, at 6 bytes)
  .else
        inca                        ; there is no inc abs,y, and A holds it anyway --
  .endif
        sta O_AL,y                  ; which also saves the reload the old code did
        cmp #10
        bne :+
        lda #0                      ; nor stz abs,y
        sta O_AL,y
:       lda health
        beq @draw
        ldx #8
        jsr inrange
        bcc @draw
        lda vy+1                    ; was bmi16 vy / beq16 vy: one load does both tests
        bmi @draw
        ora vy
        beq @draw
        lda #1
        sta O_AL,y
        mov16i vy, -2048
        lda #SFX_JUMP
        sta SFXREQ
@draw:  lda O_AL,y
        clc
        adc #2
        lsr
        lsr                         ; bounce frame 0..2
        clc                         ; hoisted: serves both arms
        ldx O_EL,y
        bne @box
        adc #43
        jmp m_addsprite
@box:   adc #115
        ldx #72                     ; box_safe: Cleo's RNGTAB quad (the boomerang's is +4)
        ; fall through
; A = frame, X = the RNGTAB quad for Cleo (64 star, 72 trampoline; the boomerang's is
; X+4 -- inrange and boomrel leave X alone), C = 0.  Adds BOXN if nothing can draw
; through the box, then tail-calls m_addsprite.  (For the trampoline rx/ry are still
; Cleo-relative: ob_tramp does not call boomrel.)
box_safe:
        sta q1
        lda O_EH,y                  ; an enemy's range covers it
        bne @no
        jsr inrange                 ; Cleo overlaps its rectangle
        bcs @no
        lda bactive
        beq @yes
        jsr boomrel
        mov16 rx, sx
        mov16 ry, sy
        txa
        ora #4
        tax
        jsr inrange                 ; the boomerang overlaps it
        bcs @no
@yes:   lda q1                      ; both ways in fall through a 'bcs @no' that was not
        adc #BOXN                   ; taken, so C is already clear here
        sta q1
@no:    lda q1
        jmp m_addsprite

; ---------------------------------------------------------------- GREEN SNAKE (2)
ob_snake:
        inc fe                      ; both arms step the counter
        lda fe
        ldx fc                      ; X is free here (the handler never reads it before a load)
        cpx #2
        bcs @s23
        cmp #12
        bne @st
        beq @z                      ; fe = 12: back to 0
@s23:   cmp #64
        bne @st
        txa                         ; fc
        and #1
        sta fc
@z:     stz fe
@st:    lda fc
        beq @c0
        cmp #1
        beq @c1
        cmp #4
        beq @c4
        cmp #5
        beq @c5
        bne @coll                   ; Z = 0: the cmp #5 did not match
@c0:    jsr @pausef
        bcs @coll
:
        inc fb
        bne :+
        inc fb+1
:       lda fb
        cmp fa
        bne @coll
        lda fb+1
        cmp fa+1
        bne @coll
        inc fc                      ; fc = 0 here (we came by beq @c0): 0 -> 1, Z = 0
        bne @coll
@c1:    jsr @pausef
        bcs @coll
        lda fb
        bne :+
        dec fb+1
:       dec fb
        bne @coll
        lda fb+1
        bne @coll
        sta fc                      ; A = fb+1 = 0 (the bne above was not taken)
        beq @coll                   ; and Z = 1 from that load
@c4:    ; if B < A + 128: B += 16
                                    ; C = 1 here (cmp #4 / beq @c4). B - A against the immediate 128, the way @c5
        lda fb                      ; tests its own limit -- no A + 128 built in t16
        sbc fa
        tax
        lda fb+1
        sbc fa+1
        eor #$80
        cpx #<128
        sbc #(>128 ^ $80)
:                                   ; placeholder - keeps the anonymous-label count
        bcs @coll
        lda fb                      ; C = 0: the bcs @coll above was not taken
        adc #16
        sta fb
        bcc @coll
        inc fb+1
        bcs @coll                   ; C = 1 still: inc leaves it
@c5:    ble16i fb, -128, @coll
        lda fb                      ; C = 1: ble16i's bcc was not taken
        sbc #16
        sta fb
        bcs @coll
        dec fb+1
@coll:  add16 rx, fb
        add16 spx, fb
        lda health
        beq @boom
        ldx #12
        jsr inrange
        bcc @boom
        lda fc
        cmp #4
        bcs @boom
        cmp #2                      ; C = fc >= 2 for both arms: no op below touches C
        lda ry+1
        bmi @nostomp
        ora ry
        beq @nostomp
        lda vy+1
        bmi @nostomp
        ora vy
        beq @nostomp
        ; stomped
        bcc :+
        lda #5
        jsr addscore
:       inc fc
        inc fc
  .if MODELB
        lda #1                      ; 6502: one byte under stz fe / lda #1
        sta bounce
        lsr                         ; A = 0
        sta fe
  .else
        stz fe
        lda #1
        sta bounce
  .endif
        lda #SFX_KILL
        sta SFXREQ
        bne @boom                   ; always: A = SFX_KILL (5), Z = 0
@nostomp:
                                    ; C = fc >= 2 still: the cmp #2 above the stomp tests
        bcs @boom
        lda hurt
        bne @boom
        mov16 hx, rx
        jsr player_hit
@boom:  jsr boomready
        bcc @draw
        jsr boomrel
        mov16 rx, sx
        mov16 ry, sy
        ldx #16
        jsr inrange
        bcc @draw
        lda fc
        cmp #4
        bcs @draw
        lda #5
        jsr addscore
        lda #4
        bit bvx+1
        bpl :+
        lda #5
:       sta fc
        stz fe
        lda #8
        sta bcnt
        lda #SFX_KILL
        sta SFXREQ
@draw:  ble16i fb, -128, @done
        lda fb                      ; B - A against 128, as @c4 (C = 1: ble16i fell through)
        sbc fa
        tax
        lda fb+1
        sbc fa+1
        eor #$80
        cpx #<128
        sbc #(>128 ^ $80)
:                                   ; placeholder - keeps the anonymous-label count
        bcs @done
        lda fc
        cmp #2
        and #1                      ; and leaves C from the cmp: both arms want fc & 1
        bcs @f6
        ldx fe                      ; fe is 0..11 whenever fc < 2; the 0..63 ladder @s23
        ora @ftab,x                 ; runs only while fc >= 2, and that takes @f6.  A is
        jmp m_addsprite             ; fc & 1: cmp/and/bcs/ldx leave it
@f6:    ora #46+6                   ; base is even, so ora == the old clc/adc
        jmp m_addsprite
@ftab:  .byte 46+0,46+0,46+0,46+2,46+2,46+2,46+4,46+4,46+4,46+2,46+2,46+2
@done:  rts
; carry set if anim counter is one of the pause frames 0,3,6,9
@pausef:
        lda fe
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
ob_rsnake:
        lda fb
        ora fb+1
        beq :+
        jmp @knocked
:
        ; A is a dormancy counter running -127..17 (CleoApp.run case 3: A++, and at 17
        ; A = -(rnd&63)-64) -- the same idiom as the spike, and a signed byte holds it.
        inc fa
        lda fa
        cmp #17
        bne @norst
        jsr m_rnd
        and #63
        eor #63
        clc
        adc #129                    ; 192-r: the byte form of -(r&63)-64
        sta fa
@norst: ; rise = (A*A >> 3) - 28 while the snake is up.
        ; NOTE: the reference skips when A <= -16 (CleoApp.run 2865: bipush -16,
        ; if_icmple), so it is up for A >= -15.  This port has always used A >= -16 -- one
        ; frame earlier.  Kept as it was, because a representation change should not carry
        ; a behaviour change: threshold 113 below instead of 112 matches the reference,
        ; and costs 18 frames of 300 on L7.
                                    ; A = fa on both ways in (lda fa / cmp #17, or sta fa)
        eor #$80                    ; bias the signed byte so the compare can be unsigned
        cmp #113                    ; -15 -> 113: at -16 the rise is +4 and the tall
        bcc @nowarm                 ; frame's tail shows 4 px under the basket; at -15
                                    ; it is 0 and the snake is flush with its bottom
@calc:  lda fa
        bpl :+
        eor #$FF
  .if MODELB
        adc #0                      ; C = 1: the cmp #113 fell through (inca is 6 bytes)
  .else
        inca
  .endif
:       jsr square                  ; returns A = t16, the low byte
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
        stz q6                      ; A is dead: boomready loads it
@boom:  jsr boomready
        bcc @hitp
        jsr boomrel
        mov16 rx, sx
        mov16 ry, sy
        ldx #20
        jsr inrange
        bcc @hitp
        lda #4
        jsr addscore
        ldx #1
        bgt16 ox, px, :+
        ldx #2
:       stx fb
        stz fb+1
        lda q6
        beq :+
        mov16 fc, rise
:       lda #8
        sta bcnt
        lda #SFX_KILL
        sta SFXREQ
@hitp:  dif16 rx, ox, px            ; the boomerang test above left rx boomerang-
        lda q6                      ; relative; on a miss it fell through here with
        beq @draw                   ; that x, so a boomerang passing the snake while
                                    ; Cleo stood at its height read as Cleo touching it
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
        ldx #24
        jsr inrange
        bcc @draw
        lda hurt
        bne @draw
        mov16 hx, rx
        jsr player_hit
@draw:  lda q6
        beq @basket
        ldx #54
        lda fa
        bmi @fr
        ldx #56
        cmp #0                      ; A still holds fa; ldx did not touch it
        beq @fr
        ldx #58
@fr:    stx q1
        bge16 px, ox, :+
        inc q1
:       mov16 spy, oy
        add16 spy, rise             ; snake Y = oy + parabola (was t16b: wrong)
        lda q1
        jsr m_addsprite
@basket:
        mov16 spx, ox
        mov16 spy, oy
        lda #60
        jmp m_addsprite
@knocked:
        bgt16i fc, -256, :+
        rts
:
        sub16i fc, 16
        lda fb
        cmp #1
        bne :+
        add16i fd, 16
        bra :++
:       sub16i fd, 16
:       ldx #55
        bgt16 ox, px, :+
        ldx #54
:       clc                         ; spy = oy + fc in one pass, the way the ox + fd
        lda oy                      ; code twelve lines below already does it
        adc fc
        sta spy
        lda oy+1
        adc fc+1
        sta spy+1
        txa                         ; the frame is still in X
        jsr m_addsprite
        clc
        lda ox
        adc fd
        sta spx
        lda ox+1
        adc fd+1
        sta spx+1
        mov16 spy, oy
        lda #60
        jmp m_addsprite


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
ob_bat:
        lda fe
        cmp #8
        bcc :+
        jmp @dead
:
        adc #1                      ; A = fe < 8 and C = 0 from the bcc:
        and #7                      ; fe = (fe + 1) & 7
        sta fe
:       ; rx += C>>1 ; ry += D>>1
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
        bpl16 rx, @rxpos
        bge16 fc, fa, @ydir
:       inc fc                      ; (label kept: the anonymous count is unchanged)
        bne @ydir
        inc fc+1
        bra @ydir
@rxpos: beq16 rx, @ydir
        beq16 fc, @ydir
        bmi16 fc, @ydir
        lda fc
        bne :+
        dec fc+1
:       dec fc
@ydir:  bpl16 ry, @rypos
        bge16 fd, fb, @boom
:       inc fd
        bne @boom
        inc fd+1
        bra @boom
@rypos: beq16 ry, @boom
        lda fd+1
        bmi @boom
        ora fd
        beq @boom
        lda fd
        bne :+
        dec fd+1
:       dec fd
@boom:  jsr boomready
        bcc @player
        mov16 t16, rx
        mov16 t16b, ry
        jsr boomrel
        mov16 rx, sx
        mov16 ry, sy
        ldx #28
        jsr inrange
        mov16 rx, t16               ; lda/sta do not touch carry
        mov16 ry, t16b
        bcc @player
        lda #8                      ; bcnt first: the kill does not read it
        sta bcnt
@kill:  lda #6
        jsr addscore
        mov16i fa, -640
        lda #8
        sta fe
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
        lda vy+1                    ; N from the high byte, exactly what bmi16's bit did
        bmi @nostomp
        ora vy                      ; then Z from vy|vy+1, exactly what beq16 built
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
@draw:  lda fe
        cmp #6                      ; C: fe >= 6 draws 65
        and #2                      ; else 61, or 63 for fe 2..3 (61 has bit 1 clear)
        ora #61
        bcc @fr
        lda #65
@fr:    sta q1
        bge16 px, spx, :++          ; spx > px: one frame on
:       inc q1
:       ; wobble: x += BAT_OFFSET[(frame + obj*5) & 15] ; y += BAT_OFFSET[((5*frame>>2) + obj*7) & 15]
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
        jmp m_addsprite
@dead:  ; falling
        ldx fb+1                    ; t16+1 = fb+1 + 1; the low byte is fb's own
        inx
        stx t16+1
        lda fd
        cmp fb
        lda fd+1
        sbc t16+1
        bvc :+
        eor #$80
:       bpl @done
:
        clc                         ; add16i fa, 120, keeping the new low byte in X
        lda fa
        adc #120
        sta fa
        tax
        lda fa+1
        adc #0
        sta fa+1                    ; want only the high byte of fa + 128:
        cpx #$80                    ; C = carry out of fa_lo + 128
        adc #0
        bpl :+                      ; fd += A sign-extended (N from the adc): pre-borrow
        dec fd+1                    ; the high byte when A is negative
:       clc
        adc fd
        sta fd
        bcc @fdok
        inc fd+1
@fdok:
        lda fc+1                    ; t16 = fc >> 1 (arith), folded into the add
        cmp #$80
        ror a
        tax                         ; the high half waits in X (dead: addsprite loads it)
        lda fc
        ror a
        clc
        adc spx
        sta spx
        txa
        adc spx+1
        sta spx+1
        lda fd+1                    ; same again for fd into spy
        cmp #$80
        ror a
        tax                         ; the high half waits in X, as above
        lda fd
        ror a
        clc
        adc spy
        sta spy
        txa
        adc spy+1
        sta spy+1
        bgt16 spx, px, :+
        lda #65
        bne :++                     ; always: Z = 0 from the lda #65
:       lda #66
:       jmp m_addsprite
@done:  rts
batoff: .byte 0,1,1,2,2,2,1,1,0,<-1,<-1,<-2,<-2,<-2,<-1,<-1

; ---------------------------------------------------------------- MASK (5) / MUMMY (6)
ob_walker:
        inc fe
        lda fe
        cmp #12
        bne :+
        stz fe                      ; A is dead: lda frame follows
:       lda frame
        and #1
        sta q1                      ; frame & 1: the step is q1 + 1, the + 1 the carry's
        lda fc
        bne @left
        lda fb                      ; walking right.  fb can be -1 coming in (the left
        sec                         ; path rests one past the near end), and the carry
        adc q1                      ; out of the add is what clears its sign byte -- drop
        sta fb                      ; that and -1 + 2 becomes -255, not 1.  (sec: the + 1)
        bcc :+
        inc fb+1
:       cmp fa                      ; past here fb+1 is 0 and fb is 0..194, so the
        bcc @coll                   ; unsigned compare says what the signed 16-bit did
        inc fc                      ; fc = 0 here (bne @left fell through): now 1
        bne @coll                   ; always
@left:  lda fb
        clc                         ; fb - q1 - 1: the step (C = 0 is the - 1)
        sbc q1
        sta fb
        beq @stop                   ; fb reached 0 (a borrow never leaves zero: >= 254)
        bcs @coll                   ; no borrow, not zero: still walking
        dec fb+1                    ; borrow == fb went negative: that IS the bmi16 test
@stop:  stz fc
@coll:  add16 rx, fb
        add16 spx, fb
        lda health
        beq @boom
        ldx #40
        jsr inrange
        bcc @boom
        lda hurt
        bne @boom
        mov16 hx, rx
        jsr player_hit
@boom:  jsr boomready
        bcc @draw
        jsr boomrel
        sta ry+1                    ; A = sy+1: boomrel's last store
        lda sy
        sta ry
        mov16 rx, sx
        ldx #44
        jsr inrange
        bcc @draw
        bit bvx+1
        bmi @bleft
        ; bvx > 0: if B < A: C = 0
        bge16 fb, fa, @bset
  .if ::MODELB
        lda #0                      ; (stz's own expansion, spelled out for its Z)
        sta fc
        beq @bset                   ; always
  .else
        stz fc
        bra @bset
  .endif
@bleft: ; bvx < 0: if B > 0: C = 1
        bmi16 fb, @bset
        lda fb
        beq @bset
        lda #1
        sta fc
@bset:  lda #8
        sta bcnt
@draw:  bmi16 fb, @f8               ; standing frame at either end.  Past the sign test
        lda fb                      ; fb+1 is 0, so the rest is an 8-bit compare
        beq @f8
        cmp fa
        bcs @f8
        ldx fe                      ; fe in X, so each arm can load its frame early
        cpx #3
        bcc @f0
        cpx #6
        bcc @f2
        cpx #9
        lda #4
        bcc @fr                     ; C = 0: fc + 4
        lda #5                      ; C = 1 (cpx #9 fell through): fc + 6
@fr:    adc fc
@sp:    ldx otype                   ; the frame stays in A: no round trip through q1
        cpx #6                      ; otype is 5 or 6 (the walker's two table entries)
        bne :+                      ; 5: C = 0 from the cpx
        adc #8                      ; 6: C = 1, so A + 9, and C = 0 again
:       adc #67
        jmp m_addsprite
@f0:    lda fc                      ; C = 0: the bcc
        bcc @sp
@f2:    lda #2                      ; C = 0: the bcc
        bcc @fr
@f8:    lda #8
        bne @sp

; ---------------------------------------------------------------- SPIKE (7)
ob_spike:
        ; A is a dormancy counter running -127..24 (CleoApp.run case 7: A++, and at 24
        ; A = -(rnd&63)-64).  That fits a signed byte exactly, so the byte IS the value
        ; and the high half was only ever its sign extension.
        inc fa
        lda fa
        cmp #24
        bne @nowrap
        jsr m_rnd
        and #63
        eor #63                     ; 63-r, then +129, is 192-r: the byte form of
        clc                         ; -(r&63)-64, i.e. -64 down to -127
        adc #129
        sta fa
@nowrap:
        ldx health                  ; A = fa on both ways in, and ldx keeps it
        beq @draw
        cmp #8                      ; unsigned: a dormant (negative) fa is >= 8 too
        bcs @draw
        ; rx > -8 && rx < (A+1)*2 && ry > -24 && ry < 8
        asl                         ; fa < 8 and C = 0 (bcs fell through): 2fa, C = 0
        adc #130                    ; (fa+1)*2 biased by $80
        sta RNGTAB+49
        ldx #48
        jsr inrange
        bcc @draw
        lda hurt
        bne @draw
        mov16 hx, rx
        jsr player_hit
@draw:  lda fa
        bmi @done
        cmp #8
        bcc :+
        eor #$FF                    ; A = fa (8..23), C = 1: 255-fa+23+1 = 23-fa, C = 1
        adc #23
        lsr
        clc                         ; only the lsr can leave C set; bcc arrives with C=0
:       adc #85
        jmp m_addsprite
@done:  rts

; ---------------------------------------------------------------- FLAME (9)
ob_flame:
        lda frame
        and #3
        bne :+
        inc fe
        lda fe
        and #3
        sta fe
:       lda fe
        clc
        adc #93
        jmp m_addsprite

; ---------------------------------------------------------------- POWERUP (10)
ob_powerup:
        lda fa
        bne @adv
        lda health
        beq @draw
        cmp #3
        bcs @draw
        ldx #52
        jsr inrange
        bcc @draw
        inc fa                      ; fa was 0: bne @adv fell through
        lda #3
        sta health
        jsr bar_touch
        lda #SFX_POWER
        sta SFXREQ
        bne @draw                   ; Z = 0: SFX_POWER is 6
@adv:   cmp #6
        bcs @done
        inc fa
@draw:  lda fa
        lsr
        cmp #3
        bcs @done
        adc #97
        jmp m_addsprite
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
  .if ::MODELB
        and #3                      ; bitimm's save and restore of A are not needed:
        bne @done                   ; A is reloaded
        lda fe
  .else
        bitimm 3
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
        ; tiles at (ox>>3, oy>>3) and +1 : codes from header per page
        mov16 qx, ox
        mov16 qy, oy
        jsr tilexy                  ; X = tile x, A = tile y
        sta q5                      ; tile y (q4/q5: gx/gy are the live grid-walk cursor)
        jsr maptile                 ; sets mapptr, Y = tx; X kept, bank 7 back
        ldx q1
        lda LV_HDR+8,x
        jsr mapput                  ; X and Y kept
        iny
        sty q4                      ; tile x + 1
        lda LV_HDR+9,x
        jsr mapput
        dey
        tya                         ; tile x
        ldx q5
        jsr m_mark_dirty
        lda q4
        ldx q5
        jsr m_mark_dirty
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
        jsr m_mark_dirty
  .if MODELB
        ldx fa                      ; inca is 6 bytes here
        inx
        txa
  .else
        lda fa
        inca
  .endif
        ldx q5
        jsr m_mark_dirty
        inc q5
        dec q4
        bne @rl
@set:   inc fd                      ; fd = 0 here (bne @draw fell through): now 1
@draw:  lda fd
        clc
        adc #100
        jmp m_addsprite

; ============================================================================
; Status bar digits (drawn into the bar master image in bank 4)  [main RAM]
; ============================================================================
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with the digits and the bar art
; draw digit A at bar pixel column X (even), digit slot Y (0..8): copies a 64-byte digit
; tile into the bar image.
;
; Each buffer remembers the nine values its bar was last drawn with, because redraw_hud
; redraws all nine whenever anything changes and a score tick usually moves only one of
; them -- the other eight were 128 bytes of copy for no pixels (measured 5.0K cycles a
; render on an L0 run, 3.2% of the frame).  The bank is BANK_LVL on entry and on exit, so
; the skip path must not touch it.
draw_health:                        ; falls into bar_digit
        lda health
        ldx #46
        ldy #1
bar_digit:
        cmp BARCACHE,y              ; one bar, so one cache: no curbuf in the index
        beq bd_same
        sta BARCACHE,y
        lsr                         ; C = d bit0, A = d >> 1
        sta w16+1
  .if .not MODELB
        setbank HUD_BANK            ; (lda #/sta/sta: C survives)
  .endif
        lda #0
        sta ptr+1                   ; for the x * 4 below (sta keeps C)
        ror                         ; A = d0 << 7
        lsr w16+1                   ; C = d bit1, w16+1 = d >> 2
        ror                         ; A = d1 << 7 | d0 << 6; C = 0 (A bit 0 was 0)
        adc #<SPR_DIGITS
        sta w16
        lda w16+1
        adc #>SPR_DIGITS
        sta w16+1                   ; digit tile
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
        ldy #31
:       lda (w16),y
        sta (ptr),y
        dey
        bpl :-
        lda w16
        adc #32                     ; C still clear: ptr+1 <= 3 and >BARADDR = $7B, so the
        sta w16                     ; adc above cannot carry, and the copy loop leaves C
        bcc @nc
        inc w16+1
@nc:    add16i ptr, 640
        ldy #31
:       lda (w16),y
        sta (ptr),y
        dey
        bpl :-
  .if .not MODELB
        setbank BANK_LVL, BANK_LVL
  .endif
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
; t16 = t16 / 10 ; q1 = remainder
div10_16:
        lda #0                      ; remainder lives in A for the whole loop
        ldy #16                     ; Y, not X: draw_score keeps its slot in X
@l:     asl t16
        rol t16+1
        rol a                       ; was rol q1 / lda q1
        cmp #10
        bcc :+
        sbc #10                     ; was sbc #10 / sta q1
        inc t16
:       dey
        bne @l
        sta q1
        rts

        PLACE "LOGIC", "LGCCODE"
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
