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
        lda dst+1
        adc #>(imm)
        sta dst+1
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
        lda dst+1
        sbc #>(imm)
        sta dst+1
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
        lda #<(imm)
        cmp var
        lda #>(imm)
        sbc var+1
        bvc :+
        eor #$80
:      bmi label
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
OBJN    = 149
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
LV_MAPROWLO = $A900               ; bank 6: 256 : tile row -> map row address
LV_MAPROWHI = $AA00

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

        .segment "LOGIC"

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
        asl
        asl
        asl
        asl
        asl
        sta q2
        lda qx
        lsr
        lsr
        lsr
        ora q2
        tax
        lda qy+1
        cmp maph+1
        bcs @out
        asl
        asl
        asl
        asl
        asl
        sta q2
        lda qy
        lsr
        lsr
        lsr
        ora q2
        sec
        rts
@out:   clc
        rts

; getinfo: A = alt byte for pixel (qx, qy), 8 if outside the map
getinfo:
        jsr tilexy                  ; X = qx>>3, A = qy>>3
        bcs :+
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
        sta q2
        lda qx
        and #7
        ora q2
        tay
        lda LV_ALTTAB,y
        rts

; getaltitude: A = altitude (signed) at pixel (qx, qy)  [qy modified]
getaltitude:
        jsr getinfo
        sta q3                      ; n3
        lsr
        lsr
        lsr
        lsr
        sta q4                      ; n4
        lda qy
        and #7
        sta q5                      ; n5
        lda q3
        and #15
        cmp q5
        beq @below
        bcs @notbelow
@below: lda qy
        clc
        adc #8
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
        lda q4
        bne @d2
        lda qy
        sec
        sbc #8
        sta qy
        bcs :+
        dec qy+1
:       jsr getinfo
        sta q3
        and #15
        cmp #8
        bne @done
        lda q3
        lsr
        lsr
        lsr
        lsr
        sbc #8
        sta q4
@done:  lda q4
@d2:    sec
        sbc q5
        rts

; gettileattr: A = attribute byte for the tile at (qx,qy): bits0-2 push+3, bit7 kill ; 3 if outside
gettileattr:
        jsr tilexy                  ; X = qx>>3, A = qy>>3
        bcs :+
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
        jsr init_maprows            ; main RAM: the row tables live with the map
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
        ; clear object state, then grid
        stz BINOK                   ; the cached object list belongs to the old level
        ldx #0
        lda #0
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
        ldx #127
        lda #$FF
:       sta LV_GRID,x
        dex
        bpl :-
        stza stars
        stza bent
        ; objects, last to first
        ldy nobj
        bne :+
        jmp @objdone
:
@ol:    dey
        sty obj
        ; entry pointer = LV_OBJS + obj*6
        tya
        asl
        sta t16
        lda #0
        rol
        sta t16+1
        lda t16
        asl
        sta t16b
        lda t16+1
        rol
        sta t16b+1
        clc
        lda t16
        adc t16b
        sta t16
        lda t16+1                   ; <LV_OBJS = 0: only the high byte moves
        adc t16b+1
        adc #>LV_OBJS               ; the high-byte add cannot carry: t16+1 <= 1, t16b+1 <= 3
        sta t16+1
        ldaz t16                    ; lda (t16)
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
        deca
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
        inca
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
        deca
:       lsr
        lsr
        lsr
        sta gy
        jmp @box
@t1:    lda O_XL,y
        clc
        adc #4
        sta O_XL,y
        bcc :+
        lda O_XH,y
        inca
        sta O_XH,y
:       lda q1
        submin0 2
        lsr
        lsr
        lsr
        sta gx0
        lda q1
        inca
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
        lda q3
        lsr
        lsr
        lsr
        lsr
        sta O_AH,y
        lda q4
        asl
        asl
        asl
        asl
        sta O_BL,y
        lda q4
        lsr
        lsr
        lsr
        lsr
        sta O_BH,y
        ; C = rnd % (A+1) ; D = rnd % (B+1)  (A,B < 4096) -> use rnd16 & mask then reduce
        jsr m_rnd
        sta t16
        jsr m_rnd
        and #$0F
        sta t16+1
        clc
        lda O_AL,y
        adc #1
        sta t16b
        lda O_AH,y
        adc #0
        sta t16b+1
        jsr mod16
        lda t16
        sta O_CL,y
        lda t16+1
        sta O_CH,y
        jsr m_rnd
        sta t16
        jsr m_rnd
        and #$0F
        sta t16+1
        clc
        lda O_BL,y
        adc #1
        sta t16b
        lda O_BH,y
        adc #0
        sta t16b+1
:                                   ; placeholder - keeps the anonymous-label count
        jsr mod16
        lda t16
        sta O_DL,y
        lda t16+1
        sta O_DH,y
        lda q2
        beq :+                      ; submin0 1 specialised: max(q2-1, 0)
        dec a
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
        bra @box
@t9:    lda q2
        submin0 2
        lsr
        lsr
        lsr
        sta gy
        lda q2
        lsr
        lsr
        lsr
        sta gy1
        bra @box
@t11:   lda gy
        sta gy1
        bra @box
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
        lda gx0
        sta gx
@bx:    ; cell = gx + (gy << gridsh), built once per grid row: the gx loop below
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
        bra @cell
:       inc gy
        lda gy1                     ; C clear <=> gy1 < gy <=> gy > gy1
        cmp gy
        bcc @nextobj
:       lda gx0                     ; KEPT: this ':' now has no reference, but removing
        sta gx                      ; the line would retarget the anonymous labels
        bra @bx
@nextobj:
        ldy obj
        beq @objdone
        jmp @ol
@objdone:
        ; player state
        mov16 px, startx
        mov16 py, starty
        stz vx
        stz vx+1
        stz vy
        stz vy+1
        stz anim
        mov16 evframe, frame
        stz facing
        stz running
        stz firing
        lda #1
        sta hurt
        sta control
        stza bactive
        stza pausing
        stza exiting
        stza frame
        stza frame+1
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
        bra :-
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
        bra mod16
:       rts

; ============================================================================
; Per frame update.  Fills the sprite list; sets wx/wy.
; ============================================================================
game_frame:
        inc frame
        bne :+
        inc frame+1
:       stza bounce
        ; ---- camera
        lda health
        beq @cam
        lda px
        sec
        sbc #80
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
        setbank BANK_LVL
        ; ---- bucket range (16-bit >> 6)
        lda wx+1                    ; shr6 inlined: the t16 staging and the jsr/rts
        asl                         ; were most of its cost, and wx/wy can be read
        asl                         ; directly (t16 < 16384 still holds)
        sta t16+1
        lda wx
        rol
        rol
        rol
        and #3
        ora t16+1
        sta gx0
        lda wx
        clc
        adc #159
        sta t16
        lda wx+1
        adc #0
        asl
        asl
        sta t16+1
        lda t16
        rol
        rol
        rol
        and #3
        ora t16+1
        sta gx1
        lda wy+1
        asl
        asl
        sta t16+1
        lda wy
        rol
        rol
        rol
        and #3
        ora t16+1
        sta gy
        lda wy
        clc
        adc #VISLINES/2-1
        sta t16
        lda wy+1
        adc #0
        asl
        asl
        sta t16+1
        lda t16
        rol
        rol
        rol
        and #3
        ora t16+1
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
        stz NSTARL
        stz NOTHL
        lda #1
        sta BINOK
@rows:  lda gx0
        sta gx
        lda gy                      ; row base = gy << gridsh, once per row
        ldx gridsh
        beq :++
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
        bra @skip
@apo:   ldx NOTHL
        cpx #BINMAX
        bcs @full
        tya
        sta LV_BINOTH,x
        inc NOTHL
        bra @skip
@full:  stz BINOK                   ; more objects than a list holds: process this one
        sty obj                     ; now and rebuild next step rather than lose it
        jsr process_object
        setbank BANK_LVL
@skip:  ldx bent
@sk2:   lda LV_BNEXT,x
        bra @walk
@cellend:
        lda gx
        cmp gx1
        beq :+
        inc gx
        bra @cells
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
        bra @rls
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
        bra @rl2
@rldone:
        ; ---- after objects
        lda bounce
        beq :+
        stz vy
        lda #>(-1280)
        sta vy+1
:       ; kill tile under player
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
        lda facing
        beq :+
        lda #$FF
:       sta hx+1                    ; facing left -> hx negative -> vx = +768
        jsr player_hit
@nokill:
        lda health
        bne @alive
        jmp player_dead
@alive: jmp player_update

; A = t16 >> 6 (t16 < 16384)
shr6:   lda t16+1                   ; t16 < 16384: result = (hi<<2) | (lo>>6)
        asl
        asl
        sta t16+1
        lda t16
        rol                         ; three ROLs bring bits 7,6 down to bits 1,0
        rol
        rol
        and #3
        ora t16+1
        rts

; ============================================================================
; player_hit: knock back. hx = relative x of the enemy (sign used)
; ============================================================================
player_hit:
        mov16 evframe, frame
        dec health
        jsr bar_touch
        lda #1
        sta hurt
        stz control
        stz vx
        stz vx+1
        lda health
        beq :+
        lda #>768                   ; vx low is already 0 from the stz above, and both
        sta vx+1                    ; knockback speeds have a zero low byte
        bit hx+1
        bmi :+
        lda #>(-768)                ; -768 is $FD00: the HIGH byte is the non-zero one
        sta vx+1
:       stz vy                      ; -1280 = $FB00: the low byte is zero
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
        sta t16
        lda frame+1
        sbc evframe+1
        bne @respawn
        lda t16
        cmp #61
        bcc @draw
@respawn:
        mov16 px, startx
        mov16 py, starty
        stz vx
        stz vx+1
        stz vy
        stz vy+1
        stz anim
        mov16 evframe, frame
        lda #3
        sta health
        dec lives
        bne :+
        lda #1
        sta exiting                 ; game over handled by caller (lives == 0)
        rts
:       stz facing
        stz running
        stz firing
        lda #1
        sta hurt
        sta control
        jsr bar_touch
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
        sta t16+1
        add16 vy, t16
        rts

; dpx = (vy + 128) >> 8 (signed)
vy_step:
        mov16 dpx, vy
        add16i dpx, 128             ; leaves the high byte in A
        sta dpx
        and #$80
        beq :+
        lda #$FF
:       sta dpx+1
        bmi @up                     ; A already holds dpx+1, with matching N/Z
        bne @cdn                    ; >= 256
        lda dpx
        cmp #MAXDWY+1
        bcc @cdone
@cdn:   lda #MAXDWY
        sta dpx
        stz dpx+1
        rts
@up:    lda dpx                     ; dpx+1 is $FF on this arm, so neither the
        cmp #<-MAXDWY               ; <= -256 test nor the clamp's rewrite of the
        bcs @cdone                  ; high byte can do anything
@cup:   lda #<-MAXDWY
        sta dpx
@cdone: rts

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
        stz anim
        lda #1
        sta firing
@nothrow:
        ; vertical velocity
        bmi16 vy, @grav
        lda alt
        beq :+
        bpl @grav
:       lda firing
        bne @stand
        lda control
        beq @stand
        lda keys
        and #(K_UP|K_FIRE)
        beq @stand
        stz vy                      ; -1280 = $FB00: the low byte is zero
        lda #>(-1280)
        sta vy+1
        lda #SFX_JUMP
        sta SFXREQ
        bra @move
@stand: lda #1
        sta control
        stza vy
        stza vy+1
        bra @move
@grav:  jsr gravity
@move:  jsr vy_step
        bmi16 dpx, @up
        ; down: dy = min(dy, alt)
        lda alt
        cmp dpx
        bcs :+
        sta dpx
        stz dpx+1
:       sec
        sbc dpx
        sta alt
        add16 py, dpx
        bra @vdone
@up:    add16 py, dpx
@upl:   mov16 qx, px
        clc
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
        bra @upl
@vdone:
        sec
        lda maph
        sbc #24
        sta t16
        lda maph+1
        sbc #0
        sta t16+1
        bge16 t16, py, @push
@fell:  mov16 evframe, frame
        stza health
        jsr bar_touch
        stz control
        stz vx
        stz vx+1
        lda #SFX_DIE
        sta SFXREQ
@push:  mov16 qx, px
        clc                         ; qy = py + 16 in one pass
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
        lda control
        bne :+
        jmp @nofric
:
        lda alt
        beq :+
        bmi :+
        jmp @air
:
:       lda q6
        cmp #3
        bne :+
        jmp @air
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
        sta t16
        tya
        adc vx+1
        sta t16+1                   ; t16 = 3vx
        neg16 t16                   ; leaves A = t16+1
:                                   ; placeholder - keeps the anonymous-label count
        cmp #$80                    ; asr16 x6, high byte held in A
        ror
        ror t16
        cmp #$80
        ror
        ror t16
        cmp #$80
        ror
        ror t16
        cmp #$80
        ror
        ror t16
        cmp #$80
        ror
        ror t16
        cmp #$80
        ror
        ror t16
        sta t16+1
        add16 vx, t16
        ; * 24: |24*q6| <= 96, so it fits in 8 bits and needs one sign extension
        lda q6
        asl
        asl
        asl
        sta t16                     ; 8p
        asl                         ; 16p
        clc
        adc t16                     ; 24p
        sx16 t16
        add16 vx, t16
        bra @nofric
@air:   ; vx = vx*5>>3 : vx + asr3(-3vx) == asr3(5vx), and 5vx still fits 16 bits
        lda vx
        asl
        sta t16
        lda vx+1
        rol
        sta t16+1                   ; t16 = 2vx
        asl t16
        rol t16+1                   ; t16 = 4vx
        clc
        lda t16
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
        stz anim
:       ; accel = (alt > 0 || push == 3) ? 288 : 36
        lda alt
        beq :+
        bpl @acc288
:       lda q6
        cmp #3
        beq @acc288
        lda #36
        sta t16
        stza t16+1                  ; was lda #0 / sta t16+1
        bra @acc
@acc288:
        mov16i t16, 288
@acc:   txa
        and #K_LEFT
        beq @right
        sub16 vx, t16
        lda #1
        sta facing
        bra @run
@right: add16 vx, t16
        stz facing
@run:   lda #1
        sta running
        bra @hmove
@norun: stza running
@hmove:
        ; steps = (vx + 128) >> 8 ; dir = sign
        lda vx
        cmp #$80                    ; C = carry out of vx_lo + 128, without the clc
        lda vx+1
        adc #0                      ; A = high byte of vx + 128
        sta dpx
        bne :+
        stz dpx+1                   ; dpx = 0, so its sign extension is 0 too
        jmp @hdone
:       and #$80
        beq :+
        lda #$FF
:       sta dpx+1
        bra @hstep                  ; qx = px and qy = py+16 already, set at @push
@hl:    mov16 qx, px
        clc
        lda py
        adc #16
        sta qy
        lda py+1
        adc #0
        sta qy+1
        lda dpx+1
@hstep: bmi @hneg
        inc qx
        bne @hget
        inc qx+1
        bra @hget
@hneg:  lda qx
        bne :+
        dec qx+1
:       dec qx
@hget:  jsr getaltitude
        sta q1
        bpl @hok
        cmp #$FF
        bne @wall
@hok:   ; px += dir
        lda dpx+1
        bmi @hdn
        inc px
        bne @hmoved
        inc px+1
        bra @hmoved
@hdn:   lda px
        bne :+
        dec px+1
:       dec px
@hmoved:
        ; if a <= 1: py += a ; alt = 0 else alt = a   (a may be -1: step up a slope)
        lda q1
        bmi @stepn
        cmp #2
        bcs @alt
        adc py                      ; C is clear from the cmp: 0 or 1, addend high byte 0
        sta py
        bcc :+
        inc py+1
:       stza alt
        bra @hnext
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
        bra :++
:       inc dpx
:       beq @hdone      ; Z survives from the inc/dec
        jmp @hl
@wall:  stz vx
        stz vx+1
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
        stz bvx
        lda #>3584
        sta bvx+1
        lda facing
        beq @bdir
        lda #>(-3584)
        sta bvx+1
@bdir:  stz bvy
        stz bvy+1
        stz bcnt
        lda #1
        sta bactive
        lda #SFX_THROW
        sta SFXREQ
        bra @animdone
:       cmp #12
        bne @animdone
        stza firing
        bra @animdone
@notfiring:
        lda running
        beq :+
        lda anim
        cmp #16
        bne @animdone
        stza anim
        bra @animdone
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
        bra @setctl
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
        lda #1
        sta control
        bra @ctl
@noctl:
        lda #22
        ldx vx+1
        bmi @spr2
        ldx vx
        beq @spr2
        lda #23
@spr2:  jmp @spr
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
        bra @sprf
@f14:   lda #14
        bra @sprf
@f18:   lda #18
        bra @sprf
@nofire:
        bmi16 vy, @jump
        lda alt
        beq @ground
        bpl @jump
@ground:
        lda running
        beq @standing
        lda anim
        lsr
        and #$FE                    ; (anim >> 2) << 1 with one shift, not three
        bra @sprf
@standing:
        lda anim
        cmp #93
        bcc @s8
        cmp #109
        bcc @s10
        cmp #113
        bcc @s12
@s10:   lda #10
        bra @sprf
@s8:    lda #8
        bra @sprf
@s12:   lda #12
        bra @sprf
@jump:  ble16i vy, -384, @j20
        bge16i vy, 384, @j24
        lda #22
        bra @sprf
@j20:   lda #20
        bra @sprf
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
        ble16i rx, -8, @nocatch
        bge16i rx, 8, @nocatch
        ble16i ry, -8, @nocatch
        bge16i ry, 8, @nocatch
        stz bactive
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
        sbc bvx+1
        sta t16+1
        asl16 t16                   ; t16 = -2*bvx
        sec
        lda t16
        sbc bvx
        sta t16
        lda t16+1
        sbc bvx+1                   ; A = high byte of -3*bvx (t16+1 store is dead)
        ldx #6
:       cmp #$80
        ror
        ror t16
        dex
        bne :-
        sta t16+1
        add16 bvx, t16
        asl16 rx
        add16 bvx, rx
        lda bvx
        cmp #$80                    ; C = bit 7 of bvx = carry out of (bvx + 128)
        lda bvx+1
        adc #0                      ; A = high byte of bvx + 128
        sx16 t16
        add16 bx, t16
        sec                         ; t16 = -bvy, same shape as the bvx block above
        lda #0
        sbc bvy
        sta t16
        lda #0
        sbc bvy+1
        sta t16+1
        asl16 t16                   ; t16 = -2*bvy
        sec
        lda t16
        sbc bvy
        sta t16
        lda t16+1
        sbc bvy+1                   ; A = high byte of -3*bvy (t16+1 store is dead)
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
        cmp #128
        lda bvy+1
        adc #0
        ldx #0                      ; sign-extend the delta into X and add it straight
        cmp #$80                    ; to by, instead of staging it through t16
        bcc :+
        dex
:       clc
        adc by
        sta by
        txa
        adc by+1
        sta by+1
        mov16 qx, bx
        mov16 qy, by
        jsr getaltitude
        bpl @bfly
        lda #8
        sta bcnt
@bfly:  inc bcnt
        lda bcnt
        cmp #8
        bne :+
        stza bcnt
:       cmp #14
        bne :+
        stza bactive
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
        sta t16                     ; and low byte under the width
        lda px+1
        sbc exitx+1
        bne @noexit
        lda t16
        cmp #16
        bcs @noexit
        lda py
        sec
        sbc exity
        sta t16
        lda py+1
        sbc exity+1
        bne @noexit
        lda t16
        cmp #24
        bcs @noexit
        lda #1
        sta exiting
@noexit:
        rts


; ============================================================================
; Object processing.  Y = object index (obj).  Loads fields into zp, dispatches, stores back.
; ============================================================================
process_object:
        lda O_TYPE,y
        sta otype
        cmp #NLEAN                  ; types below NLEAN read and write the arrays in
        bcs @gen                    ; place; the rest are still staged through zero page
        jmp @lean
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
        lda otype
        asl
        tax
        jsr @call
        ; store back
        setbank BANK_LVL
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
        lda otype
        asl
        tax
@call:  jmpx @tab                   ; tail dispatch: the handler returns to our caller
        ; (@call is the jsr entry for the staged path)
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
        lda rx+1
        inca                         ; $FF -> 0, 0 -> 1, anything else >= 2
        cmp #2
        bcs @no
        lda rx
        eor rx+1                    ; low byte sign must agree with the high byte
        bmi @no
        lda rx
        eor #$80
        cmp RNGTAB,x
        bcc @no
        beq @no                     ; rx > lo
        cmp RNGTAB+1,x
        bcs @no                     ; rx < hi
        lda ry+1
        inca
        cmp #2
        bcs @no
        lda ry
        eor ry+1
        bmi @no
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
        ; Guard bands: not "close enough to collect" but "the drawn rectangles touch".
        .byte 105, 147, 113, 152        ; 32: Cleo      <-23, 19, <-15, 24
        .byte 111, 144, 118, 143        ; 36: boomerang <-17, 16, <-10, 15
        .byte 112, 144, 116, 144        ; 32: <-16, 16, <-12, 16
        .byte 116, 140, 0, 255          ; 36: <-12, 12, <-128, 127
        .byte 112, 144, 104, 148        ; 40: <-16, 16, <-24, 20
        .byte 118, 138, 112, 136        ; 44: <-10, 10, <-16, 8
        .byte 120, 128, 104, 136        ; 48: <-8, 0, <-24, 8
        .byte 112, 144, 104, 140        ; 52: <-16, 16, <-24, 12
        .byte 112, 129, 143, 145        ; 56: <-16, 1, 15, 17
        .byte 112, 144, 104, 140        ; 60: <-16, 16, <-24, 12
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
        lda bcnt
        cmp #8
        bcs @no
        sec
        rts
@no:    clc
        rts
addscore:                           ; A = points
        clc
        adc score
        sta score
        bcc :+
        inc score+1
:       jmp bar_touch

; ---------------------------------------------------------------- STAR (0)
ob_star:
        lda frame
        and #1
        bne @nostep
        lda O_AL,y
        cmp #18                     ; cap: a collected star's A must not wrap 8-bit
        bcs @nostep                 ; (it would make the star reappear ~every 20s).
        inc a                       ; A still holds it: there is no inc abs,y
        sta O_AL,y
@nostep:
        lda O_AL,y
        cmp #12
        bne :+
        lda O_CL,y
        bne :+
        lda #0                      ; (no stz abs,y either)
        sta O_AL,y
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
        jsr bar_touch
        lda #1
        jsr addscore
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
        sta q1
        jsr star_safe
        lda q1
        jmp m_addsprite
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
; are drawn under an alias id BOXN above the real one.
star_safe:
        lda O_EH,y
        bne @no
        ldx #32
        jsr inrange
        bcs @no
        lda bactive
        beq @yes
        jsr boomrel
        mov16 rx, sx
        mov16 ry, sy
        ldx #36
        jsr inrange
        bcs @no
@yes:   lda q1                      ; both ways in are a bcs that was not taken,
        adc #BOXN                   ; so the carry is already clear
        sta q1
@no:    rts

; The trampoline box is opaque the same way; nothing may draw through it if it is to be
; left alone.  rx/ry are still Cleo-relative here (ob_tramp does not call boomrel).
tramp_safe:
        lda O_EH,y                    ; an enemy's range covers it
        bne @no
        ldx #72
        jsr inrange                 ; Cleo overlaps its rectangle
        bcs @no
        lda bactive
        beq @yes
        jsr boomrel
        mov16 rx, sx
        mov16 ry, sy
        ldx #76
        jsr inrange                 ; the boomerang overlaps it
        bcs @no
@yes:   lda q1                      ; both ways in fall through a 'bcs @no' that was not
        adc #BOXN                   ; taken, so C is already clear here
        sta q1
@no:    rts

; ---------------------------------------------------------------- TRAMPOLINE (1)
ob_tramp:
        lda O_AL,y
        beq :+
        inc a                       ; there is no inc abs,y, and A holds it anyway --
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
        beq @reg
        adc #115
        sta q1
        jsr tramp_safe
        lda q1
        jmp m_addsprite
@reg:   adc #43
        jmp m_addsprite

; ---------------------------------------------------------------- GREEN SNAKE (2)
ob_snake:
        lda fc
        cmp #2
        bcs @s23
        inc fe
        lda fe
        cmp #12
        bne @st
        stza fe
        bra @st
@s23:   inc fe
        lda fe
        cmp #64
        bne @st
        lda fc
        and #1
        sta fc
        stz fe
@st:    lda fc
        beq @c0
        cmp #1
        beq @c1
        cmp #4
        beq @c4
        cmp #5
        beq @c5
        jmp @coll
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
        lda #1
        sta fc
        bra @coll
@c1:    jsr @pausef
        bcs @coll
        lda fb
        bne :+
        dec fb+1
:       dec fb
        bne @coll
        lda fb+1
        bne @coll
        stza fc
        bra @coll
@c4:    ; if B < A + 128: B += 16
        sec                         ; B - A against the immediate 128, the way @c5
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
        add16i fb, 16
        bra @coll
@c5:    ble16i fb, -128, @coll
        sub16i fb, 16
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
        lda ry+1
        bmi @nostomp
        ora ry
        beq @nostomp
        lda vy+1
        bmi @nostomp
        ora vy
        beq @nostomp
        ; stomped
        lda fc
        cmp #2
        bcc :+
        lda #5
        jsr addscore
:       inc fc
        inc fc
        stz fe
        lda #1
        sta bounce
        lda #SFX_KILL
        sta SFXREQ
        bra @boom
@nostomp:
        lda fc
        cmp #2
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
        clc
        lda fa
        adc #128
        sta t16
        lda fa+1
        adc #0
        sta t16+1
        bge16 fb, t16, @done
        lda fc
        cmp #2
        bcs @f6
        ldx fe                      ; fe is 0..11 whenever fc < 2; the 0..63 ladder @s23
        and #1                      ; runs only while fc >= 2, and that takes @f6.  A is
        ora @ftab,x                 ; still fc: cmp/bcs/ldx do not touch it
        jmp m_addsprite
@f6:    and #1                      ; base is even, so ora == the old clc/adc
        ora #46+6
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
        lda fa
        eor #$80                    ; bias the signed byte so the compare can be unsigned
        cmp #112                    ; -16 -> 112
        bcc @nowarm
@calc:  lda fa
        bpl :+
        eor #$FF
        inca
:       jsr square
        lsr t16+1
        ror t16
        lsr t16+1
        ror t16
        lsr t16+1
        ror t16
        sec
        lda t16
        sbc #28
        sta t16
        sta rise
        lda t16+1
        sbc #0
        sta t16+1
        sta rise+1
        lda #1
        sta q6                      ; snake visible
        bra @boom
@nowarm:
        stza q6
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
        dif16 rx, ox, px
@hitp:  lda q6
        beq @draw
        lda health
        beq @draw
        clc                         ; ry = oy + rise, in one pass
        lda oy
        adc rise
        sta ry
        lda oy+1
        adc rise+1
        sta ry+1
        sub16 ry, py
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
        jmp @done
:
        sub16i fc, 16
        lda fb
        cmp #1
        bne :+
        add16i fd, 16
        bra :++
:       sub16i fd, 16
:       ldx #54
        bgt16 ox, px, :+
        bra :++
:       ldx #55
:       stx q1
        clc                         ; spy = oy + fc in one pass, the way the ox + fd
        lda oy                      ; code twelve lines below already does it
        adc fc
        sta spy
        lda oy+1
        adc fc+1
        sta spy+1
        lda q1
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
@done:  rts

; t16 = A * A (A unsigned 0..128)
square: sta q1
        sta q1x
        lda #0                      ; accumulator low byte lives in A
        stza t16+1                  ; stz never touches A on a 65C02
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
        inc fe
        lda fe
        cmp #8
        bne :+
        stza fe
:       ; rx += C>>1 ; ry += D>>1
        mov16 t16, fc
        asr16 t16
        add16 rx, t16
        add16 spx, t16
        mov16 t16, fd
        asr16 t16
        add16 ry, t16
        add16 spy, t16
        ; chase
        bpl16 rx, @rxpos
        blt16 fc, fa, :+
        bra @ydir
:       inc fc
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
        blt16 fd, fb, :+
        bra @boom
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
        jsr @kill
        lda #8
        sta bcnt
        bra @draw
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
        jsr @kill
        lda #1
        sta bounce
        bra @draw
@nostomp:
        lda hurt
        bne @draw
        ldx #36
        jsr inrange
        bcc @draw
        mov16 hx, rx
        jsr player_hit
@draw:  lda fe
        cmp #2
        bcc @f0
        cmp #4
        bcc @f2
        cmp #6
        bcc @f0
        lda #65
        bra @fr
@f0:    lda #61
        bra @fr
@f2:    lda #63
@fr:    sta q1
        bgt16 spx, px, :+
        bra :++
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
        asl
        sec
        sbc obj
        clc
        adc t16
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
@kill:  lda #6
        jsr addscore
        mov16i fa, -640
        lda #8
        sta fe
        lda #SFX_KILL
        sta SFXREQ
        rts
@dead:  ; falling
        lda fb                      ; t16 = fb + 256: only the high byte changes
        sta t16
        lda fb+1
        inca
        sta t16+1
        blt16 fd, t16, :+
        jmp @done
:
        add16i fa, 120
        lda fa                      ; want only the high byte of fa + 128
        cmp #$80                    ; C = carry out of fa_lo + 128
        lda fa+1
        adc #0
        sx16 t16
        add16 fd, t16
        lda fc+1                    ; t16 = fc >> 1 (arith), folded into the add
        cmp #$80
        ror a
        sta t16+1
        lda fc
        ror a
        clc
        adc spx
        sta spx
        lda spx+1
        adc t16+1
        sta spx+1
        lda fd+1                    ; same again for fd into spy
        cmp #$80
        ror a
        sta t16+1
        lda fd
        ror a
        clc
        adc spy
        sta spy
        lda spy+1
        adc t16+1
        sta spy+1
        bgt16 spx, px, :+
        lda #65
        bra :++
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
        stza fe
:       lda frame
        and #1
        inca
        sta q1                      ; step 1 or 2
        lda fc
        bne @left
        lda fb                      ; walking right.  fb can be -1 coming in (the left
        clc                         ; path rests one past the near end), and the carry
        adc q1                      ; out of the add is what clears its sign byte -- drop
        sta fb                      ; that and -1 + 2 becomes -255, not 1.
        bcc :+
        inc fb+1
:       cmp fa                      ; past here fb+1 is 0 and fb is 0..194, so the
        bcc @coll                   ; unsigned compare says what the signed 16-bit did
        lda #1
        sta fc
        bra @coll
@left:  lda fb
        sec
        sbc q1
        sta fb
        bcs :+                      ; borrow == fb went negative: that IS the bmi16 test
        dec fb+1
        bra @stop
:       bne @coll                   ; Z still from the sbc, so fb's own load is not needed
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
        mov16 rx, sx
        mov16 ry, sy
        ldx #44
        jsr inrange
        bcc @draw
        bit bvx+1
        bmi @bleft
        ; bvx > 0: if B < A: C = 0
        blt16 fb, fa, :+
        bra @bset
:       stz fc
        bra @bset
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
        lda fe
        cmp #3
        bcc @f0
        cmp #6
        bcc @f2
        cmp #9
        bcc @f4
        lda #6
        clc                         ; only this arm reaches @fr with C set (cmp #9
        bra @fr                     ; fell through); @f2 and @f4 got here on a bcc
@f0:    lda fc
        bra @sp
@f2:    lda #2
        bra @fr
@f8:    lda #8
        bra @sp
@f4:    lda #4
@fr:    adc fc
@sp:    ldx otype                   ; the frame stays in A: no round trip through q1
        cpx #5
        bne :+
        adc #66                     ; C = 1 from the equal cpx, so this is A + 67
        bra :++
:       clc
        adc #76
:       jmp m_addsprite

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
        lda health
        beq @draw
        lda fa
        bmi @draw                   ; still dormant
        cmp #8
        bcs @draw
        ; rx > -8 && rx < (A+1)*2 && ry > -24 && ry < 8
        inca                        ; A is still fa: cmp does not write A
        asl
        eor #$80                    ; biased limit
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
        lda #23
        sec
        sbc fa
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
        lda #1
        sta fa
        lda #3
        sta health
        jsr bar_touch
        lda #SFX_POWER
        sta SFXREQ
        bra @draw
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
        lda #1
        sta fe
@ret:   rts
@count: inc fe
        lda fe
        bit #3
        bne @done
        cmp #12
        bcs :+
        lsr
        bra @set
:       cmp #37
        bcc @six
        lda #48
        sbc fe                      ; carry is already set: bcc fell through
        lsr
        bra @set
@six:   lda #6
@set:   sta q1
        ; tiles at (ox>>3, oy>>3) and +1 : codes from header per page
        mov16 qx, ox
        mov16 qy, oy
        jsr tilexy
        stx q4                      ; tile x (q4/q5: gx/gy are the live grid-walk cursor)
        sta q5                      ; tile y
        ldx q1
        lda LV_HDR+8,x
        sta q2
        lda LV_HDR+9,x
        sta q3
        ldx q4
        lda q5
        jsr maptile                 ; sets mapptr, Y = tx
        lda q2
        jsr mapput
        iny
        lda q3
        jsr mapput
        lda q4
        ldx q5
        jsr m_mark_dirty
        lda q4
        inca
        ldx q5
        jsr m_mark_dirty
        lda fe
        cmp #48
        bne @done
        stza fe
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
        jsr mapbyte
        sta q2
        iny
        jsr mapbyte
        sta q3
        iny
        lda q2
        jsr mapput
        iny
        lda q3
        jsr mapput
        lda fa
        ldx q5
        jsr m_mark_dirty
        lda fa
        inca
        ldx q5
        jsr m_mark_dirty
        inc q5
        dec q4
        bne @rl
@set:   lda #1
        sta fd
@draw:  lda fd
        clc
        adc #100
        jmp m_addsprite

; ============================================================================
; Status bar digits (drawn into the bar master image in bank 4)  [main RAM]
; ============================================================================
        .code
; draw digit A at bar pixel column X (even), digit slot Y (0..8): copies a 64-byte digit
; tile into the bar image.
;
; Each buffer remembers the nine values its bar was last drawn with, because redraw_hud
; redraws all nine whenever anything changes and a score tick usually moves only one of
; them -- the other eight were 128 bytes of copy for no pixels (measured 5.0K cycles a
; render on an L0 run, 3.2% of the frame).  The bank is BANK_LVL on entry and on exit, so
; the skip path must not touch it.
bar_digit:
        pha                         ; X is the column and must survive: test curbuf in A,
        lda curbuf                  ; which the push has already saved
        beq :+
        tya
        ora #16
        tay
:       pla
        cmp BARCACHE,y
        beq bd_same
        sta BARCACHE,y
        pha
        setbank BANK_SPR
        pla
        lsr                         ; C = d bit0, A = d >> 1
        sta w16+1
        lda #0
        ror                         ; A = d0 << 7
        lsr w16+1                   ; C = d bit1, w16+1 = d >> 2
        ror                         ; A = d1 << 7 | d0 << 6
        clc
        adc #<SPR_DIGITS
        sta w16
        lda w16+1
        adc #>SPR_DIGITS
        sta w16+1                   ; digit tile
        txa
        and #$FE                    ; char = x/2, then *8 -- i.e. (x & $FE) * 4
        stza ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        adc #<BARADDR               ; straight into the back buffer's bar row (no offscreen
        sta ptr                     ; buffer): bank 4 glyph at $8xxx, screen bar at $7Bxx
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
        lda (w16),y
        sta (ptr),y
        dey
        lda (w16),y
        sta (ptr),y
        dey
        lda (w16),y
        sta (ptr),y
        dey
        bpl :-
        setbank BANK_LVL
bd_same:
        rts

bar_touch:
        lda #1
        sta BARDIRTY
        sta BARDIRTY+1
        rts

redraw_hud:
        jsr draw_lives
        jsr draw_health
        jsr draw_stars
        jmp draw_score

draw_lives:
        lda lives
        ldx #18
        ldy #0
        jmp bar_digit
draw_health:
        lda health
        ldx #46
        ldy #1
        jmp bar_digit
draw_stars:                         ; stars remaining: 2 digits at 74, 82
        lda stars
        jsr div10
        ldx #74
        ldy #2
        jsr bar_digit
        lda q1
        ldx #82
        ldy #3
        jmp bar_digit
; A = A / 10 ; q1 = A mod 10
div10:  ldx #0
:       cmp #10
        bcc :+
        sbc #10
        inx
        bra :-
:       sta q1
        txa
        rts
draw_score:                         ; 5 digits at 108..140
        mov16 t16, score
        ldx #4
@d:     phx
        ; t16 /= 10 -> remainder
        jsr div10_16
        plx
        phx
        txa
        clc
        adc #4                      ; score digits are slots 4..8
        tay
        asl
        asl
        asl
        adc #76                     ; (X+4)*8 + 76 = X*8 + 108
        tax
        lda q1
        jsr bar_digit
        plx
        dex
        bpl @d
        rts
; t16 = t16 / 10 ; q1 = remainder
div10_16:
        stza q1
        ldx #16
        lda q1                  ; remainder lives in A for the whole loop
@l:     asl t16
        rol t16+1
        rol a                   ; was rol q1 / lda q1
        cmp #10
        bcc :+
        sbc #10                 ; was sbc #10 / sta q1
        inc t16
:       dex
        bne @l
        sta q1
        rts

        .segment "LOGIC"
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
