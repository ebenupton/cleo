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
.macro blt16i var, imm, label
        lda var
        cmp #<(imm)
        lda var+1
        sbc #>(imm)
        bvc :+
        eor #$80
:      bmi label
.endmacro
; branch if var >= imm
.macro bge16i var, imm, label
        lda var
        cmp #<(imm)
        lda var+1
        sbc #>(imm)
        bvc :+
        eor #$80
:      bpl label
.endmacro
; branch if var <= imm
.macro ble16i var, imm, label
        lda #<(imm)
        cmp var
        lda #>(imm)
        sbc var+1
        bvc :+
        eor #$80
:      bpl label
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
        cmp #n
        bcs :+
        lda #n
:       sec
        sbc #n
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
LV_ALTPAGE = $BC00                ; bank 7: 2 x 256 : map byte -> alt class
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
gridw:    .res 1
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
gridsh:   .res 1                  ; log2 gridw

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
        ; alt class = ALTPAGE[page][byte]
        tay
        lda q1
        clc
        adc #>LV_ALTPAGE
        sta @ap+2
@ap:    lda LV_ALTPAGE,y
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
@below: add16i qy, 8
        jsr getinfo
        lsr
        lsr
        lsr
        lsr
        clc
        adc #8
        sec
        sbc q5
        rts
@notbelow:
        lda q4
        bne @done
        sub16i qy, 8
        jsr getinfo
        sta q3
        and #15
        cmp #8
        bne @done
        lda q3
        lsr
        lsr
        lsr
        lsr
        sec
        sbc #8
        sta q4
@done:  lda q4
        sec
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
        lda q1
        clc
        adc #>LV_ATTR0
        sta @at+2
@at:    lda LV_ATTR0,y
        rts

; ============================================================================
; Level initialisation (level pack already loaded in bank 7)
; ============================================================================
level_init:
        jsr init_maprows            ; main RAM: the row tables live with the map
        ; alt class per page: ALTPAGE[p][b] = ALTCLS[id(b)].  Page entries are pre-shifted
        ; tile addresses: lo = (id&3)<<6 | bank, hi = $80 | id>>2 (see convert.py).
        ; The pages are in bank 6 and the alt classes in bank 7, so take a copy of the
        ; pages into the screen, which is blanked for the whole of a level load.
        jsr copy_pages              ; main RAM: they are in bank 6 with the map
        ldx #0
@ap:    lda PGCOPY+256,x
        ldy PGCOPY,x
        jsr @altof
        sta LV_ALTPAGE,x
        lda PGCOPY+768,x
        ldy PGCOPY+512,x
        jsr @altof
        sta LV_ALTPAGE+256,x
        inx
        bne @ap
        bra @apdone
        ; A = hi, Y = lo -> A = alt class of that tile (X preserved)
@altof: cmp #$C0                    ; a solid tile has no id: its class is in the
        bcc :+                      ; low nibble of the entry, where the bank would be
        tya
        and #$0F
        rts
:       asl
        asl                         ; (id >> 2) << 2 = id & $FC
        sta t16
        tya
        asl
        rol
        rol
        and #3                      ; id & 3
        ora t16
        tay
        lda LV_ALTCLS,y
        rts
@apdone:
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
        lda #1
        ldx gridsh
        beq :++
:       asl
        dex
        bne :-
:       sta gridw
        ; clear object state, then grid
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
        ldx #0
        lda #$FF
:       sta LV_GRID,x
        inx
        cpx #128
        bne :-
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
        add16 t16, t16b
        add16i t16, LV_OBJS
        ldy #0
        lda (t16),y
        sta otype
        ldx obj
        sta O_TYPE,x
        iny
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
        submin0 1
        lsr
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
        jsr m_rnd
        jsr mod12
        sta O_AL,y
        inc stars
        lda q2
        submin0 1
        lsr
        lsr
        lsr
        sta gy
        lda q2
        lsr
        lsr
        lsr
        sta gy1
        jmp @box
@t1:    lda O_XL,y
        clc
        adc #4
        sta O_XL,y
        lda O_XH,y
        adc #0
        sta O_XH,y
        lda q1
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
        lda O_AL,y
        sta t16b
        lda O_AH,y
        sta t16b+1
        inc t16b
        bne :+
        inc t16b+1
:       jsr mod16
        lda t16
        sta O_CL,y
        lda t16+1
        sta O_CH,y
        jsr m_rnd
        sta t16
        jsr m_rnd
        and #$0F
        sta t16+1
        lda O_BL,y
        sta t16b
        lda O_BH,y
        sta t16b+1
        inc t16b
        bne :+
        inc t16b+1
:       jsr mod16
        lda t16
        sta O_DL,y
        lda t16+1
        sta O_DH,y
        lda q2
        submin0 1
        lsr
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
        lda gy
        cmp gy1
        beq :+
        bcs @nextobj
:       lda gx0
        sta gx
@bx:    ; cell = gx + (gy << gridsh)
        lda gy
        ldx gridsh
        beq :++
:       asl
        dex
        bne :-
:       clc
        adc gx
        tax
        ldy bent
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
        bra @bx
:       inc gy
        lda gy
        cmp gy1
        beq :+
        bcs @nextobj
:       lda gx0
        sta gx
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
@x8:    pha
        lsr
        lsr
        lsr
        lsr
        lsr
        tax
        pla
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
        lda wx
        sta t16
        lda wx+1
        sta t16+1
        jsr shr6
        sta gx0
        lda wx
        clc
        adc #159
        sta t16
        lda wx+1
        adc #0
        sta t16+1
        jsr shr6
        sta gx1
        lda wy
        sta t16
        lda wy+1
        sta t16+1
        jsr shr6
        sta gy
        lda wy
        clc
        adc #VISLINES/2-1
        sta t16
        lda wy+1
        adc #0
        sta t16+1
        jsr shr6
        sta gy1
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
        lda O_STAMP,y
        cmp frame
        beq @skip
        lda frame
        sta O_STAMP,y
        sty obj
        jsr process_object
        setbank BANK_LVL
@skip:  ldx bent
        lda LV_BNEXT,x
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
:       ; ---- after objects
        lda bounce
        beq :+
        mov16i vy, -1280
:       ; kill tile under player
        lda health
        bne :+
        lda hurt
        bne @nokill
:       mov16 qx, px
        mov16 qy, py
        add16i qy, 12
        jsr gettileattr
        bpl @nokill
        ; knockback by facing
        stz hx+1
        lda facing
        beq :+
        lda #$FF
        sta hx+1                    ; facing left -> hx negative -> vx = +768
:       jsr player_hit
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
        jsr draw_health
        lda #1
        sta hurt
        stz control
        stz vx
        stz vx+1
        lda health
        beq :+
        mov16i vx, 768
        bit hx+1
        bmi :+
        mov16i vx, -768
:       mov16i vy, -1280
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
        bcs @respawn
        bra @draw
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
        jsr draw_lives
        jsr draw_health
@draw:  mov16 spx, px
        mov16 spy, py
        lda #26
        jmp m_addsprite

; vy = (vy + 80) * 31 >> 5
gravity:
        add16i vy, 80
        mov16 t16, vy
        neg16 t16
        ldx #5
:       asr16 t16
        dex
        bne :-
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
        rts

; ============================================================================
; player alive update
; ============================================================================
player_update:
        ; alt = getAltitude(px, py+16)
        mov16 qx, px
        mov16 qy, py
        add16i qy, 16
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
        mov16i vy, -1280
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
        lda dpx
        cmp alt
        bcc :+
        lda alt
        sta dpx
        stz dpx+1
:       add16 py, dpx
        lda alt
        sec
        sbc dpx
        sta alt
        bra @vdone
@up:    add16 py, dpx
@upl:   mov16 qx, px
        mov16 qy, py
        add16i qy, 16
        jsr getaltitude
        sta alt
        bpl @vdone
        inc py
        bne @upl
        inc py+1
        bra @upl
@vdone:
        ; fell off bottom?
        mov16 t16, maph
        sub16i t16, 24
        bgt16 py, t16, @fell
        bra @push
@fell:  mov16 evframe, frame
        stza health
        jsr draw_health
        stz control
        stz vx
        stz vx+1
        lda #SFX_DIE
        sta SFXREQ
@push:  mov16 qx, px
        mov16 qy, py
        add16i qy, 16
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
        mov16 t16, vx
        asl16 t16
        add16 t16, vx               ; 3vx
        neg16 t16
        ldx #6
:       asr16 t16
        dex
        bne :-
        add16 vx, t16
        lda q6
        ldx #0
        ora #0
        bpl :+
        dex
:       sta t16
        stx t16+1
        ; * 24
        asl16 t16
        asl16 t16
        asl16 t16
        mov16 t16b, t16
        asl16 t16
        add16 t16, t16b             ; 8p + 16p
        add16 vx, t16
        bra @nofric
@air:   ; vx = vx*5>>3
        mov16 t16, vx
        asl16 t16
        add16 t16, vx
        neg16 t16
        asr16 t16
        asr16 t16
        asr16 t16
        add16 vx, t16
@nofric:
        ; horizontal input
        lda control
        beq @norun
        lda keys
        and #(K_LEFT|K_RIGHT)
        beq @norun
        cmp #(K_LEFT|K_RIGHT)
        beq @norun
        pha
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
        mov16i t16, 36
        bra @acc
@acc288:
        mov16i t16, 288
@acc:   pla
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
        mov16 dpx, vx
        add16i dpx, 128             ; leaves the high byte in A
        sta dpx
        and #$80
        beq :+
        lda #$FF
:       sta dpx+1
        bne16 dpx, :+
        jmp @hdone
:
@hl:    mov16 qx, px
        mov16 qy, py
        add16i qy, 16
        lda dpx+1
        bmi @hneg
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
        bmi @step
        cmp #2
        bcs @alt
@step:  sx16 t16
        add16 py, t16
        stza alt
        bra @hnext
@alt:   sta alt
@hnext: ; steps -= dir
        lda dpx+1
        bmi :+
        dec dpx
        bra :++
:       inc dpx
:       lda dpx
        beq :+
        jmp @hl
:
        bra @hdone
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
        mov16i bvx, 3584
        lda facing
        beq @bdir
        mov16i bvx, -3584
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
        sta t16
        lda frame+1
        sbc evframe+1
        bne @clrhurt                ; elapsed >= 256 -> clear
        lda t16
        cmp #65
        bcc @afterhurt
@clrhurt:
        stz hurt
@afterhurt:
        lda control
        bne @afterctl
        lda frame
        sec
        sbc evframe
        sta t16
        lda frame+1
        sbc evframe+1
        bne @setctl
        lda t16
        cmp #25
        bcc @afterctl
@setctl:
        lda #1
        sta control
@afterctl:
        ; ---- choose sprite
        lda control
        bne @ctl
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
        lsr
        asl
        bra @sprf
@standing:
        lda anim
        cmp #113
        bcs @s10
        cmp #109
        bcs @s12
        cmp #93
        bcs @s10
        lda #8
        bra @sprf
@s10:   lda #10
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
@sprf:  clc
        adc facing
@spr:   sta q1
        lda hurt
        beq @drawp
        lda frame
        and #3
        bne @boom
@drawp: mov16 spx, px
        mov16 spy, py
        lda q1
        jsr m_addsprite
@boom:  ; ---- boomerang
        lda bactive
        bne :+
        jmp @bdone
:
        dif16 rx, px, bx            ; rx = px - bx
        mov16 ry, py
        add16i ry, 8
        sub16 ry, by                ; ry = py + 8 - by
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
        mov16 t16, bvx
        asl16 t16
        add16 t16, bvx
        neg16 t16
        ldx #6
:       asr16 t16
        dex
        bne :-
        add16 bvx, t16
        asl16 rx
        add16 bvx, rx
        mov16 t16, bvx
        add16i t16, 128
        lda t16+1
        sx16 t16
        add16 bx, t16
        mov16 t16, bvy
        asl16 t16
        add16 t16, bvy
        neg16 t16
        ldx #6
:       asr16 t16
        dex
        bne :-
        add16 bvy, t16
        asl16 ry
        add16 bvy, ry
        mov16 t16, bvy
        add16i t16, 128
        lda t16+1
        sx16 t16
        add16 by, t16
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
        blt16 px, exitx, @noexit
        mov16 t16, exitx
        add16i t16, 16
        bge16 px, t16, @noexit
        blt16 py, exity, @noexit
        mov16 t16, exity
        add16i t16, 24
        bge16 py, t16, @noexit
        lda #1
        sta exiting
@noexit:
        rts


; ============================================================================
; Object processing.  Y = object index (obj).  Loads fields into zp, dispatches, stores back.
; ============================================================================
process_object:
        lda O_XL,y
        sta ox
        lda O_XH,y
        sta ox+1
        lda O_YL,y
        sta oy
        lda O_YH,y
        sta oy+1
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
        lda O_TYPE,y
        sta otype
        dif16 rx, ox, px
        dif16 ry, oy, py
        mov16 spx, ox
        mov16 spy, oy
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
@call:  jmpx @tab
@tab:   .word ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .word ob_spike, ob_none, ob_flame, ob_powerup, ob_vanish, ob_switch
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
        .byte 112, 144, 116, 144        ; 32: <-16, 16, <-12, 16
        .byte 116, 140, 0, 255          ; 36: <-12, 12, <-128, 127
        .byte 112, 144, 104, 148        ; 40: <-16, 16, <-24, 20
        .byte 118, 138, 112, 136        ; 44: <-10, 10, <-16, 8
        .byte 120, 128, 104, 136        ; 48: <-8, 0, <-24, 8
        .byte 112, 144, 104, 140        ; 52: <-16, 16, <-24, 12
        .byte 112, 129, 143, 145        ; 56: <-16, 1, 15, 17
        .byte 112, 144, 104, 140        ; 60: <-16, 16, <-24, 12

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
:       jmp draw_score

; ---------------------------------------------------------------- STAR (0)
ob_star:
        lda frame
        and #1
        bne @nostep
        lda fa
        cmp #18                     ; cap: a collected star's fa must not wrap 8-bit
        bcs @nostep                 ; (it would make the star reappear ~every 20s)
        inc fa
@nostep:
        lda fa
        cmp #12
        bne :+
        lda fc
        bne :+
        stza fa
:       lda fc
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
        sta fa
        lda #1
        sta fc
        dec stars
        jsr draw_stars
        lda #1
        jsr addscore
        lda #SFX_STAR
        sta SFXREQ
@anim:  lda fa
        cmp #18
        bcs @done
        lsr
        ldx fe                      ; box class: spin frames on a uniform background use
        beq @reg                    ; the pre-composited box sprites (no mask, no erase)
        cmp #6
        bcs @reg                    ; sparkle frames stay regular (C = 0 below)
        adc boxbase-1,x
        jmp m_addsprite
@reg:   clc
        adc #34
        jmp m_addsprite
@done:  rts
boxbase: .byte 103, 109

; ---------------------------------------------------------------- TRAMPOLINE (1)
ob_tramp:
        lda fa
        beq :+
        inc fa
        lda fa
        cmp #10
        bne :+
        stza fa
:       lda health
        beq @draw
        ldx #8
        jsr inrange
        bcc @draw
        bmi16 vy, @draw
        beq16 vy, @draw
        lda #1
        sta fa
        mov16i vy, -2048
        lda #SFX_JUMP
        sta SFXREQ
@draw:  lda fa
        clc
        adc #2
        lsr
        lsr
        clc
        adc #43
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
        bcc :+
        jmp @coll
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
        bne16 fb, @coll
        stza fc
        bra @coll
@c4:    ; if B < A + 128: B += 16
        mov16 t16, fa
        add16i t16, 128
        bge16 fb, t16, @coll
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
        bmi16 ry, @nostomp
        beq16 ry, @nostomp
        bmi16 vy, @nostomp
        beq16 vy, @nostomp
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
        mov16 t16, fa
        add16i t16, 128
        bge16 fb, t16, @done
        lda fc
        cmp #2
        bcs @f6
        lda fe
        cmp #3
        bcc @f0
        cmp #6
        bcc @f2
        cmp #9
        bcc @f4
@f2:    lda #2
        bra @fr
@f0:    lda #0
        bra @fr
@f4:    lda #4
        bra @fr
@f6:    lda #6
@fr:    clc
        adc #46
        sta q1
        lda fc
        and #1
        clc
        adc q1
        jmp m_addsprite
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
        inc fa
        bne :+
        inc fa+1
:       lda fa
        cmp #17
        bne @norst
        lda fa+1
        bne @norst
        jsr m_rnd
        and #63
        clc
        adc #64
        eor #$FF
        inca                         ; -(r&63)-64
        sx16 fa
@norst: ; rise = (A*A >> 3) - 28  (A > -16) -> q6/t16b
        lda fa+1
        beq @calc
        cmp #$FF
        bne @nowarm
        lda fa
        cmp #<-16
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
        sub16i t16, 28
        mov16 rise, t16
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
        mov16 ry, oy
        add16 ry, rise
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
        ldx #0
        bit fa+1
        bmi @fr
        ldx #2
        beq16 fa, @fr
        ldx #4
@fr:    txa
        clc
        adc #54
        sta q1
        bgt16 ox, px, :+
        bra :++
:       inc q1
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
        mov16 spy, oy
        add16 spy, fc
        lda q1
        jsr m_addsprite
        mov16 spx, ox
        add16 spx, fd
        mov16 spy, oy
        lda #60
        jmp m_addsprite
@done:  rts

; t16 = A * A (A unsigned 0..128)
square: sta q1
        sta q1x
        stza t16
        stza t16+1
        ldx #8
@l:     asl t16
        rol t16+1
        asl q1
        bcc :+
        lda t16
        clc
        adc q1x
        sta t16
        bcc :+
        inc t16+1
:       dex
        bne @l
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
        beq16 fd, @boom
        bmi16 fd, @boom
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
        php
        mov16 rx, t16
        mov16 ry, t16b
        plp
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
        bmi16 vy, @nostomp
        beq16 vy, @nostomp
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
        lda #4
        bra @fr
@f0:    lda #0
        bra @fr
@f2:    lda #2
@fr:    clc
        adc #61
        sta q1
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
        sx16 t16
        add16 spx, t16
        lda frame+1
        sta t16+1
        lda frame
        sta t16
        asl16 t16
        asl16 t16
        add16 t16, frame            ; 5*frame
        lsr t16+1
        ror t16
        lsr t16+1
        ror t16
        lda obj
        asl
        asl
        asl
        sec
        sbc obj                     ; obj*7
        clc
        adc t16
        and #15
        tax
        lda batoff,x
        sx16 t16
        add16 spy, t16
        lda q1
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
        mov16 t16, fb
        add16i t16, 256
        blt16 fd, t16, :+
        jmp @done
:
        add16i fa, 120
        mov16 t16, fa
        add16i t16, 128
        lda t16+1
        sx16 t16
        add16 fd, t16
        mov16 t16, fc
        asr16 t16
        add16 spx, t16
        mov16 t16, fd
        asr16 t16
        add16 spy, t16
        ldx #65
        bgt16 spx, px, :+
        bra :++
:       ldx #66
:       txa
        jmp m_addsprite
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
        lda fb
        clc
        adc q1
        sta fb
        bcc :+
        inc fb+1
:       bge16 fb, fa, :+
        bra @coll
:       lda #1
        sta fc
        bra @coll
@left:  lda fb
        sec
        sbc q1
        sta fb
        bcs :+
        dec fb+1
:       bmi16 fb, @stop
        bne16 fb, @coll
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
        beq16 fb, @bset
        lda #1
        sta fc
@bset:  lda #8
        sta bcnt
@draw:  bmi16 fb, @f8
        beq16 fb, @f8
        bge16 fb, fa, @f8
        lda fe
        cmp #3
        bcc @f0
        cmp #6
        bcc @f2
        cmp #9
        bcc @f4
        lda #6
        bra @fr
@f0:    lda #0
        bra @fr
@f2:    lda #2
        bra @fr
@f4:    lda #4
@fr:    clc
        adc fc
        bra @sp
@f8:    lda #8
@sp:    sta q1
        lda otype
        cmp #5
        bne :+
        lda #67
        bra :++
:       lda #76
:       clc
        adc q1
        jmp m_addsprite

; ---------------------------------------------------------------- SPIKE (7)
ob_spike:
        inc fa
        bne :+
        inc fa+1
:       lda fa
        cmp #24
        bne @nowrap
        lda fa+1
        bne @nowrap
        jsr m_rnd
        and #63
        clc
        adc #64
        eor #$FF
        inca
        sx16 fa
@nowrap:
        lda health
        beq @draw
        lda fa+1
        bne @draw
        lda fa
        cmp #8
        bcs @draw
        ; rx > -8 && rx < (A+1)*2 && ry > -24 && ry < 8
        lda fa
        inca
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
@draw:  bmi16 fa, @done
        lda fa
        cmp #8
        bcc :+
        lda #23
        sec
        sbc fa
        lsr
:       clc
        adc #85
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
        jsr draw_health
        lda #SFX_POWER
        sta SFXREQ
        bra @draw
@adv:   cmp #6
        bcs @done
        inc fa
@draw:  lda fa
        cmp #6
        bcs @done
        lsr
        clc
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
        and #3
        bne @done
        lda fe
        cmp #12
        bcs :+
        lsr
        bra @set
:       cmp #37
        bcc @six
        lda #48
        sec
        sbc fe
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
        tay
        lda LV_ROWPAGE,y
        beq :+
        lda #12
:       clc
        adc q1
        tax
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
; draw digit A at bar pixel column X (even): copies a 64-byte digit tile into the bar image
bar_digit:
        pha
        setbank BANK_SPR
        pla
        stza w16+1
        asl
        asl
        asl
        asl
        asl
        rol w16+1
        asl
        rol w16+1
        clc
        adc #<SPR_DIGITS
        sta w16
        lda w16+1
        adc #>SPR_DIGITS
        sta w16+1                   ; digit tile
        txa
        lsr                         ; char = x/2
        stza ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        clc
        adc #<SPR_BAR
        sta ptr
        lda ptr+1
        adc #>SPR_BAR
        sta ptr+1                   ; bar char address (row 0)
        ldy #31
:       lda (w16),y
        sta (ptr),y
        dey
        bpl :-
        ; row 1: +640 in bar, +32 in tile
        add16i w16, 32
        add16i ptr, 640
        ldy #31
:       lda (w16),y
        sta (ptr),y
        dey
        bpl :-
        lda #1
        sta BARDIRTY
        sta BARDIRTY+1
        setbank BANK_LVL
        rts

draw_lives:
        lda lives
        ldx #18
        jmp bar_digit
draw_health:
        lda health
        ldx #46
        jmp bar_digit
draw_stars:                         ; stars remaining: 2 digits at 74, 82
        lda stars
        jsr div10
        ldx #74
        jsr bar_digit
        lda q1
        ldx #82
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
        asl
        asl
        asl
        clc
        adc #108
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
@l:     asl t16
        rol t16+1
        rol q1
        lda q1
        cmp #10
        bcc :+
        sbc #10
        sta q1
        inc t16
:       dex
        bne @l
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
