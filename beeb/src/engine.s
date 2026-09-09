; ============================================================================
; CLEO - BBC Master 128 MODE 2 port : display engine
;   - main + shadow RAM double buffered 20K ring framebuffers
;   - vertical rupture: fixed status bar section + hardware scrolled playfield
;     with 2-scanline fine vertical scroll, 1-character horizontal scroll
;   - tiles are 8x8 game pixels = 4 chars x 2 char rows (64 bytes) in SWR
; ============================================================================
        .setcpu "65C02"
        .include "assets.inc"

; ---------------------------------------------------------------- hardware
CRTC_IDX  = $FE00
CRTC_DAT  = $FE01
ULA_CTRL  = $FE20
ULA_PAL   = $FE21
ROMSEL    = $FE30
ACCCON    = $FE34
VIA_ORB   = $FE40
VIA_ORA   = $FE41
VIA_DDRB  = $FE42
VIA_DDRA  = $FE43
VIA_T1CL  = $FE44
VIA_T1CH  = $FE45
VIA_T1LL  = $FE46
VIA_T1LH  = $FE47
VIA_ACR   = $FE4B
VIA_PCR   = $FE4C
VIA_IFR   = $FE4D
VIA_IER   = $FE4E
VIA_ORANH = $FE4F
UVIA_IER  = $FE6E

OSWRCH    = $FFEE
OSBYTE    = $FFF4
OSFILE    = $FFDD
OSCLI     = $FFF7
IRQ1V     = $0204
ROMSEL_CPY= $F4

SCREEN    = $3000
BARBUF    = SPR_BAR               ; master bar image lives in bank 4 (2 char rows x 640 bytes)

BANK_SPR  = 4
BANK_TIL0 = 5
BANK_TIL1 = 6
BANK_LVL  = 7

; bank 7 layout
LV_PAGE0  = $8000                 ; 256 lo, 256 bank
LV_PAGE1  = $8200
LV_ROWPAGE= $8400
LV_HDR    = $8480
LV_OBJS   = $8500
LV_ATTR0  = $8900                 ; per page attribute (kill/push)
LV_ATTR1  = $8A00
LV_MAP    = $8B00                 ; up to 8K, row major
LV_ALTCLS = $AB00                 ; 512 : compact tile -> alt class
LV_ALTTAB = $AD00                 ; classes x 8
LV_OBJST  = $B000                 ; object state arrays (16 x 149)
LV_GRID   = $B950                 ; 128 grid heads
LV_BOBJ   = $B9D0                 ; 255
LV_BNEXT  = $BAD0                 ; 255
LV_MUSIC  = $BC00

VISROWS   = 27                    ; visible char rows (216 lines = 108 game px)
BUFROWS   = 28                    ; rows held (visible + partial top row source)
VISLINES  = VISROWS*8
MAXREC    = 32
MAXSPR    = 32

; key bits
K_LEFT  = 1
K_RIGHT = 2
K_UP    = 4
K_DOWN  = 8
K_FIRE  = 16
K_MENU  = 32

; ---------------------------------------------------------------- zero page
        .zeropage
ptr:      .res 2                  ; general pointer
tp:       .res 2                  ; tile/source pointer
sp:       .res 2                  ; screen pointer
tmp:      .res 1
tmp2:     .res 1
tmp3:     .res 1
tmp4:     .res 1
cnt:      .res 1
w16:      .res 2                  ; scratch words
w16b:     .res 2

; window (map coords) for the frame being rendered
wx:       .res 2                  ; window x in map px (even)
wy:       .res 2                  ; window y in map px
wcx:      .res 2                  ; window x in map chars (wx/2)
wcy:      .res 1                  ; window y in map char rows (wy/4)
wfine:    .res 1                  ; fine scanline offset 0,2,4,6
curbuf:   .res 1                  ; buffer being drawn: 0 = main, 1 = shadow
curbank:  .res 1
recp:     .res 2                  ; current buffer's sprite record base
rp:       .res 2                  ; current record

; drawrect args
rc_x:     .res 2
rc_y:     .res 1
rc_w:     .res 1
rc_h:     .res 1
rc_sub:   .res 1
rc_gi:    .res 1
rc_subc:  .res 1
rc_n:     .res 1

; sprite draw
spx:      .res 2
spy:      .res 2
sp_ptr:   .res 2
sp_w:     .res 1
sp_lines: .res 1
sp_ext:   .res 1                  ; height in scanlines (2*lines for half-res)
sp_flags: .res 1
sp_c0:    .res 1
sp_c1:    .res 1
sp_lb0:   .res 2
sp_r0:    .res 1
sp_r1:    .res 1
sp_ra0:   .res 1
sp_ra1:   .res 1
sp_col:   .res 2                  ; current column base pointer
sp_step:  .res 2
sp_off:   .res 2                  ; row source offset
sp_row:   .res 1
sp_c:     .res 1
sp_lim:   .res 1
spi:      .res 1
lcnt:     .res 1
lidx:     .res 1
ringS:    .res 2                  ; window start char S (0..2559)
barq:     .res 1                  ; row slot q = S/80

; level geometry
maplw:    .res 1                  ; log2 map width in tiles
maplh:    .res 1
mapw:     .res 2                  ; map width in px
maph:     .res 2
maxwx:    .res 2                  ; mapw - 160
maxwy:    .res 2                  ; maph - 120

; misc
vsyncs:   .res 1                  ; incremented by vsync ISR
flipreq:  .res 1                  ; 1 = flip pending
flipvs:   .res 1
keys:     .res 1                  ; current key bits
seed:     .res 2
dispbuf:  .res 1
SFXPTR:   .res 2
MUSPTR:   .res 2

; ---------------------------------------------------------------- tables (uninitialised RAM $0400-$0CFF)
        .segment "TABLES"
MASKTAB:   .res 256               ; data byte -> AND mask
SWAPTAB:   .res 256               ; nibble (pixel) swap for mirroring
RINGLO:    .res 32                ; ring row r -> screen address
RINGHI:    .res 32
GATHER:    .res 48                ; per-row tile gather (lo,bank pairs)
SECTAB:    .res 2*48              ; per buffer: 6 sections x 8 bytes
SPRLIST:   .res 5*MAXSPR          ; sprite draw list: id, xlo, xhi, ylo, yhi
SPRREC:    .res 2*MAXREC*10       ; per buffer drawn-sprite records: id,xl,xh,yl,yh, cxl,cxh,cy,w,h
RECCNT:    .res 2
KEEP:      .res MAXREC
SV_COLX:   .res 2
SV_COLW:   .res 1
SV_ROWY:   .res 1
SV_ROWH:   .res 1
DIRTYSEEN: .res 1
NSPR:      .res 1
BUF_CX:    .res 4                 ; per buffer held window (cx lo,hi) x2
BUF_CY:    .res 2
BUF_VALID: .res 2
BUF_BARQ:  .res 2
BARDIRTY:  .res 2
DIRTYLIST: .res 2*2*16            ; per buffer dirty tiles (tx, ty)
DIRTYCNT:  .res 2
DISPSECT:  .res 1                 ; SECTAB offset the ISR chain uses (0/48)
NEXTSECT:  .res 1
SECIDX:    .res 1
OLDIRQ:    .res 2
OLDIER:    .res 1
OLDACR:    .res 1
SFXREQ:    .res 1
SFXDUR:    .res 1
MUSON:     .res 1
MUSDUR:    .res 1
MUSNOTE:   .res 3
ISRT1:     .res 1
ISRT2:     .res 1
OSBLOCK:   .res 18
KEYSCAN:   .res 1
VS2T:      .res 2
NEXTBUF:   .res 1

        .code

; ---------------------------------------------------------------- macros
.macro setbank n
        lda #n
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
.endmacro

.macro crtc reg, val
        lda #reg
        sta CRTC_IDX
        lda val
        sta CRTC_DAT
.endmacro

; advance sp (screen pointer) by one char (8 bytes) with ring wrap
.macro spnext
        lda sp
        clc
        adc #8
        sta sp
        bcc :+
        inc sp+1
        bpl :+
        lda sp+1
        sec
        sbc #$50
        sta sp+1
:
.endmacro

; ============================================================================
; ringaddr: screen address of map char (w16 = cx 16 bit, A = cy) -> sp
; ============================================================================
ringaddr:
        and #31
        tax
        lda w16+1
        sta sp+1
        lda w16
        asl
        rol sp+1
        asl
        rol sp+1
        asl
        rol sp+1                    ; sp+1:A = cx*8
        clc
        adc RINGLO,x
        sta sp
        lda sp+1
        adc RINGHI,x
        sta sp+1
        bpl :+
        sec
        sbc #$50
        sta sp+1
:       rts

; ============================================================================
; drawrect: draw map tiles into the current back buffer.
;   rc_x (map chars, 16 bit), rc_y (map char rows), rc_w (chars 1..80), rc_h (rows)
; ============================================================================
drawrect:
        lda rc_h
        bne @row
        rts
@row:
        ; ---- tile row ty = rc_y >> 1 ; map row pointer ptr = $8000 | (ty << maplw)
        lda rc_y
        lsr
        sta ptr
        stz ptr+1
        tax
        setbank BANK_LVL
        lda LV_ROWPAGE,x
        beq :+
        lda #2
:       clc
        adc #>LV_PAGE0
        sta @pglo+2
        inc
        sta @pgbk+2
        ldx maplw
@shl:   asl ptr
        rol ptr+1
        dex
        bne @shl
        lda ptr+1
        clc
        adc #>LV_MAP
        sta ptr+1
        ; ---- tx0 = rc_x >> 2 ; tx1 = (rc_x + rc_w - 1) >> 2
        lda rc_x
        clc
        adc rc_w
        sta w16
        lda rc_x+1
        adc #0
        sta w16+1
        lda w16
        bne :+
        dec w16+1
:       dec w16
        lsr w16+1
        ror w16
        lsr w16+1
        ror w16                     ; w16 = tx1
        lda rc_x+1
        lsr
        sta tmp
        lda rc_x
        ror
        lsr tmp
        ror                         ; A = tx0 (map width <= 256 tiles)
        tay
        sta tmp
        lda w16
        sec
        sbc tmp
        sta cnt                     ; ntiles-1
        ldx #0
@gl:    lda (ptr),y
        phy
        tay
@pglo:  lda LV_PAGE0,y
        sta GATHER,x
@pgbk:  lda LV_PAGE0+$100,y
        sta GATHER+1,x
        ply
        iny
        inx
        inx
        dec cnt
        bpl @gl
        ; ---- screen base
        lda rc_x
        sta w16
        lda rc_x+1
        sta w16+1
        lda rc_y
        jsr ringaddr
        lda rc_y
        and #1
        beq :+
        lda #32
:       sta rc_sub
        lda rc_x
        and #3
        sta rc_subc
        lda rc_w
        sta cnt
        stz rc_gi
@run:
        lda #4
        sec
        sbc rc_subc
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        ldx rc_gi
        lda GATHER+1,x
        cmp curbank
        beq :+
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
:       lda GATHER,x
        pha
        and #3
        ror
        ror
        ror
        and #$C0
        clc
        adc rc_sub
        sta tp
        lda rc_subc
        asl
        asl
        asl
        adc tp
        sta tp
        pla
        lsr
        lsr
        ora #$80
        sta tp+1
        ; wrap check: sp + n*8 crosses $8000 ?
        lda rc_n
        asl
        asl
        asl
        sta tmp                     ; bytes
        clc
        adc sp
        lda sp+1
        adc #0
        bpl :+
        jmp @slow
:       lda rc_n
        asl
        tax
        jmp (@jt-2,x)
@jt:    .word @b7, @b15, @b23, @b31
        ; unrolled copy, descending Y so that entry at 8n-1 copies bytes 8n-1..0
.macro CPY1 k
        ldy #k
        lda (tp),y
        sta (sp),y
.endmacro
@b31:   CPY1 31
        CPY1 30
        CPY1 29
        CPY1 28
        CPY1 27
        CPY1 26
        CPY1 25
        CPY1 24
@b23:   CPY1 23
        CPY1 22
        CPY1 21
        CPY1 20
        CPY1 19
        CPY1 18
        CPY1 17
        CPY1 16
@b15:   CPY1 15
        CPY1 14
        CPY1 13
        CPY1 12
        CPY1 11
        CPY1 10
        CPY1 9
        CPY1 8
@b7:    CPY1 7
        CPY1 6
        CPY1 5
        CPY1 4
        CPY1 3
        CPY1 2
        CPY1 1
        CPY1 0
        lda sp
        clc
        adc tmp
        sta sp
        bcc :+
        inc sp+1
        bpl :+
        lda sp+1
        sec
        sbc #$50
        sta sp+1
:       bra @runend
@slow:
        lda rc_n
        sta tmp2
@sc:    ldy #7
:       lda (tp),y
        sta (sp),y
        dey
        bpl :-
        lda tp
        clc
        adc #8
        sta tp
        bcc :+
        inc tp+1
:       spnext
        dec tmp2
        bne @sc
@runend:
        lda cnt
        sec
        sbc rc_n
        sta cnt
        beq @rowdone
        stz rc_subc
        inc rc_gi
        inc rc_gi
        jmp @run
@rowdone:
        inc rc_y
        dec rc_h
        beq :+
        jmp @row
:       rts

; ============================================================================
; drawrect_clip: like drawrect but clips the rect to the current window
; (rows wcy..wcy+30, cols wcx..wcx+79).
; ============================================================================
drawrect_clip:
        ; rows
        lda rc_y
        sec
        sbc wcy
        sta tmp                     ; rel row start (may be negative)
        bpl :+
        ; start above window: shrink
        clc
        adc rc_h
        beq @none
        bmi @none
        sta rc_h
        lda wcy
        sta rc_y
        stz tmp
:       lda tmp
        clc
        adc rc_h                    ; rel end+1
        cmp #BUFROWS+1
        bcc :+
        lda #BUFROWS
        sec
        sbc tmp
        beq @none
        bmi @none
        sta rc_h
:       ; cols: rel = rc_x - wcx (16 bit signed)
        lda rc_x
        sec
        sbc wcx
        sta w16
        lda rc_x+1
        sbc wcx+1
        sta w16+1
        bpl @right
        ; rel < 0: visible only if -rel < w
        lda w16
        eor #$FF
        sta tmp
        lda w16+1
        eor #$FF
        sta tmp2
        inc tmp
        bne :+
        inc tmp2
:       lda tmp2
        bne @none                   ; -rel >= 256 > any width
        lda tmp
        cmp rc_w
        bcs @none
        lda rc_w
        sec
        sbc tmp
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        stz w16
        stz w16+1
@right: lda w16+1
        bne @none                   ; rel >= 256 -> off right
        lda w16
        cmp #80
        bcs @none
        clc
        adc rc_w
        cmp #81
        bcc :+
        lda #80
        sec
        sbc w16
        sta rc_w
:       jmp drawrect
@none:  rts

; ============================================================================
; scroll_validate: make current buffer hold window (wcx, wcy) x 80 x 31
; ============================================================================
scroll_validate:
        stz SV_COLW
        stz SV_ROWH
        ldx curbuf
        lda BUF_VALID,x
        bne :+
        jmp @full
:       txa
        asl
        tay
        ; dx = wcx - BUF_CX
        lda wcx
        sec
        sbc BUF_CX,y
        sta w16
        lda wcx+1
        sbc BUF_CX+1,y
        sta w16+1
        ; dy = wcy - BUF_CY
        lda wcy
        sec
        sbc BUF_CY,x
        sta w16b
        ; |dx| >= 80 -> full
        lda w16+1
        beq @dxpos
        cmp #$FF
        beq :+
        jmp @full
:       lda w16
        cmp #<-79
        bcs :+
        jmp @full
:
        ; dx negative: draw cols wcx .. wcx+(-dx)-1, rows wcy..wcy+30
        lda w16
        eor #$FF
        inc
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        bra @docols
@dxpos: lda w16
        beq @dyc
        cmp #80
        bcs @full
        ; dx positive: cols (oldcx+80) .. wcx+79 = dx cols starting at wcx+80-dx
        sta rc_w
        lda wcx
        clc
        adc #80
        sta rc_x
        lda wcx+1
        adc #0
        sta rc_x+1
        lda rc_x
        sec
        sbc rc_w
        sta rc_x
        bcs @docols
        dec rc_x+1
@docols:
        lda wcy
        sta rc_y
        lda #BUFROWS
        sta rc_h
        lda rc_x
        sta SV_COLX
        lda rc_x+1
        sta SV_COLX+1
        lda rc_w
        sta SV_COLW
        jsr drawrect
@dyc:   lda w16b
        beq @done
        bpl @dypos
        cmp #<-30
        bcc @full
        eor #$FF
        inc
        sta rc_h
        lda wcy
        sta rc_y
        bra @dorows
@dypos: cmp #BUFROWS
        bcs @full
        sta rc_h
        lda wcy
        clc
        adc #BUFROWS
        sec
        sbc rc_h
        sta rc_y
@dorows:
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        lda #80
        sta rc_w
        lda rc_y
        sta SV_ROWY
        lda rc_h
        sta SV_ROWH
        jsr drawrect
        bra @done
@full:
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        lda wcy
        sta rc_y
        lda #80
        sta rc_w
        lda #BUFROWS
        sta rc_h
        lda #1
        sta DIRTYSEEN
        jsr drawrect
@done:
        ldx curbuf
        lda #1
        sta BUF_VALID,x
        lda wcy
        sta BUF_CY,x
        txa
        asl
        tay
        lda wcx
        sta BUF_CX,y
        lda wcx+1
        sta BUF_CX+1,y
        rts

; ============================================================================
; Persistent sprite records.  match_sprites: KEEP[i] = new sprite i identical to record i
; ============================================================================
match_sprites:
        ldx curbuf
        lda RECCNT,x
        cmp NSPR
        bcc :+
        lda NSPR
:       sta cnt                     ; n = min(RECCNT, NSPR)
        ldx #0
        stx tmp4                    ; i
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx tmp4
        cpx NSPR
        bcs @done
        stz KEEP,x
        cpx cnt
        bcs @next
        ldy sprmul5,x
        lda SPRLIST,y
        ldx #0
        cmp (rp,x)
        bne @next
        ldx #1
        lda SPRLIST+1,y
        cmp (rp,x)
        bne @next
        inx
        lda SPRLIST+2,y
        cmp (rp,x)
        bne @next
        inx
        lda SPRLIST+3,y
        cmp (rp,x)
        bne @next
        inx
        lda SPRLIST+4,y
        cmp (rp,x)
        bne @next
        ldx tmp4
        lda #1
        sta KEEP,x
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc tmp4
        bra @l
@done:  rts

; erase_old: redraw tiles under old records that are not kept
erase_old:
        ldx curbuf
        lda RECCNT,x
        beq @done
        sta lcnt
        stz lidx
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx lidx
        cpx NSPR
        bcs @erase
        lda KEEP,x
        bne @next
@erase: ldy #8
        lda (rp),y
        beq @next
        sta rc_w
        iny
        lda (rp),y
        sta rc_h
        ldy #5
        lda (rp),y
        sta rc_x
        iny
        lda (rp),y
        sta rc_x+1
        iny
        lda (rp),y
        sta rc_y
        jsr drawrect_clip
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc lidx
        dec lcnt
        bne @l
@done:  rts

; rec_overlap: carry set if the record's rect (rp) overlaps this frame's refreshed regions
rec_overlap:
        lda DIRTYSEEN
        bne @yes
        lda SV_COLW
        beq @row
        ; cx < colx + colw  &&  cx + w > colx
        ldy #5
        lda (rp),y
        sta w16
        iny
        lda (rp),y
        sta w16+1                   ; cx
        lda SV_COLX
        clc
        adc SV_COLW
        sta w16b
        lda SV_COLX+1
        adc #0
        sta w16b+1                  ; colx+colw
        lda w16
        cmp w16b
        lda w16+1
        sbc w16b+1
        bcs @row                    ; cx >= colx+colw -> no x overlap
        ldy #8
        lda (rp),y
        clc
        adc w16
        sta w16
        bcc :+
        inc w16+1
:       lda SV_COLX
        cmp w16
        lda SV_COLX+1
        sbc w16+1
        bcc @yes                    ; colx < cx+w
@row:   lda SV_ROWH
        beq @no
        ldy #7
        lda (rp),y                  ; cy
        cmp SV_ROWY
        bcs :+
        ; cy < rowy : overlap if cy + h > rowy
        ldy #9
        clc
        adc (rp),y
        cmp SV_ROWY
        bcc @no
        beq @no
        bra @yes
:       ; cy >= rowy : overlap if cy < rowy + rowh
        sec
        sbc SV_ROWY
        cmp SV_ROWH
        bcs @no
@yes:   sec
        rts
@no:    clc
        rts

; ============================================================================
; dirty tiles: redraw changed map tiles (both buffers keep their own list)
; ============================================================================
mark_dirty:                         ; A = tx, X = ty  (adds to both buffers' lists)
        sta tmp
        stx tmp2
        ldx #0
@b:     lda DIRTYCNT,x
        cmp #16
        bcs @next
        asl
        sta tmp3
        txa
        asl
        asl
        asl
        asl
        asl                         ; x*32
        clc
        adc tmp3
        tay
        lda tmp
        sta DIRTYLIST,y
        lda tmp2
        sta DIRTYLIST+1,y
        inc DIRTYCNT,x
@next:  inx
        cpx #2
        bne @b
        rts

draw_dirty:
        ldx curbuf
        lda DIRTYCNT,x
        beq @done
        sta lcnt
        txa
        asl
        asl
        asl
        asl
        asl
        sta lidx
@l:     ldy lidx
        lda DIRTYLIST,y
        stz rc_x+1
        asl
        rol rc_x+1
        asl
        rol rc_x+1
        sta rc_x
        lda DIRTYLIST+1,y
        asl
        sta rc_y
        lda #4
        sta rc_w
        lda #2
        sta rc_h
        jsr drawrect_clip
        inc lidx
        inc lidx
        dec lcnt
        bne @l
        ldx curbuf
        stz DIRTYCNT,x
@done:  rts

; ============================================================================
; Sprites
; ============================================================================
; add sprite to draw list: A = id, spx/spy = map px
addsprite:
        ldx NSPR
        cpx #MAXSPR
        bcs @full
        ldy sprmul5,x
        sta SPRLIST,y
        lda spx
        sta SPRLIST+1,y
        lda spx+1
        sta SPRLIST+2,y
        lda spy
        sta SPRLIST+3,y
        lda spy+1
        sta SPRLIST+4,y
        inc NSPR
@full:  rts

; draw all listed sprites into current buffer (skipping unchanged kept ones)
draw_sprites:
        stz spi
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     lda spi
        cmp NSPR
        bcs @done
        ldx spi
        lda KEEP,x
        beq @draw
        jsr rec_overlap
        bcc @next
@draw:  ldx spi
        ldy sprmul5,x
        lda SPRLIST+1,y
        sta spx
        lda SPRLIST+2,y
        sta spx+1
        lda SPRLIST+3,y
        sta spy
        lda SPRLIST+4,y
        sta spy+1
        lda SPRLIST,y
        pha
        ; copy identity into record, clear rect
        phy
        ldy #0
        sta (rp),y
        ply
        lda SPRLIST+1,y
        pha
        lda SPRLIST+2,y
        pha
        lda SPRLIST+3,y
        pha
        lda SPRLIST+4,y
        ldy #4
        sta (rp),y
        pla
        dey
        sta (rp),y
        pla
        dey
        sta (rp),y
        pla
        dey
        sta (rp),y
        ldy #8
        lda #0
        sta (rp),y
        pla
        jsr drawsprite
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc spi
        bra @l
@done:  ldx curbuf
        lda NSPR
        sta RECCNT,x
        rts

; draw one sprite: A = id ; spx, spy = map px (ref point)
drawsprite:
        pha
        lda spbank
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
        pla
        ; table entry pointer
        stz ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        sta ptr
        lda ptr+1
        ora #>SPR_TABLE
        sta ptr+1
        ldy #0
        lda (ptr),y
        sta sp_ptr
        iny
        lda (ptr),y
        sta sp_ptr+1
        iny
        lda (ptr),y
        sta sp_w
        beq @out0
        ldy #6
        lda (ptr),y
        sta sp_flags
        iny
        lda (ptr),y
        sta sp_lines
        sta sp_ext
        lda sp_flags
        and #2
        bne :+
        asl sp_ext                  ; half-res: two scanlines per stored row
:       ; ---- horizontal: sx = spx - refx - wx ; c0 = sx >> 1
        ldy #4
        lda (ptr),y
        jsr sext
        lda spx
        sec
        sbc (ptr),y
        sta w16
        lda spx+1
        sbc tmp3
        sta w16+1
        lda w16
        sec
        sbc wx
        sta w16
        lda w16+1
        sbc wx+1
        sta w16+1
        cmp #$80
        ror w16+1
        ror w16                     ; arithmetic shift right 1 -> c0 (16 bit)
        lda w16+1
        beq @cpos
        cmp #$FF
        bne @out0                   ; way off left
        ; c0 negative (-128..-1): cstart = 0 ; visible if c0 + W > 0
        lda w16
        clc
        adc sp_w
        beq @out0
        bmi @out0
        sta sp_c1                   ; c0+W (count of visible) -> c1 = that-1
        dec sp_c1
        stz sp_c0
        ; first visible column index = -c0
        lda w16
        eor #$FF
        inc
        sta sp_c                    ; starting image column
        bra @vert
@cpos:  lda w16
        cmp #80
        bcs @out0
        sta sp_c0
        clc
        adc sp_w
        dec
        cmp #80
        bcc :+
        lda #79
:       sta sp_c1
        stz sp_c
        bra @vert
@out0:  rts
@vert:
        ; ---- vertical: sy = spy - refy - wy ; lb0 = 2*sy + wfine
        ldy #5
        lda (ptr),y
        jsr sext
        lda spy
        sec
        sbc (ptr),y
        sta w16
        lda spy+1
        sbc tmp3
        sta w16+1
        lda w16
        sec
        sbc wy
        sta w16
        lda w16+1
        sbc wy+1
        sta w16+1
        asl w16
        rol w16+1
        lda w16
        clc
        adc wfine
        sta sp_lb0
        lda w16+1
        adc #0
        sta sp_lb0+1                ; lb0 (16 bit signed)
        ; lend = lb0 + ext - 1
        lda sp_lb0
        clc
        adc sp_ext
        sta w16
        lda sp_lb0+1
        adc #0
        sta w16+1
        lda w16
        bne :+
        dec w16+1
:       dec w16                     ; w16 = lb1
        ; clip lstart = max(lb0,0) ; lend = min(lb1, 247)
        lda sp_lb0+1
        bmi @top
        bne @out0                   ; lb0 >= 256 -> below
        lda sp_lb0
        cmp #BUFROWS*8
        bcs @out0
        sta tmp                     ; lstart
        bra @ck
@top:   lda w16+1
        bmi @out0                   ; lb1 < 0
        stz tmp
@ck:    lda w16+1
        bne @clampend
        lda w16
        cmp #BUFROWS*8
        bcc :+
@clampend:
        lda #BUFROWS*8-1
:       sta tmp2                    ; lend
        cmp tmp
        bcc @out0
        lda tmp
        and #7
        sta sp_ra0
        lda tmp
        lsr
        lsr
        lsr
        sta sp_r0
        lda tmp2
        and #7
        sta sp_ra1
        lda tmp2
        lsr
        lsr
        lsr
        sta sp_r1
        ; ---- record rect in current sprite record
        ldy #5
        lda wcx
        clc
        adc sp_c0
        sta (rp),y
        iny
        lda wcx+1
        adc #0
        sta (rp),y
        iny
        lda wcy
        clc
        adc sp_r0
        sta (rp),y
        iny
        lda sp_c1
        sec
        sbc sp_c0
        inc
        sta (rp),y
        iny
        lda sp_r1
        sec
        sbc sp_r0
        inc
        sta (rp),y
        ; ---- column base pointer & step
        lda sp_flags
        and #1
        beq @nomirror
        ; mirror: image column = W-1-c ; step = -lines
        lda sp_w
        dec
        sec
        sbc sp_c
        sta sp_c
        lda sp_lines
        eor #$FF
        inc
        sta sp_step
        lda #$FF
        sta sp_step+1
        bra @colbase
@nomirror:
        lda sp_lines
        sta sp_step
        stz sp_step+1
@colbase:
        ; sp_col = sp_ptr + sp_c * lines
        lda sp_ptr
        sta sp_col
        lda sp_ptr+1
        sta sp_col+1
        lda sp_c
        beq @rows
@mul:   lda sp_col
        clc
        adc sp_lines
        sta sp_col
        bcc :+
        inc sp_col+1
:       dec sp_c
        bne @mul
@rows:
        lda sp_r0
        sta sp_row
ds_rowloop:
        ; screen base for (wcx + c0, wcy + row)
        lda wcx
        clc
        adc sp_c0
        sta w16
        lda wcx+1
        adc #0
        sta w16+1
        lda wcy
        clc
        adc sp_row
        jsr ringaddr
        ; ra range for this row
        ldx #0
        lda sp_row
        cmp sp_r0
        bne :+
        ldx sp_ra0
:       stx tmp                     ; ra0'
        ldx #7
        cmp sp_r1
        bne :+
        ldx sp_ra1
:       stx tmp2                    ; ra1'
        ; row source offset = row*8 - lb0  (>>1 for half res)
        lda sp_row
        stz sp_off+1
        asl
        asl
        asl
        sec
        sbc sp_lb0
        sta sp_off
        lda #0
        sbc sp_lb0+1
        sta sp_off+1
        lda sp_flags
        and #2
        bne @fullres
        lda sp_off+1
        cmp #$80
        ror sp_off+1
        ror sp_off
@fullres:
        lda sp_col
        sta tp
        lda sp_col+1
        sta tp+1
        lda sp_c0
        sta sp_c
ds_colloop:
        ; tp = column base + off
        lda tp
        clc
        adc sp_off
        sta ptr
        lda tp+1
        adc sp_off+1
        sta ptr+1
        ; dispatch
        lda sp_flags
        and #3
        asl
        tax
        jmp (@disp,x)
@disp:  .word sprHN, sprHM, sprFN, sprFM
sprret:
        ; next column
        lda tp
        clc
        adc sp_step
        sta tp
        lda tp+1
        adc sp_step+1
        sta tp+1
        spnext
        lda sp_c
        cmp sp_c1
        beq ds_rowdone
        inc sp_c
        bra ds_colloop
ds_rowdone:
        lda sp_row
        cmp sp_r1
        beq ds_done
        inc sp_row
        jmp ds_rowloop
ds_done: rts

; ---- inner blocks.  ptr = source column (already offset), sp = screen char,
;      tmp = ra0', tmp2 = ra1'.  Full-res: source byte per line.
.macro SPRLINE k, mirror
        .local skip, opaque
        ldy #k
        lda (ptr),y
        beq skip
        tax
.if mirror
        lda SWAPTAB,x
        tax
.endif
        lda MASKTAB,x
        beq opaque
        and (sp),y
        sta tmp3
        txa
        ora tmp3
        sta (sp),y
        bra skip
opaque: txa
        sta (sp),y
skip:
.endmacro

.macro SPRFULL name, mirror
        .local partial, et, l0, l1, l2, l3, l4, l5, l6, l7, pl, ps, po, pd
name:
        lda tmp2
        cmp #7
        beq :+
        jmp partial
:       lda tmp
        asl
        tax
        jmp (et,x)
et:     .word l0,l1,l2,l3,l4,l5,l6,l7
l0:     SPRLINE 0, mirror
l1:     SPRLINE 1, mirror
l2:     SPRLINE 2, mirror
l3:     SPRLINE 3, mirror
l4:     SPRLINE 4, mirror
l5:     SPRLINE 5, mirror
l6:     SPRLINE 6, mirror
l7:     SPRLINE 7, mirror
        jmp sprret
partial:
        ldy tmp
pl:     lda (ptr),y
        beq ps
        tax
.if mirror
        lda SWAPTAB,x
        tax
.endif
        lda MASKTAB,x
        beq po
        and (sp),y
        sta tmp3
        txa
        ora tmp3
        sta (sp),y
        bra ps
po:     txa
        sta (sp),y
ps:     cpy tmp2
        beq pd
        iny
        bra pl
pd:     jmp sprret
.endmacro

        SPRFULL sprFN, 0
        SPRFULL sprFM, 1

; half res: one source byte -> two screen lines (2k, 2k+1)
.macro SPRLINE2 k, mirror
        .local skip, opaque
        ldy #k
        lda (ptr),y
        beq skip
        tax
.if mirror
        lda SWAPTAB,x
        tax
.endif
        lda MASKTAB,x
        beq opaque
        sta tmp4
        stx tmp3
        ldy #2*k
        lda (sp),y
        and tmp4
        ora tmp3
        sta (sp),y
        iny
        lda (sp),y
        and tmp4
        ora tmp3
        sta (sp),y
        bra skip
opaque: txa
        ldy #2*k
        sta (sp),y
        iny
        sta (sp),y
skip:
.endmacro

.macro SPRHALF name, mirror
        .local partial, et, l0, l1, l2, l3, pl, ps, po, pd
name:
        lda tmp2
        cmp #7
        beq :+
        jmp partial
:       lda tmp                     ; even 0,2,4,6 -> entry 0..3
        tax
        jmp (et,x)
et:     .word l0,l1,l2,l3
l0:     SPRLINE2 0, mirror
l1:     SPRLINE2 1, mirror
l2:     SPRLINE2 2, mirror
l3:     SPRLINE2 3, mirror
        jmp sprret
partial:
        lda tmp
        sta sp_lim                  ; current screen line (even)
pl:     lda sp_lim
        lsr
        tay
        lda (ptr),y
        beq ps
        tax
.if mirror
        lda SWAPTAB,x
        tax
.endif
        lda MASKTAB,x
        beq po
        sta tmp4
        stx tmp3
        ldy sp_lim
        lda (sp),y
        and tmp4
        ora tmp3
        sta (sp),y
        iny
        lda (sp),y
        and tmp4
        ora tmp3
        sta (sp),y
        bra ps
po:     txa
        ldy sp_lim
        sta (sp),y
        iny
        sta (sp),y
ps:     lda sp_lim
        inc
        cmp tmp2
        bcs pd
        inc sp_lim
        inc sp_lim
        bra pl
pd:     jmp sprret
.endmacro

        SPRHALF sprHN, 0
        SPRHALF sprHM, 1

; ============================================================================
; copy_partial: copy lines wfine..7 of ring row wcy into lines 0..(7-wfine)
; of ring row wcy-1, for all 80 chars (the "A" section source).
; ============================================================================
copy_partial:
        lda wfine
        bne :+
        rts
:       lda wcx
        sta w16
        lda wcx+1
        sta w16+1
        lda wcy
        jsr ringaddr                ; sp = source row start
        ; dest = sp - 640 (ring)
        lda sp
        sec
        sbc #<640
        sta ptr
        lda sp+1
        sbc #>640
        cmp #$30
        bcs :+
        adc #$50
:       sta ptr+1
        ; dest pointer adjusted by -wfine so that same Y indexes both
        lda ptr
        sec
        sbc wfine
        sta ptr
        bcs :+
        dec ptr+1
:       lda #80
        sta cnt
        lda wfine
        cmp #4
        beq @f4
        bcs @f6
@f2:    ldy #2
        lda (sp),y
        sta (ptr),y
        iny
        lda (sp),y
        sta (ptr),y
        iny
@f4:    ldy #4
        lda (sp),y
        sta (ptr),y
        iny
        lda (sp),y
        sta (ptr),y
        iny
@f6:    ldy #6
        lda (sp),y
        sta (ptr),y
        iny
        lda (sp),y
        sta (ptr),y
        ; advance both pointers by 8 with ring wrap
        spnext
        lda ptr
        clc
        adc #8
        sta ptr
        bcc :+
        inc ptr+1
:       ; wrap check on the REAL dest address (ptr + wfine): the adjusted pointer
        ; can still be $7FFx when the real address has crossed $8000
        lda ptr
        clc
        adc wfine
        lda ptr+1
        adc #0
        bpl :+
        lda ptr+1
        sec
        sbc #$50
        sta ptr+1
:       dec cnt
        beq @done
        lda wfine
        cmp #4
        beq @f4
        bcs @f6
        bra @f2
@done:  rts

; ============================================================================
; calc_ring: ringS = ((wcy & 31) * 80 + wcx) mod 2560 ; barq = ringS / 80
; ============================================================================
calc_ring:
        lda wcy
        and #31
        tax
        lda mul80lo,x
        clc
        adc wcx
        sta ringS
        lda mul80hi,x
        adc wcx+1
        sta ringS+1
        cmp #>2560
        bcc :+
        bne @sub
        lda ringS
        cmp #<2560
        bcc :+
@sub:   lda ringS
        sec
        sbc #<2560
        sta ringS
        lda ringS+1
        sbc #>2560
        sta ringS+1
:       ; q = S / 80
        lda ringS
        sta w16
        lda ringS+1
        sta w16+1
        ldx #0
@div:   lda w16
        sec
        sbc #80
        tay
        lda w16+1
        sbc #0
        bcc @dd
        sta w16+1
        sty w16
        inx
        bra @div
@dd:    stx barq
        rts

; copy_bar: if this buffer's bar rows are stale, write bar image into ring slots q-3, q-2
copy_bar:
        ldx curbuf
        lda BARDIRTY,x
        bne @do
        lda BUF_BARQ,x
        cmp barq
        bne @do
        rts
@do:    lda barq
        sta BUF_BARQ,x
        stz BARDIRTY,x
        sec
        sbc #3
        and #31
        tax
        lda #BANK_SPR
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
        lda #<BARBUF
        sta @s0+1
        lda #>BARBUF
        sta @s0+2
        jsr @row
        inx
        txa
        and #31
        tax
@row:   lda RINGLO,x
        sta @d0+1
        lda RINGHI,x
        sta @d0+2
        ldy #2                      ; 2 full pages
@pages: phx
        ldx #0
@s0:    lda BARBUF,x
@d0:    sta SCREEN,x
        inx
        bne @s0
        plx
        inc @s0+2
        inc @d0+2
        dey
        bne @pages
        ; final 128 bytes (same bases as @s0/@d0)
        lda @s0+1
        sta @s1+1
        lda @s0+2
        sta @s1+2
        lda @d0+1
        sta @d1+1
        lda @d0+2
        sta @d1+2
        phx
        ldx #127
@s1:    lda BARBUF,x
@d1:    sta SCREEN,x
        dex
        bpl @s1
        plx
        ; advance source by 128 for the second row
        lda @s0+1
        clc
        adc #128
        sta @s0+1
        bcc :+
        inc @s0+2
:       rts
@done:  rts

; ============================================================================
; build_sections: fill SECTAB for current buffer from ringS/barq/wfine
; entry i: R12n, R13n, R4, R9, R6, R7, T1lo, T1hi (T1 = duration of section i+1)
; ============================================================================
LINE = 64
build_sections:
        ; bar start (CRTC) = 80*((q-3)&31) + $600  -> w16b
        lda barq
        sec
        sbc #3
        and #31
        tax
        lda mul80lo,x
        clc
        adc #<$600
        sta w16b
        lda mul80hi,x
        adc #>$600
        sta w16b+1
        ; S + $600 -> w16
        lda ringS
        clc
        adc #<$600
        sta w16
        lda ringS+1
        adc #>$600
        sta w16+1
        lda curbuf
        beq :+
        lda #48
:       tax
        ; --- T
        lda #1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #2
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda wfine
        beq :+
        jmp @fine
:       ; f = 0 : T -> P (27 rows) -> Q
        lda w16+1
        sta SECTAB,x
        lda w16
        sta SECTAB+1,x
        lda #<(VISLINES*LINE-2)
        sta SECTAB+6,x
        lda #>(VISLINES*LINE-2)
        sta SECTAB+7,x
        ; P
        lda w16b+1
        sta SECTAB+8,x
        lda w16b
        sta SECTAB+9,x
        lda #VISROWS-1
        sta SECTAB+10,x
        lda #7
        sta SECTAB+11,x
        lda #30
        sta SECTAB+12,x
        sta SECTAB+13,x
        lda #<(40*LINE-2)
        sta SECTAB+14,x
        lda #>(40*LINE-2)
        sta SECTAB+15,x
        txa
        clc
        adc #16
        tax
        jmp @setq
@fine:
        ; T -> A (S-80) [8-f lines] -> P1 (S+80) [208] -> P2 (S+27*80) [f] -> Q
        jsr @sub80
        lda w16+1
        sta SECTAB,x
        lda w16
        sta SECTAB+1,x
        lda wfine
        eor #7
        inc                         ; 8-f
        jsr @dur
        sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        ; A
        jsr @add80
        jsr @add80                  ; S+80
        lda w16+1
        sta SECTAB+8,x
        lda w16
        sta SECTAB+9,x
        lda #0
        sta SECTAB+10,x
        lda #7
        sec
        sbc wfine
        sta SECTAB+11,x
        lda #2
        sta SECTAB+12,x
        lda #30
        sta SECTAB+13,x
        lda #<((VISROWS-1)*8*LINE-2)
        sta SECTAB+14,x
        lda #>((VISROWS-1)*8*LINE-2)
        sta SECTAB+15,x
        ; P1 : next = S + 27*80 = (S+80) + 26*80
        ldy #VISROWS-1
:       jsr @add80
        dey
        bne :-
        lda w16+1
        sta SECTAB+16,x
        lda w16
        sta SECTAB+17,x
        lda #VISROWS-2
        sta SECTAB+18,x
        lda #7
        sta SECTAB+19,x
        lda #VISROWS
        sta SECTAB+20,x
        lda #30
        sta SECTAB+21,x
        lda wfine
        jsr @dur
        sta SECTAB+22,x
        lda tmp3
        sta SECTAB+23,x
        ; P2
        lda w16b+1
        sta SECTAB+24,x
        lda w16b
        sta SECTAB+25,x
        lda #0
        sta SECTAB+26,x
        lda wfine
        dec
        sta SECTAB+27,x
        lda #VISROWS
        sta SECTAB+28,x
        lda #30
        sta SECTAB+29,x
        lda #<(40*LINE-2)
        sta SECTAB+30,x
        lda #>(40*LINE-2)
        sta SECTAB+31,x
        txa
        clc
        adc #32
        tax
@setq:  lda w16b+1
        sta SECTAB,x
        lda w16b
        sta SECTAB+1,x
        lda #QROWS-1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #0
        sta SECTAB+4,x
        lda #QVSYNC
        sta SECTAB+5,x
        lda #<(40*LINE-2)
        sta SECTAB+6,x
        lda #>(40*LINE-2)
        sta SECTAB+7,x
        rts
; A = lines -> A/tmp3 = lines*64-2
@dur:   stz tmp3
        asl
        rol tmp3
        asl
        rol tmp3
        asl
        rol tmp3
        asl
        rol tmp3
        asl
        rol tmp3
        asl
        rol tmp3
        sec
        sbc #2
        bcs :+
        dec tmp3
:       rts
; w16 = (w16 - 80) with ring wrap (w16 holds CRTC address S+$600 in $600..$FFF)
@sub80: lda w16
        sec
        sbc #80
        sta w16
        bcs :+
        dec w16+1
:       lda w16+1
        cmp #6
        bcs :+
        lda w16+1
        clc
        adc #$0A
        sta w16+1
:       rts
@add80: lda w16
        clc
        adc #80
        sta w16
        bcc :+
        inc w16+1
:       lda w16+1
        cmp #$10
        bcc :+
        sec
        sbc #$0A
        sta w16+1
:       rts

QROWS  = 10                        ; blank rows after the display (312 - 232 = 80 lines)
QVSYNC = 4                         ; vsync at Q row 4 -> T starts 48 lines after vsync

; ============================================================================
; Frame control
; ============================================================================
; select CPU access to the current back buffer (ACCCON X bit)
select_backbuf:
        lda ACCCON
        and #$FB
        ldx curbuf
        beq :+
        ora #$04
:       sta ACCCON
        lda #<SPRREC
        sta recp
        lda #>SPRREC
        sta recp+1
        lda curbuf
        beq :+
        lda recp
        clc
        adc #<(MAXREC*10)
        sta recp
        lda recp+1
        adc #>(MAXREC*10)
        sta recp+1
:       rts

; render everything queued for the current back buffer and request flip
render_frame:
        jsr select_backbuf
        ; derive char window
        lda wx
        sta wcx
        lda wx+1
        sta wcx+1
        lsr wcx+1
        ror wcx
        lda wy
        and #3
        asl
        sta wfine
        lda wy+1
        lsr
        lda wy
        ror
        lsr
        sta wcy
        jsr calc_ring
        jsr match_sprites
        jsr erase_old
        jsr scroll_validate
        ldx curbuf
        lda DIRTYCNT,x
        beq :+
        lda #1
        sta DIRTYSEEN
:       jsr draw_dirty
        jsr draw_sprites
        stz DIRTYSEEN
        jsr copy_partial
        jsr copy_bar
        stz NSPR
        jsr build_sections
        ; hand over to ISR
        lda curbuf
        sta NEXTBUF
        beq :+
        lda #48
:       sta NEXTSECT
        lda #1
        sta flipreq
        ; wait for flip
:       lda flipreq
        bne :-
        lda curbuf
        eor #1
        sta curbuf
        rts

; ============================================================================
; IRQ handling
; ============================================================================
irq_handler:
        phx
        phy
        bit VIA_IFR
        bvc @notT1
        ; ---- rupture chain step (time critical: R9, R4, R6 within the section's first line)
        ldx SECIDX
        lda #9
        sta CRTC_IDX
        lda SECTAB+3,x
        sta CRTC_DAT
        lda #4
        sta CRTC_IDX
        lda SECTAB+2,x
        sta CRTC_DAT
        lda #6
        sta CRTC_IDX
        lda SECTAB+4,x
        sta CRTC_DAT
        lda #7
        sta CRTC_IDX
        lda SECTAB+5,x
        sta CRTC_DAT
        lda #12
        sta CRTC_IDX
        lda SECTAB,x
        sta CRTC_DAT
        lda #13
        sta CRTC_IDX
        lda SECTAB+1,x
        sta CRTC_DAT
        lda SECTAB+6,x
        sta VIA_T1LL
        lda SECTAB+7,x
        sta VIA_T1LH
        lda VIA_T1CL                ; clear T1 flag
        txa
        clc
        adc #8
        sta SECIDX
        bra @exit
@notT1:
        lda VIA_IFR
        and #$02
        beq @exit
        ; ---- vsync: restart T1 first (constant latency), counter = vsync->T, latch = T duration
        lda VS2T
        sta VIA_T1LL
        lda VS2T+1
        sta VIA_T1CH
        lda #<(16*LINE-2)
        sta VIA_T1LL
        lda #>(16*LINE-2)
        sta VIA_T1LH
        lda #$02
        sta VIA_IFR
        inc vsyncs
        lda flipreq
        beq @noflip
        lda vsyncs
        sec
        sbc flipvs
        cmp #2
        bcc @noflip
        lda vsyncs
        sta flipvs
        lda NEXTSECT
        sta DISPSECT
        lda ACCCON
        and #$FE
        ora NEXTBUF
        sta ACCCON
        stz flipreq
@noflip:
        lda DISPSECT
        sta SECIDX
        jsr scan_keys
        jsr sound_tick
@exit:
        ply
        plx
        lda $FC
        rti

VS2T_DEFAULT = (QROWS-QVSYNC)*8*LINE - 2*LINE - 35   ; CA1 IRQ fires at end of the 2-line vsync pulse; T1 lands ~5us into T

; ---------------------------------------------------------------- keyboard
scan_keys:
        lda #$7F
        sta VIA_DDRA
        lda #3
        sta VIA_ORB                 ; disable keyboard autoscan
        ldx #0
        stx KEYSCAN
@k:     lda keytab,x
        sta VIA_ORANH
        lda VIA_ORANH
        bpl :+
        lda KEYSCAN
        ora keybits,x
        sta KEYSCAN
:       inx
        cpx #11
        bne @k
        lda KEYSCAN
        sta keys
        rts
keytab:  .byte $61,$19, $42,$79, $48,$39,$49, $68,$29, $62, $70
keybits: .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE, K_DOWN,K_DOWN, K_FIRE, K_MENU

; ---------------------------------------------------------------- sound
; sfx format: steps of (b0,b1,b2,frames) written to the SN76489 ; end = $FF
sound_tick:
        lda SFXREQ
        beq @play
        ; start new sfx
        asl
        tax
        lda sfxtab-2,x
        sta SFXPTR
        lda sfxtab-1,x
        sta SFXPTR+1
        stz SFXREQ
        lda #1
        sta SFXDUR
@play:  lda SFXPTR+1
        beq @music
        dec SFXDUR
        bne @music
        ldy #0
        lda (SFXPTR),y
        cmp #$FF
        beq @end
        jsr sndwrite
        iny
        lda (SFXPTR),y
        jsr sndwrite
        iny
        lda (SFXPTR),y
        jsr sndwrite
        iny
        lda (SFXPTR),y
        sta SFXDUR
        lda SFXPTR
        clc
        adc #4
        sta SFXPTR
        bcc @music
        inc SFXPTR+1
        bra @music
@end:   stz SFXPTR+1
        lda #$DF                    ; channel 2 off
        jsr sndwrite
        lda #$FF
        jsr sndwrite
@music: jmp music_tick

sndwrite:
        pha
        lda #$FF
        sta VIA_DDRA
        lda #$0B
        sta VIA_ORB                 ; keyboard autoscan on so the keyboard does not pull PA7
        pla
        sta VIA_ORANH
        lda #0
        sta VIA_ORB
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        nop
        lda #8
        sta VIA_ORB
        lda #$7F
        sta VIA_DDRA
        rts

; ---------------------------------------------------------------- music (bank 6 @ MUSIC_DATA)
MUSIC_DATA = $B500
MUSIC_TAB  = MUSIC_DATA             ; 72 x 2 byte periods (MIDI 24..95)
MUSIC_SEQ  = MUSIC_DATA + 144
music_tick:
        lda MUSON
        beq @done
        dec MUSDUR
        bne @done
        lda ROMSEL_CPY
        pha
        lda #BANK_TIL1
        sta ROMSEL_CPY
        sta ROMSEL
        ldy #0
        lda (MUSPTR),y
        bne :+
        lda #<MUSIC_SEQ
        sta MUSPTR
        lda #>MUSIC_SEQ
        sta MUSPTR+1
        lda (MUSPTR),y
:       sta MUSDUR
        ldx #0
@v:     iny
        lda (MUSPTR),y
        cmp MUSNOTE,x
        beq :+
        sta MUSNOTE,x
        phy
        jsr set_voice
        ply
:       inx
        cpx #3
        bne @v
        lda MUSPTR
        clc
        adc #4
        sta MUSPTR
        bcc :+
        inc MUSPTR+1
:       pla
        sta ROMSEL_CPY
        sta ROMSEL
@done:  rts

; X = voice (0..2), A = MIDI note (0 = rest)
set_voice:
        phx
        tay
        txa
        asl
        asl
        asl
        asl
        asl
        sta ISRT1                   ; ch << 5
        tya
        bne @note
        lda ISRT1
        ora #$9F
        jsr sndwrite
        plx
        rts
@note:  sec
        sbc #24
        asl
        tay
        lda MUSIC_TAB,y
        and #15
        ora ISRT1
        ora #$80
        jsr sndwrite
        lda MUSIC_TAB,y
        lsr
        lsr
        lsr
        lsr
        sta ISRT2
        lda MUSIC_TAB+1,y
        asl
        asl
        asl
        asl
        ora ISRT2
        jsr sndwrite
        plx
        lda musvol,x
        ora ISRT1
        ora #$90
        jsr sndwrite
        rts
musvol: .byte 3, 8, 8

music_start:
        lda #<MUSIC_SEQ
        sta MUSPTR
        lda #>MUSIC_SEQ
        sta MUSPTR+1
        lda #1
        sta MUSDUR
        stz MUSNOTE
        stz MUSNOTE+1
        stz MUSNOTE+2
        sta MUSON
        rts

music_stop:
        stz MUSON
        lda #$9F
        jsr sndwrite
        lda #$BF
        jsr sndwrite
        lda #$DF
        jsr sndwrite
        lda #$FF
        jmp sndwrite

; ---------------------------------------------------------------- interrupt takeover
take_over:
        sei
        lda IRQ1V
        sta OLDIRQ
        lda IRQ1V+1
        sta OLDIRQ+1
        lda VIA_ACR
        sta OLDACR
        lda #<irq_handler
        sta IRQ1V
        lda #>irq_handler
        sta IRQ1V+1
        lda #$7F
        sta VIA_IER
        sta UVIA_IER
        lda VIA_ACR
        and #$3F
        ora #$40                    ; T1 continuous
        sta VIA_ACR
        lda #<(40*LINE)
        sta VIA_T1LL
        lda #>(40*LINE)
        sta VIA_T1CH
        lda #$C2                    ; enable CA1 (vsync) + T1
        sta VIA_IER
        lda #$7F
        sta VIA_IFR
        stz flipreq
        cli
        rts

; ============================================================================
; CRTC / palette setup
; ============================================================================
crtc_init:
        ; standard MODE 2 timings, no interlace, cursor off
        ldx #0
:       stx CRTC_IDX
        lda crtctab,x
        sta CRTC_DAT
        inx
        cpx #14
        bne :-
        rts
crtctab: .byte 127,80,98,$28, 38,0,32,34, 0,7, $20,8, $06,$00

set_palette:
        ldx #15
:       txa
        asl
        asl
        asl
        asl
        sta tmp
        txa
        and #7
        eor #7
        ora tmp
        sta ULA_PAL
        dex
        bpl :-
        rts

blank_palette:
        ldx #15
:       txa
        asl
        asl
        asl
        asl
        ora #7
        sta ULA_PAL
        dex
        bpl :-
        rts

; ============================================================================
; table init
; ============================================================================
init_tables:
        ldx #0
@t:     txa
        and #$AA
        beq :+
        lda #0
        bra :++
:       lda #$AA
:       sta tmp
        txa
        and #$55
        beq :+
        lda #0
        bra :++
:       lda #$55
:       ora tmp
        sta MASKTAB,x
        txa
        and #$AA
        lsr
        sta tmp
        txa
        and #$55
        asl
        ora tmp
        sta SWAPTAB,x
        inx
        bne @t
        ; ring rows
        lda #<SCREEN
        sta w16
        lda #>SCREEN
        sta w16+1
        ldx #0
@r:     lda w16
        sta RINGLO,x
        lda w16+1
        sta RINGHI,x
        lda w16
        clc
        adc #<640
        sta w16
        lda w16+1
        adc #>640
        sta w16+1
        inx
        cpx #32
        bne @r
        ; mul80 tables (row slot -> chars)
        stz w16
        stz w16+1
        ldx #0
@m80:   lda w16
        sta mul80lo,x
        lda w16+1
        sta mul80hi,x
        lda w16
        clc
        adc #80
        sta w16
        bcc :+
        inc w16+1
:       inx
        cpx #32
        bne @m80
        ldx #0
        lda #0
@m:     sta sprmul5,x
        clc
        adc #5
        inx
        cpx #MAXSPR
        bne @m
        stz RECCNT
        stz RECCNT+1
        stz DIRTYSEEN
        stz DIRTYCNT
        stz DIRTYCNT+1
        stz BUF_VALID
        stz BUF_VALID+1
        stz NSPR
        stz SFXREQ
        stz SFXPTR+1
        stz MUSON
        stz DISPSECT
        stz curbuf
        lda #BANK_SPR
        sta spbank
        lda #$FF
        sta BUF_BARQ
        sta BUF_BARQ+1
        stz BARDIRTY
        stz BARDIRTY+1
        lda #<VS2T_DEFAULT
        sta VS2T
        lda #>VS2T_DEFAULT
        sta VS2T+1
        rts

        .segment "TABLES"
sprmul5: .res MAXSPR
mul80lo: .res 32
mul80hi: .res 32
        .code

; ============================================================================
; Disc loading: polled WD1770 sector reads (DFS single density, 10 x 256 byte sectors/track)
; file table entries: sector lo, hi, nsectors, bank, dest hi (dest lo = 0)
; ============================================================================
FDC_CTRL = $FE24
FDC_STAT = $FE28
FDC_CMD  = $FE28
FDC_TRK  = $FE29
FDC_SEC  = $FE2A
FDC_DATA = $FE2B

        .segment "TABLES"
ld_sec:    .res 2
ld_n:      .res 1
ld_trk:    .res 1
ld_sc:     .res 1
cur_trk:   .res 1
ld_done:   .res 1
ld_secs:   .res 1
        .code

; NMI handler (reached via JMP at $0D00): 1770 data request / completion (multi-sector read)
nmi_handler:
        pha
        lda FDC_STAT
        and #3
        cmp #3
        bne nmi_nd
        lda FDC_DATA
nmi_sta:
        sta $FFFF
        inc nmi_sta+1
        bne :+
        inc nmi_sta+2
        dec ld_secs                 ; a whole sector done
        bne :+
        lda #$D0                    ; force interrupt: stop the multi-sector read
        sta FDC_CMD
        lda #1
        sta ld_done
:       pla
        rti
nmi_nd: and #1
        bne :+
        lda #1
        sta ld_done
:       pla
        rti

; initialise: reset controller, restore head to track 0
disc_init:
        lda #$20
        sta FDC_CTRL                ; reset asserted (active low bit 2)
        lda #$25
        sta FDC_CTRL                ; drive 0, FM, reset released
        lda #$00                    ; restore, spin up, 6ms
        sta FDC_CMD
        jsr fdc_wait
        stz cur_trk
        rts

fdc_wait:
        ldx #20
:       dex
        bne :-
:       lda FDC_STAT
        and #1
        bne :-
        rts

; load file A (index into filetab) into its destination
loadfile:
        pha
        jsr music_stop
        pla
        sta tmp
        asl
        asl
        adc tmp                     ; *5
        tax
        lda filetab,x
        sta ld_sec
        lda filetab+1,x
        sta ld_sec+1
        lda filetab+2,x
        sta ld_n
        lda filetab+3,x
        beq :+
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
:       lda filetab+4,x
        sta ptr+1
        stz ptr
        ; track/sector from linear sector
        stz ld_trk
        lda ld_sec
        sta ld_sc
        lda ld_sec+1
        beq :++
:       lda ld_sc                   ; subtract 256 = 25 tracks + 6 sectors
        clc
        adc #6
        sta ld_sc
        lda ld_trk
        adc #25
        sta ld_trk
        dec ld_sec+1
        bne :-
:       lda ld_sc
        cmp #10
        bcc @track
        sbc #10
        sta ld_sc
        inc ld_trk
        bra :-
@track: lda ld_trk
        cmp cur_trk
        beq @read
        sta cur_trk
        sta FDC_DATA
        lda #$10                    ; seek (no verify)
        sta FDC_CMD
        jsr fdc_wait
@read:  ; sectors to read on this track: min(ld_n, 10 - ld_sc)
        lda #10
        sec
        sbc ld_sc
        cmp ld_n
        bcc :+
        lda ld_n
:       sta ld_secs
        sta tmp
        lda ld_sc
        sta FDC_SEC
        lda ptr
        sta nmi_sta+1
        lda ptr+1
        sta nmi_sta+2
        stz ld_done
        lda #$94                    ; read multiple sectors with head settle (NMI handler transfers and stops)
        sta FDC_CMD
        ldx #20
:       dex
        bne :-
:       lda ld_done
        bne :+
        lda FDC_STAT                ; fallback: command finished without a completion NMI
        and #1
        bne :-
:       jsr fdc_wait                ; the abort takes a moment to clear busy
        lda ptr+1
        clc
        adc tmp
        sta ptr+1
        lda ld_n
        sec
        sbc tmp
        sta ld_n
        beq @done
        stz ld_sc
        inc ld_trk
        bra @track
@done:  rts

; sign extend A -> tmp3 (0 or $FF)
sext:   and #$80
        beq :+
        lda #$FF
:       sta tmp3
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
