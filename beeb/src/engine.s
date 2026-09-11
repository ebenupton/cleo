; ============================================================================
; CLEO - BBC Master 128 MODE 2 port : display engine
;   - main + shadow RAM double buffered 20K ring framebuffers
;   - vertical rupture: fixed status bar section + hardware scrolled playfield
;     with 2-scanline fine vertical scroll, 1-character horizontal scroll
;   - tiles are 8x8 game pixels = 4 chars x 2 char rows (64 bytes) in SWR
; ============================================================================
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
BANK_MAP  = 6                     ; the map and the tables read alongside it

; bank 6: this level's overflow tiles, then the map and everything the renderer or
; the logic reads in the same breath as the map.  It is here rather than in bank 7
; because a Model B has to put the game logic in a bank, and the map is the only
; thing big enough to make the room.
;         $8000  tiles 256.. of this level (16 tiles: no level needs more)
LV_ROWPAGE= $8400
LV_PAGE0  = $8500                 ; 256 lo ((idx&3)<<6 | bank), 256 hi ($80 | idx>>2)
LV_PAGE1  = $8700                 ; only loaded for the levels that need two pages
LV_MAP    = $8900                 ; up to 8K, row major
;         $A900  LV_MAPROWLO, LV_MAPROWHI (built by level_init, see logic.s)
;         $B000  box stars, $B800 music

; bank 7
LOGIC_ADDR= $8900                 ; the game logic and menus: bank 7, above the tables
PGCOPY    = SCREEN                ; level_init's scratch copy of the page tables
LV_HDR    = $8000
LV_OBJS   = $8100
LV_ATTR0  = $8500                 ; per page attribute (kill/push)
LV_ATTR1  = $8600
LV_ALTCLS = $8700                 ; 512 : this level's tile id -> alt class
;         $8900..$AFFF free: the game logic lives here on a Model B
LV_OBJST  = $B000                 ; object state arrays (16 x 149)
LV_GRID   = $B950                 ; 128 grid heads
LV_BOBJ   = $B9D0                 ; 255
LV_BNEXT  = $BAD0                 ; 255
;         $BC00  LV_ALTPAGE (512, see logic.s)
LV_ALTTAB = $BE00                 ; classes x 8 (global: loaded once)

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
jv:       .res 2                  ; jmp (abs,x) has no 6502 form: it goes through here
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
rowoff:   .res 1                  ; rc_sub | rc_subc*8 : byte offset into the tile for this run
rc_n:     .res 1
rc_wrap:  .res 1                  ; row may cross $8000 (needs per-run wrap check)
rc_tx0:   .res 1                  ; per-rect invariants: first tile column,
rc_nt:    .res 1                  ;   tiles-1 per row,
rc_sc0:   .res 1                  ;   rc_x & 3 (chars into the first tile),
rc_ro0:   .res 1                  ;   (rc_x & 3) << 3,
rc_sp:    .res 2                  ;   screen address of the current char row's first char
irq_x:    .res 1                  ; IRQ handler register save (not reentrant)
irq_y:    .res 1

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
sp_rb:    .res 2                  ; screen address of the current row's first char
sp_rp:    .res 2                  ; source pointer for the current row (col base + row offset)
sp_rinc:  .res 1                  ; source bytes per row: 8 (full res) or 4 (half res)
sp_ncol:  .res 1                  ; columns-1
sp_row:   .res 1
sp_c:     .res 1
sp_lim:   .res 1
sp_cnt:   .res 1                  ; sprite column countdown
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
SFXPTR:   .res 2
MUSPTR:   .res 2

; ---------------------------------------------------------------- tables (uninitialised RAM $0400-$0CFF)
        .segment "TABLES"
MASKTAB:   .res 256               ; data byte -> AND mask
SWAPTAB:   .res 256               ; nibble (pixel) swap for mirroring
IDENT:     .res 256               ; identity table: ora IDENT,x == ora X (no temp)
RINGLO:    .res 32                ; ring row r -> screen address
RINGHI:    .res 32
GATHERL:   .res 24                ; per-row tile gather: tile address lo | bank (low nibble)
GATHERH:   .res 24                ;                       tile address hi
SECTAB:    .res 2*48              ; per buffer: 6 sections x 8 bytes
SPRLIST:   .res 5*MAXSPR          ; sprite draw list: id, xlo, xhi, ylo, yhi
SPRREC:    .res 2*MAXREC*10       ; per buffer drawn-sprite records: id,xl,xh,yl,yh, cxl,cxh,cy,w,h
GLYPHBUF:  .res 8                 ; one font glyph, copied out of bank 4 for the menus
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
PART_CY:   .res 2                 ; per buffer: row/fine the partial (A) row was last copied for
PART_F:    .res 2
PART_LO:   .res 2                 ; per buffer: window columns of row wcy drawn since that copy
PART_HI:   .res 2                 ;   (LO > HI = none)
BUF_BARQ:  .res 2
BUF_BARADDR: .res 4          ; per buffer: bar CRTC start (hi,lo) x2 (fixes cross-buffer carryover)
BARDIRTY:  .res 2
DIRTYLIST: .res 2*2*16            ; per buffer dirty tiles (tx, ty)
DIRTYCNT:  .res 2
DISPSECT:  .res 1                 ; SECTAB offset the ISR chain uses (0/48)
curR7:     .res 1                 ; last R7 written by the chain (for the vsync re-phase)
NEXTSECT:  .res 1
SECIDX:    .res 1
OLDIRQ:    .res 2
OLDIER:    .res 1
OLDACR:    .res 1
SFXREQ:    .res 1
SFXDUR:    .res 1
MUSON:     .res 1
MUSTMP:    .res 1                 ; musbyte scratch (ISR context: must not touch tmp)
music_tab: .res 144               ; SN76489 periods for MIDI 24..95, decoded at start-up
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
        lda sp+1                    ; C = 1 here: the adc #8 above carried
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
        bne :+
        rts
:       lda rc_y
        cmp wcy
        bne :+
        ldx curbuf                  ; touches the window's top row: widen the partial-row
        lda rc_x                    ; dirty column range (rects are window-clipped, so
        sec                         ; the low byte of rc_x - wcx is the column)
        sbc wcx
        cmp PART_LO,x
        bcs @plo
        sta PART_LO,x
@plo:   clc
        adc rc_w
        deca
        cmp PART_HI,x
        bcc :+
        sta PART_HI,x
:       ; ---- per-rect invariants: tx0 = rc_x >> 2 ; tiles-1 = ((rc_x + rc_w - 1) >> 2) - tx0
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
        sta rc_tx0
        lda w16
        sec
        sbc rc_tx0
        sta rc_nt                   ; tiles-1
        lda rc_x
        and #3
        sta rc_sc0
        asl
        asl
        asl
        sta rc_ro0
        ; screen address of the first row; later rows add 640 (ring wrap) in @drawrow
        lda rc_x
        sta w16
        lda rc_x+1
        sta w16+1
        lda rc_y
        jsr ringaddr
        lda sp
        sta rc_sp
        lda sp+1
        sta rc_sp+1
@row:
        ; ---- tile row ty = rc_y >> 1 ; map row pointer from the level's row tables
        setbank BANK_MAP
        lda rc_y
        lsr
        tax
        lda LV_ROWPAGE,x
        beq :+
        lda #2
:       clc
        adc #>LV_PAGE0
        sta @pglo+2
        inca
        sta @pgbk+2
        lda LV_MAPROWLO,x
        sta ptr
        lda LV_MAPROWHI,x
        sta ptr+1
        lda rc_tx0
        clc
        adc ptr
        sta ptr                     ; ptr -> first tile of the row (so Y counts from 0)
        bcc :+
        inc ptr+1
:       ldy rc_nt
@gl:    lda (ptr),y
        tax
@pglo:  lda LV_PAGE0,x
        sta GATHERL,y
@pgbk:  lda LV_PAGE0+$100,x
        sta GATHERH,y
        dey
        bpl @gl
        ; ---- draw this char row, and (without re-gathering) the odd row of the same tile row
        jsr @drawrow
        inc rc_y
        dec rc_h
        beq @done
        lda rc_y
        and #1
        bne @second
        jmp @row
@second:
        jsr @drawrow
        inc rc_y
        dec rc_h
        beq @done
        jmp @row
@done:  rts
@drawrow:
        ; ---- screen base (per-rect ringaddr, +640 per row)
        lda rc_sp
        sta sp
        lda rc_sp+1
        sta sp+1
        ; a row spans <= 640 bytes: it can only cross $8000 if sp is within 768 of it
        cmp #$7D
        lda #0
        rol
        sta rc_wrap
        lda rc_y
        and #1
        beq :+
        lda #32
:       sta rc_sub
        ora rc_ro0
        sta rowoff
        lda rc_sc0
        sta rc_subc
        lda rc_w
        sta cnt
        stz rc_gi
@run:
        ldx rc_gi
        lda GATHERH,x               ; bit 6: solid cyan/black tile, filled not copied
        and #$40                    ; (bit abs,x would be 65C02 only)
        beq :+
        jmp @solid
:       lda GATHERL,x
        and #$0F                    ; bank rides in the low nibble of the pre-shifted lo byte
        cmp curbank
        beq :+
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
:       lda GATHERL,x
        and #$C0
        ora rowoff
        sta tp
        lda GATHERH,x
        sta tp+1
        ; chars in this run: min(4 - rc_subc, cnt) -> rc_n, X = 2*rc_n, tmp = 8*rc_n
        lda #4
        sec
        sbc rc_subc
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        asl
        tax
        asl
        asl
        sta tmp                     ; bytes
        ldy rc_wrap
        beq :+                      ; row cannot cross $8000: no per-run check needed
        adc sp                      ; C is clear: the asl's above shifted out zeros (rc_n <= 4)
        lda sp+1
        adc #0
        bpl :+
        jmp @slow
:       jmpx @jt-2
@jt:    .word @b7, @b15, @b23, @b31
        ; unrolled copy, one block per char in descending char order so that entry at
        ; char n-1 copies chars n-1..0.  A cell whose first byte has bit 7 set repeats
        ; lines 0..3 as 4..7 (flagged by convert.py): 4 loads, 8 stores.
.macro CPYN                         ; next line: A = (tp),y -> (sp),y ; y++
        lda (tp),y
        sta (sp),y
        iny
.endmacro
.macro CHARCPY c, per
.if c = 0
        ldaz tp                     ; line 0 non-indexed
        bmi per
        staz sp
        ldy #1
.else
        ldy #8*c
        lda (tp),y
        bmi per
        sta (sp),y
        iny
.endif
        CPYN
        CPYN
        CPYN
        CPYN
        CPYN
        CPYN
        lda (tp),y                  ; line 7
        sta (sp),y
.endmacro
.macro CHARPER c, next              ; A = line 0 (Y = 8c unless c = 0)
.if c = 0
        staz sp
.else
        sta (sp),y
.endif
        ldy #8*c+4
        sta (sp),y
        ldy #8*c+1
        lda (tp),y
        sta (sp),y
        ldy #8*c+5
        sta (sp),y
        ldy #8*c+2
        lda (tp),y
        sta (sp),y
        ldy #8*c+6
        sta (sp),y
        ldy #8*c+3
        lda (tp),y
        sta (sp),y
        ldy #8*c+7
        sta (sp),y
        jmp next
.endmacro
@t3:    jmp @p3                     ; the periodic blocks are out of branch range: trampolines
@t2:    jmp @p2
@b31:   CHARCPY 3, @t3
@b23:   CHARCPY 2, @t2
@b15:   CHARCPY 1, @t1
@b7:    CHARCPY 0, @t0
        jmp @advsp
@t1:    jmp @p1
@t0:    jmp @p0
@p3:    CHARPER 3, @b23
@p2:    CHARPER 2, @b15
@p1:    CHARPER 1, @b7
@p0:    CHARPER 0, @advsp
@advsp: lda sp
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
        lda rc_sub
        sta rowoff                  ; later tiles in the row start at column 0
        inc rc_gi
        jmp @run
@rowdone:
        lda rc_sp                   ; next char row: +640 with ring wrap
        clc
        adc #<640
        sta rc_sp
        lda rc_sp+1
        adc #>640
        bpl :+
        sec
        sbc #$50
:       sta rc_sp+1
        rts
        ; ---- solid tile: store one constant, no bank switch, no source pointer
@solid: lda GATHERL,x
        and #$10
        beq :+
        lda #$3C                    ; both pixels colour 6 (cyan); else 0 = black
:       sta tp                      ; fill value (tp is otherwise unused on this path)
        lda #4
        sec
        sbc rc_subc
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        asl
        tax
        asl
        asl
        sta tmp
        lda rc_wrap
        beq :+
        lda tmp
        adc sp
        lda sp+1
        adc #0
        bpl :+
        jmp @fslow
:       lda tp
        jmpx @ft-2
@ft:    .word @f7, @f15, @f23, @f31
.macro FIL1 k
        ldy #k
        sta (sp),y
.endmacro
.macro FILN                         ; next line down: y-- ; A -> (sp),y
        dey
        sta (sp),y
.endmacro
@f31:   FIL1 31
        FILN
        FILN
        FILN
        FILN
        FILN
        FILN
        FILN
@f23:   FIL1 23
        FILN
        FILN
        FILN
        FILN
        FILN
        FILN
        FILN
@f15:   FIL1 15
        FILN
        FILN
        FILN
        FILN
        FILN
        FILN
        FILN
@f7:    FIL1 7
        FILN
        FILN
        FILN
        FILN
        FILN
        FILN
        staz sp                     ; line 0 non-indexed
        jmp @advsp
@fslow: lda rc_n
        sta tmp2
@fsc:   lda tp
        ldy #7
:       sta (sp),y
        dey
        bpl :-
        spnext
        dec tmp2
        bne @fsc
        jmp @runend

; ============================================================================
; scroll_validate: make current buffer hold window (wcx, wcy) x 80 x 31
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
:       ; dx negative: draw cols wcx .. wcx+(-dx)-1, rows wcy..wcy+30
        eor #$FF                    ; (A still holds w16)
        inca
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        bra @docols
@dxpos: lda w16
        beq @dyc
        cmp #80
        bcs @full                   ; not taken: C = 0 for the adc
        ; dx positive: cols (oldcx+80) .. wcx+79 = dx cols starting at wcx+80-dx
        sta rc_w
        lda wcx
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
        inca
        sta rc_h
        lda wcy
        sta rc_y
        bra @dorows
@dypos: cmp #BUFROWS
        bcs @full                   ; not taken: C = 0 for the adc
        sta rc_h
        lda wcy
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
        lda sprmul5,x
        tax                         ; X = list offset, Y = offset into the record:
        lda SPRLIST,x               ; (rp),y -- NOT (rp,x), which indexes the pointer
        ldy #0                      ; itself and made every compare below read garbage
        cmp (rp),y
        beq @pos                    ; same sprite, same place: it redraws its own pixels
        ; two box-star frames of the same colour at the same place overwrite each
        ; other exactly, so they need no erase either
        jsr boxgrp
        beq @next
        sta tmp3
        ldaz rp
        jsr boxgrp
        cmp tmp3
        bne @next
@pos:   ldy #1
        lda SPRLIST+1,x
        cmp (rp),y
        bne @next
        iny
        lda SPRLIST+2,x
        cmp (rp),y
        bne @next
        iny
        lda SPRLIST+3,x
        cmp (rp),y
        bne @next
        iny
        lda SPRLIST+4,x
        cmp (rp),y
        bne @next
        ldx tmp4
        lda #1
        sta KEEP,x                  ; same pixels in the same place: skip the erase
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc tmp4
        bra @l
@done:  rts

; A = sprite id -> A = box-star group: 1 cyan (103..108), 2 black (109..114), else 0
boxgrp: sec
        sbc #103
        bcc @no
        cmp #12
        bcs @no
        cmp #6
        lda #1
        adc #0
        rts
@no:    lda #0
        rts

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
        ldy sprmul5,x
        tya
        tax                         ; X = list index, Y = record offset
        ldy #0
        lda SPRLIST,x
        sta (rp),y                  ; copy identity into record, clear rect
        iny
        lda SPRLIST+1,x
        sta spx
        sta (rp),y
        iny
        lda SPRLIST+2,x
        sta spx+1
        sta (rp),y
        iny
        lda SPRLIST+3,x
        sta spy
        sta (rp),y
        iny
        lda SPRLIST+4,x
        sta spy+1
        sta (rp),y
        ldy #8
        lda #0
        sta (rp),y
        lda SPRLIST,x
        jsr drawsprite
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc spi
        jmp @l
@done:  ldx curbuf
        lda NSPR
        sta RECCNT,x
        rts

; draw one sprite: A = id ; spx, spy = map px (ref point)
; A = sprite id. Game sprites (spbank = BANK_SPR): directory is in main RAM at
; SPR_TABLE; sprite data is in bank 4, or in ANDY ($8000, ROMSEL bit7) when the
; entry's flag bit2 is set. Title pieces (spbank != BANK_SPR): directory and data
; both live at TITLE_ADDR of that bank.
drawsprite:
        stz ptr+1
        asl                         ; id*8 -> offset
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        sta ptr
        lda spbank
        cmp #BANK_SPR
        bne @titledir
        ; ---- game: directory in main RAM (always visible), data in bank4/ANDY
        lda ptr
        clc
        adc #<SPR_TABLE
        sta ptr
        lda ptr+1
        adc #>SPR_TABLE
        sta ptr+1
        ldy #6
        lda (ptr),y
        sta sp_flags
        ldx #BANK_SPR
        and #4                      ; bit2 -> data in ANDY
        beq :+
        ldx #(BANK_SPR|$80)
:       lda sp_flags
        and #$10                    ; bit4 -> data above the tiles in bank 6 (box stars)
        beq :+
        ldx #BANK_TIL1
:       stx curbank
        stx ROMSEL_CPY
        stx ROMSEL
        bra @entry2
@titledir:
        ; ---- title piece: directory + data at TITLE_ADDR of bank(spbank)
        lda ptr+1
        clc
        adc #>TITLE_ADDR
        sta ptr+1
        lda spbank
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
        ldy #6
        lda (ptr),y
        sta sp_flags
@entry2:
        ldaz ptr
        sta sp_ptr
        ldy #1
        lda (ptr),y
        sta sp_ptr+1
        iny
        lda (ptr),y
        sta sp_w
        beq @out0
        ldy #7
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
        inca
        sta sp_c                    ; starting image column
        bra @vert
@cpos:  lda w16
        cmp #80
        bcs @out0                   ; not taken: C = 0 for the adc below
        sta sp_c0
        adc sp_w
        deca
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
        lda sp_r0
        bne @nopart
        ldx curbuf                  ; touches the window's top row (see drawrect)
        lda sp_c0
        cmp PART_LO,x
        bcs :+
        sta PART_LO,x
:       lda sp_c1
        cmp PART_HI,x
        bcc @nopart
        sta PART_HI,x
@nopart:
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
        inca
        sta (rp),y
        iny
        lda sp_r1
        sec
        sbc sp_r0
        inca
        sta (rp),y
        ; ---- column base pointer & step
        lda sp_flags
        and #1
        beq @nomirror
        ; mirror: image column = W-1-c (the column loop then steps backwards)
        lda sp_w
        deca
        sec
        sbc sp_c
        sta sp_c
@nomirror:
        ; ---- select the inner blitter once per sprite (patched jmp in the column loop)
        lda sp_flags
        and #8
        beq :+
        ldx #8                      ; bit3: copy blitter
        bne :++
:       lda sp_flags
        and #3
        asl
        tax
:       lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
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
        ; screen base for (wcx + c0, wcy + r0): one ringaddr, then +80 chars per row
        lda wcx
        clc
        adc sp_c0
        sta w16
        lda wcx+1
        adc #0
        sta w16+1
        lda wcy
        clc
        adc sp_r0
        jsr ringaddr
        lda sp
        sta sp_rb
        lda sp+1
        sta sp_rb+1
        ; source row pointer = column base + r0*8 - lb0 (>>1 for half res); +8 (+4) per row
        lda sp_r0
        asl
        asl
        asl
        sec
        sbc sp_lb0
        sta w16
        lda #0
        sbc sp_lb0+1
        sta w16+1
        lda #8
        sta sp_rinc
        lda sp_flags
        and #2
        bne :+
        lda w16+1
        cmp #$80
        ror w16+1
        ror w16
        lsr sp_rinc
:       lda sp_col
        clc
        adc w16
        sta sp_rp
        lda sp_col+1
        adc w16+1
        sta sp_rp+1
        lda sp_c1
        sec
        sbc sp_c0
        sta sp_ncol                 ; columns-1
ds_rowloop:
        lda sp_rb
        sta sp
        lda sp_rb+1
        sta sp+1
        lda sp_rp
        sta ptr
        lda sp_rp+1
        sta ptr+1
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
        lda sp_ncol
        sta sp_cnt                  ; columns-1 (countdown)
ds_colloop:
ds_dispatch:
        jmp sprFN                   ; operand patched per sprite
sprdisp_tab: .word sprHN, sprHM, sprFN, sprFM, sprFC
sprretM:                            ; next column, mirrored: source pointer - lines
        lda ptr
        sec
        sbc sp_lines
        sta ptr
        bcs sprnext
        dec ptr+1
        bra sprnext
sprretP:                            ; next column: source pointer + lines
        lda ptr
        clc
        adc sp_lines
        sta ptr
        bcc sprnext
        inc ptr+1
sprnext:
        spnext
        dec sp_cnt
        bpl ds_colloop
ds_rowdone:
        lda sp_row
        cmp sp_r1
        beq ds_done
        inc sp_row
        lda sp_rp
        clc
        adc sp_rinc
        sta sp_rp
        bcc :+
        inc sp_rp+1
:       lda sp_rb                   ; next char row: +640 with ring wrap
        clc
        adc #<640
        sta sp_rb
        lda sp_rb+1
        adc #>640
        bpl :+
        sec
        sbc #$50
:       sta sp_rb+1
        jmp ds_rowloop
ds_done: rts

; ---- inner blocks.  ptr = source column (already offset), sp = screen char,
;      tmp = ra0', tmp2 = ra1'.  Full-res: source byte per line.
.macro SPRLINE k, mirror, copy, solid, blank
        .local done, skip, opaque, masked
.if k = 0
        ldaz ptr                    ; line 0: Y is not needed here
.else
        ldy #k
        lda (ptr),y
.endif
.if copy
  .if k = 0
        staz sp                     ; box sprite: every byte opaque, plain copy
  .else
        sta (sp),y
  .endif
.else
        beq done                    ; 0: both pixels transparent, no store
  .if k = 0
        bpl masked                  ; (N from the load: cmp would set it from the subtraction)
        cmp #$C0
        bcc :+                      ; bit 7+6: this and the next 7 bytes all opaque
        jmp solid
:
        bra opaque
masked: cmp #$41                    ; and the mirror image of that: this and the next 7
        beq blank                   ; all transparent, so the cell is left alone
  .else
        bmi opaque                  ; bit 7: both pixels opaque (see encode_sprite)
  .endif
        tax
  .if mirror
        lda MASKTAB+$80,x           ; mask of the mirrored byte (MASKTAB[SWAPTAB[x]])
  .else
        lda MASKTAB,x
  .endif
  .if k = 0
        andz sp
  .else
        and (sp),y
  .endif
  .if mirror
        ora IDENT+$80,x             ; the mirrored byte's OR value (IDENT[SWAPTAB[x]])
  .else
        ora IDENT,x
  .endif
        bra skip
opaque:
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
skip:
  .if k = 0
        staz sp
  .else
        sta (sp),y
  .endif
done:
.endif
.endmacro

.macro SOLID1 k
        ldy #k
        lda (ptr),y
        sta (sp),y
.endmacro
.macro SOLIDM k                     ; mirrored: nibble swap through the table
.if k > 0
        ldy #k
        lda (ptr),y
.endif
        tax
        lda SWAPTAB,x
.if k = 0
        staz sp
.else
        sta (sp),y
.endif
.endmacro

.macro SPRFULL name, mirror, copy
        .local partial, et, l0, l1, l2, l3, l4, l5, l6, l7, pl, ps, po, pd, solid, blank
.if .not copy
solid:  ; byte 0 carried the RUN flag: the whole cell is opaque, straight copy
.if mirror
        SOLIDM 0
        SOLIDM 1
        SOLIDM 2
        SOLIDM 3
        SOLIDM 4
        SOLIDM 5
        SOLIDM 6
        SOLIDM 7
        jmp sprretM
.else
        staz sp                     ; A = byte 0
        SOLID1 1
        SOLID1 2
        SOLID1 3
        SOLID1 4
        SOLID1 5
        SOLID1 6
        SOLID1 7
        jmp sprretP
.endif
.endif
name:
        lda tmp2
        cmp #7
        beq :+
        jmp partial
:       lda tmp
        asl
        tax
        jmpx et
et:     .word l0,l1,l2,l3,l4,l5,l6,l7
.if .not copy
blank:  ; byte 0 was $41: the whole cell is transparent, so there is nothing to do
.if mirror
        jmp sprretM
.else
        jmp sprretP
.endif
.endif
l0:     SPRLINE 0, mirror, copy, solid, blank
l1:     SPRLINE 1, mirror, copy, solid, blank
l2:     SPRLINE 2, mirror, copy, solid, blank
l3:     SPRLINE 3, mirror, copy, solid, blank
l4:     SPRLINE 4, mirror, copy, solid, blank
l5:     SPRLINE 5, mirror, copy, solid, blank
l6:     SPRLINE 6, mirror, copy, solid, blank
l7:     SPRLINE 7, mirror, copy, solid, blank
        .if mirror
        jmp sprretM
        .else
        jmp sprretP
        .endif
partial:
        ldy tmp
.if copy
pl:     lda (ptr),y
        sta (sp),y
.else
pl:     lda (ptr),y
        beq ps
        bmi po                      ; both pixels opaque
        tax
.if mirror
        lda MASKTAB+$80,x
        and (sp),y
        ora IDENT+$80,x
.else
        lda MASKTAB,x
        and (sp),y
        ora IDENT,x
.endif
        sta (sp),y
        bra ps
po:
.if mirror
        tax
        lda SWAPTAB,x
.endif
        sta (sp),y
.endif
ps:     cpy tmp2
        beq pd
        iny
        bra pl
pd:
        .if mirror
        jmp sprretM
        .else
        jmp sprretP
        .endif
.endmacro

        SPRFULL sprFN, 0, 0
        SPRFULL sprFM, 1, 0
        SPRFULL sprFC, 0, 1         ; box stars: pre-composited on their background, no mask

; half res: one source byte -> two screen lines (2k, 2k+1)
.macro SPRLINE2 k, mirror
        .local skip, opaque, both, store
.if k = 0
        ldaz ptr
.else
        ldy #k
        lda (ptr),y
.endif
        beq skip
        bmi both                    ; bit 7: both pixels opaque
        tax
.if mirror
        lda MASKTAB+$80,x
.else
        lda MASKTAB,x
.endif
        beq opaque
        sta tmp4
.if mirror
        lda IDENT+$80,x
        sta tmp3
.else
        stx tmp3
.endif
.if k = 0
        ldaz sp
        and tmp4
        ora tmp3
        staz sp
        ldy #1
.else
        ldy #2*k
        lda (sp),y
        and tmp4
        ora tmp3
        sta (sp),y
        iny
.endif
        lda (sp),y
        and tmp4
        ora tmp3
        sta (sp),y
        bra skip
both:
.if mirror
        tax
        lda SWAPTAB,x
.endif
        bra store
opaque:
.if mirror
        lda SWAPTAB,x
.else
        txa
.endif
store:
.if k = 0
        staz sp
        ldy #1
.else
        ldy #2*k
        sta (sp),y
        iny
.endif
        sta (sp),y
skip:
.endmacro

.macro SPRHALF name, mirror
        .local partial, et, l0, l1, l2, l3, pl, ps, po, pb, pq, pd
name:
        lda tmp2
        cmp #7
        beq :+
        jmp partial
:       lda tmp                     ; even 0,2,4,6 -> entry 0..3
        tax
        jmpx et
et:     .word l0,l1,l2,l3
l0:     SPRLINE2 0, mirror
l1:     SPRLINE2 1, mirror
l2:     SPRLINE2 2, mirror
l3:     SPRLINE2 3, mirror
        .if mirror
        jmp sprretM
        .else
        jmp sprretP
        .endif
partial:
        lda tmp
        sta sp_lim                  ; current screen line (even)
pl:     lda sp_lim
        lsr
        tay
        lda (ptr),y
        beq ps
        bmi pb                      ; bit 7: both pixels opaque
        tax
.if mirror
        lda MASKTAB+$80,x
.else
        lda MASKTAB,x
.endif
        beq po
        sta tmp4
.if mirror
        lda IDENT+$80,x
        sta tmp3
.else
        stx tmp3
.endif
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
pb:
.if mirror
        tax
        lda SWAPTAB,x
.endif
        bra pq
po:
.if mirror
        lda SWAPTAB,x
.else
        txa
.endif
pq:     ldy sp_lim
        sta (sp),y
        iny
        sta (sp),y
ps:     lda sp_lim
        inca
        cmp tmp2
        bcs pd
        inc sp_lim
        inc sp_lim
        bra pl
pd:
        .if mirror
        jmp sprretM
        .else
        jmp sprretP
        .endif
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
:       ldx curbuf
        cmp PART_F,x
        bne @all
        lda wcy
        cmp PART_CY,x
        bne @all
        ; same source row and lines as last time: only the columns drawn since
        lda PART_HI,x
        cmp #80
        bcc :+
        lda #79
:       sec
        sbc PART_LO,x
        bcs :+
        rts                         ; nothing drawn in the top row
:       inca
        sta cnt
        lda PART_LO,x
        bra @go
@all:   lda wfine
        sta PART_F,x
        lda wcy
        sta PART_CY,x
        lda #80
        sta cnt
        lda #0
@go:    tay                         ; range is clean once copied
        lda #$FF
        sta PART_LO,x
        lda #0
        sta PART_HI,x
        tya
        clc
        adc wcx
        sta w16
        lda wcx+1
        adc #0
        sta w16+1
        lda wcy
        jsr ringaddr                ; sp = source start (row wcy, first dirty column)
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
:       ; start at line wfine: patched jmp into the unrolled 6-line copy
        lda wfine
        lsr
        deca                         ; 2,4,6 -> 0,1,2
        asl
        tax
        lda @ftab,x
        sta @fjmp+1
        lda @ftab+1,x
        sta @fjmp+2
@fjmp:  jmp @g2                     ; operand patched: @g2/@g4/@g6
@ftab:  .word @g2, @g4, @g6
@g2:    ldy #2
        lda (sp),y
        sta (ptr),y
        iny
        lda (sp),y
        sta (ptr),y
        iny
@g4:    ldy #4
        lda (sp),y
        sta (ptr),y
        iny
        lda (sp),y
        sta (ptr),y
        iny
@g6:    ldy #6
        lda (sp),y
        sta (ptr),y
        iny
        lda (sp),y
        sta (ptr),y
        ; next char: source with ring wrap; dest wraps on its REAL address (ptr + wfine),
        ; which only needs the full check in the last page before $8000
        spnext
        lda ptr
        clc
        adc #8
        sta ptr
        bcc :+
        inc ptr+1
:       lda ptr+1
        cmp #$7F
        bcc :+
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
        jmp @fjmp
@done:  rts

; ============================================================================
; calc_ring: ringS = ((wcy & 31) * 80 + wcx) mod 2560 ; barq = ringS / 80
; ============================================================================
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
        tax                         ; ring row for bar row 0
        stx tmp2                    ; (X is used as the byte index inside @row)
        lda #BANK_SPR
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
        lda #<BARBUF
        sta w16
        lda #>BARBUF
        sta w16+1
        jsr @row
        ldx tmp2
        inx
        txa
        and #31
        tax
        lda w16
        clc
        adc #<640
        sta w16
        lda w16+1
        adc #>640
        sta w16+1
@row:   ; one 640-byte ring row: src = w16, dst = RING[x]; 8x unrolled abs,x copy
        lda RINGLO,x
        sta w16b
        lda RINGHI,x
        sta w16b+1
        lda w16
        clc
        adc #0
        sta @s0+1
        lda w16+1
        adc #0
        sta @s0+2
        lda w16b
        clc
        adc #0
        sta @d0+1
        lda w16b+1
        adc #0
        sta @d0+2
        lda w16
        clc
        adc #1
        sta @s1+1
        lda w16+1
        adc #0
        sta @s1+2
        lda w16b
        clc
        adc #1
        sta @d1+1
        lda w16b+1
        adc #0
        sta @d1+2
        lda w16
        clc
        adc #2
        sta @s2+1
        lda w16+1
        adc #0
        sta @s2+2
        lda w16b
        clc
        adc #2
        sta @d2+1
        lda w16b+1
        adc #0
        sta @d2+2
        lda w16
        clc
        adc #3
        sta @s3+1
        lda w16+1
        adc #0
        sta @s3+2
        lda w16b
        clc
        adc #3
        sta @d3+1
        lda w16b+1
        adc #0
        sta @d3+2
        lda w16
        clc
        adc #4
        sta @s4+1
        lda w16+1
        adc #0
        sta @s4+2
        lda w16b
        clc
        adc #4
        sta @d4+1
        lda w16b+1
        adc #0
        sta @d4+2
        lda w16
        clc
        adc #5
        sta @s5+1
        lda w16+1
        adc #0
        sta @s5+2
        lda w16b
        clc
        adc #5
        sta @d5+1
        lda w16b+1
        adc #0
        sta @d5+2
        lda w16
        clc
        adc #6
        sta @s6+1
        lda w16+1
        adc #0
        sta @s6+2
        lda w16b
        clc
        adc #6
        sta @d6+1
        lda w16b+1
        adc #0
        sta @d6+2
        lda w16
        clc
        adc #7
        sta @s7+1
        lda w16+1
        adc #0
        sta @s7+2
        lda w16b
        clc
        adc #7
        sta @d7+1
        lda w16b+1
        adc #0
        sta @d7+2
        lda #32
        sta cnt
        jsr @chunk                  ; bytes 0..255
        inc @s0+2
        inc @d0+2
        inc @s1+2
        inc @d1+2
        inc @s2+2
        inc @d2+2
        inc @s3+2
        inc @d3+2
        inc @s4+2
        inc @d4+2
        inc @s5+2
        inc @d5+2
        inc @s6+2
        inc @d6+2
        inc @s7+2
        inc @d7+2
        lda #32
        sta cnt
        jsr @chunk                  ; bytes 256..511
        inc @s0+2
        inc @d0+2
        inc @s1+2
        inc @d1+2
        inc @s2+2
        inc @d2+2
        inc @s3+2
        inc @d3+2
        inc @s4+2
        inc @d4+2
        inc @s5+2
        inc @d5+2
        inc @s6+2
        inc @d6+2
        inc @s7+2
        inc @d7+2
        lda #16
        sta cnt                     ; bytes 512..639
@chunk: ldx #0
@cp:
@s0:   lda $FFFF,x
@d0:   sta $FFFF,x
@s1:   lda $FFFF,x
@d1:   sta $FFFF,x
@s2:   lda $FFFF,x
@d2:   sta $FFFF,x
@s3:   lda $FFFF,x
@d3:   sta $FFFF,x
@s4:   lda $FFFF,x
@d4:   sta $FFFF,x
@s5:   lda $FFFF,x
@d5:   sta $FFFF,x
@s6:   lda $FFFF,x
@d6:   sta $FFFF,x
@s7:   lda $FFFF,x
@d7:   sta $FFFF,x
        txa
        clc
        adc #8
        tax
        dec cnt
        bne @cp
        rts

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
        ; remember this buffer's bar CRTC start so the ISR can program R12/R13 for
        ; the DISPLAYED buffer each frame (the CRTC carryover is a frame/buffer behind)
        lda curbuf
        asl
        tax
        lda w16b+1
        sta BUF_BARADDR,x
        lda w16b
        sta BUF_BARADDR+1,x
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
        ; P.  Q starts at the row below the playfield (S + 27*80), not the bar: the 6845
        ; always displays the first scanline of a frame even with R6 = 0, so whatever Q
        ; starts at leaks one line onto the bottom of the screen (the vsync ISR sets the
        ; bar address for T anyway)
        lda w16
        clc
        adc #<(VISROWS*80)
        sta w16
        lda w16+1
        adc #>(VISROWS*80)
        cmp #$10
        bcc :+
        sbc #$0A                    ; ring wrap ($600..$FFF)
:       sta w16+1
        sta SECTAB+8,x
        lda w16
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
        inca                         ; 8-f
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
        ; P2 (partial bottom row): the row below the visible playfield, top f lines.
        ; w16 currently = S + 27*80 (advanced through P1); use it rather than the bar.
        lda w16+1
        sta SECTAB+24,x
        lda w16
        sta SECTAB+25,x
        lda #0
        sta SECTAB+26,x
        lda wfine
        deca
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
@dur:   stza tmp3
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
        bcc :+                      ; not taken: C = 1 for the sbc
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
        jsr wait_flip               ; the previous frame's flip must land before we
        jsr select_backbuf          ; draw into the buffer it is leaving
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
        lda wy+1                    ; wcy = wy >> 2, a full 16-bit shift: shifting the
        lsr                         ; high byte once only was right below wy = 512 and
        sta wcy                     ; lost 128 rows above it, which put the tall maps
        lda wy                      ; 512 px out of place once the player got that deep
        ror
        lsr wcy
        ror
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
render_done:                        ; (label for the phase timer harness)
        ; no wait here: the next logic step runs while the flip is pending and
        ; the next render_frame waits for it before touching the buffer
        lda curbuf
        eor #1
        sta curbuf
        rts

; spin until any pending flip has been taken by the vsync ISR
wait_flip:
        lda flipreq
        bne wait_flip
        rts


        .segment "LOW"             ; render-time helpers in the NMI page ($0D03..),
                                   ; copied there at init
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
        bcs @none                   ; not taken: C = 0 for the adc
        adc rc_w
        cmp #81
        bcc :+                      ; not taken: C = 1 for the sbc
        lda #80
        sbc w16
        sta rc_w
:       jmp drawrect
@none:  rts
; ============================================================================
; drawrect_clip: like drawrect but clips the rect to the current window
; (rows wcy..wcy+30, cols wcx..wcx+79).
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

        .segment "LOW2"            ; MOS vector/VDU pages ($0206..$03FF), copied there after MODE 2:
                                   ; init-only table builders and the dirty-tile routines

; ============================================================================
; table init
; ============================================================================
        .segment "LOGIC"            ; cold, and main RAM under the screen is full
init_tables:
        jsr init_ident
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
        ; sprite encoding (convert.py encode_sprite): bit 7 = both pixels opaque and never
        ; reaches the tables; left-black-only is code $44 (its $80 slot is taken)
        lda #$55
        sta MASKTAB+$44             ; keep the right screen pixel
        stz IDENT+$44               ; left pixel black
        lda #$44
        sta SWAPTAB+$40             ; right-black-only <-> left-black-only
        lda #$40
        sta SWAPTAB+$44
        lda #$FF                    ; $41 marks eight transparent bytes; if it reaches
        sta MASKTAB+$41             ; the tables (a clipped cell, or as a line 1..7)
        stz IDENT+$41               ; it must leave the screen byte alone.  $82 is its
        sta MASKTAB+$82             ; mirror image, and unreachable otherwise
        stz IDENT+$82
        ; MASKTAB+$80..: the mask of the mirrored byte, so the mirrored blitters do one
        ; lookup instead of SWAPTAB then MASKTAB (only codes < $80 are ever looked up)
        ldx #0
:       ldy SWAPTAB,x
        lda MASKTAB,y
        sta MASKTAB+$80,x
        lda IDENT,y
        sta IDENT+$80,x             ; and its OR value (differs from SWAPTAB only at \$40)
        inx
        bpl :-
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


; identity table for the sprite blitter (A | X without a temp store)
init_ident:
        ldx #0
:       txa
        sta IDENT,x
        inx
        bne :-
        rts
        .segment "LOW2"             ; back to the render helpers


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

        .segment "CODE"

; ============================================================================
; IRQ handling
; ============================================================================
irq_handler:
        stx irq_x
        sty irq_y
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
        sta curR7                   ; the vsync handler re-phases the frame from this
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
        ; next entry; the chain stops at Q (the only entry with R6 = 0): a late vsync
        ; must not walk the chain off the end of SECTAB
        lda SECTAB+4,x
        beq @stay
        txa
        clc
        adc #8
        tax
@stay:  stx SECIDX
        jmp @exit
@notT1:
        lda VIA_IFR
        and #$02
        bne :+
        jmp @exit
:       ; ---- vsync: restart T1 first (constant latency), counter = vsync->T, latch = T duration
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
        ; re-phase: the vsync fired at row curR7, so end this frame at row curR7+5 with
        ; 8-line rows -> T starts exactly 48 lines after the vsync even if the CRTC row
        ; counter had run past its vertical total (which otherwise never recovers)
        lda #9
        sta CRTC_IDX
        lda #7
        sta CRTC_DAT
        lda #4
        sta CRTC_IDX
        lda curR7
        clc
        adc #QROWS-1-QVSYNC
        and #$7F
        sta CRTC_DAT
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
        ; program the bar CRTC start for the buffer about to display, so the bar
        ; never shows the other buffer's leftover address during vertical scroll
        ldx #0
        lda DISPSECT
        beq :+
        ldx #2
:       lda #12
        sta CRTC_IDX
        lda BUF_BARADDR,x
        sta CRTC_DAT
        lda #13
        sta CRTC_IDX
        lda BUF_BARADDR+1,x
        sta CRTC_DAT
        jsr scan_keys
        jsr sound_tick
@exit:
        ldy irq_y
        ldx irq_x
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

; ---------------------------------------------------------------- music
; 144-byte period table then the sequence (4-byte records: frames, note0..2;
; frames = 0 -> loop).  It used to be hidden in bit 6 of the tile bytes, which only
; worked while the whole tile set was resident; a level now loads just the tiles it
; uses, so the music is its own file in bank 6.
MUSIC_ADDR = $B800                  ; bank 6, above the box stars
MUSIC_SEQ  = MUSIC_ADDR + 144
MUSIC_TAB  = music_tab              ; 72 x 2 byte periods (MIDI 24..95), decoded into RAM
; decode the period table (the first 144 hidden bytes) into music_tab; bank 5 loaded
music_init:
        lda #BANK_TIL1
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
        ldx #0
:       lda MUSIC_ADDR,x
        sta music_tab,x
        inx
        cpx #144
        bne :-
        rts
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
        jsr musbyte
        bne :+
        lda #<MUSIC_SEQ
        sta MUSPTR
        lda #>MUSIC_SEQ
        sta MUSPTR+1
        jsr musbyte
:       sta MUSDUR
        ldx #0
@v:     jsr musbyte
        cmp MUSNOTE,x
        beq :+
        sta MUSNOTE,x
        jsr set_voice
:       inx
        cpx #3
        bne @v
        pla
        sta ROMSEL_CPY
        sta ROMSEL
@done:  rts

; A = next music byte; MUSPTR += 1.  Preserves X.  Z reflects A.  Bank 6 selected.
musbyte:
        ldaz MUSPTR
        inc MUSPTR
        bne :+
        inc MUSPTR+1
:       cmp #0
        rts


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
        lda crtctab+7
        sta curR7
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
        tax
        lda ft_seclo,x
        sta ld_sec
        lda ft_sechi,x
        sta ld_sec+1
        lda ft_n,x
        sta ld_n
        lda ft_bank,x
        beq :+
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
:       lda ft_dest,x
        sta ptr+1
        stz ptr
        ; read ld_n sectors from linear sector ld_sec to ptr
ldread:
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

        .segment "LOW2"             ; main RAM under the screen is full; the old MOS
; ============================================================================
; Map access for the logic, which lives in bank 7 and so cannot select bank 6
; itself.  Each of these leaves bank 7 selected, so the logic calls them directly.
; ============================================================================
; A = tile row -> q1 = page, mapptr = address of that map row
maprow: tay
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        lda LV_ROWPAGE,y
        sta q1
        lda LV_MAPROWLO,y
        sta mapptr
        lda LV_MAPROWHI,y
        sta mapptr+1
        jmp pagelogic

; A = (mapptr),y ; Y preserved
mapbyte:
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        lda (mapptr),y
        jmp pagelogic

; store A at (mapptr),y ; Y preserved
mapput: pha
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        pla
        sta (mapptr),y
        jmp pagelogic

; the level's map row address table, from maplw (level_init's first job)
init_maprows:
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        stz t16
        lda #>LV_MAP
        sta t16+1
        stz t16b                    ; row stride = 1 << maplw bytes
        stz t16b+1
        lda maplw
        cmp #8
        beq :++
        lda #1
        ldx maplw
:       asl
        dex
        bne :-
        sta t16b
        bra :++
:       lda #1
        sta t16b+1
:       ldx #0
:       lda t16
        sta LV_MAPROWLO,x
        lda t16+1
        sta LV_MAPROWHI,x
        lda t16
        clc
        adc t16b
        sta t16
        lda t16+1
        adc t16b+1
        sta t16+1
        inx
        bne :-
        jmp pagelogic

; the page tables, into the screen: level_init needs them and the alt classes at once
copy_pages:
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        ldx #0
:       lda LV_PAGE0,x
        sta PGCOPY,x
        lda LV_PAGE0+256,x
        sta PGCOPY+256,x
        lda LV_PAGE1,x
        sta PGCOPY+512,x
        lda LV_PAGE1+256,x
        sta PGCOPY+768,x
        inx
        bne :-
        jmp pagelogic

; one font glyph out of bank 4, for the menus
getglyph:
        lda #BANK_SPR
        sta ROMSEL_CPY
        sta ROMSEL
        ldy #7
:       lda (w16b),y
        sta GLYPHBUF,y
        dey
        bpl :-
        jmp pagelogic
        .segment "CODE"

; ---------------------------------------------------------------- level tiles
; A level uses only part of the tile set, so the banks hold only what it asks for.
; LV_HDR+32 carries one bit per tile of the global set, MSB first, and the tiles a
; level wants keep their relative order, so copying them out in order gives exactly
; the numbering its page tables use.  TILES is read a track at a time into the
; screen, which is blanked for the whole of a level load.
TBUF     = SCREEN                   ; 2560 bytes: one track
TILEBITS = (NTILES_DATA + 7) / 8
load_tiles:
        jsr music_stop
        setbank BANK_LVL            ; the bitmap must come out of bank 7 first: a tile
        ldx #0                      ; bank is selected throughout the copy below
:       lda LV_HDR+32,x
        sta SPRREC,x
        inx
        cpx #TILEBITS
        bne :-
        lda #BANK_TIL0              ; destination: bank 5, then bank 6
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
        stz tp
        lda #$80
        sta tp+1
        stz tmp3                    ; bitmap byte index
        lda #$80
        sta w16b                    ; bit mask
        lda #<F_TILES_SEC
        sta w16
        lda #>F_TILES_SEC
        sta w16+1
        lda #F_TILES_N
        sta tmp4                    ; sectors still to read
        lda #(10 - (F_TILES_SEC .mod 10))
        bne @first                  ; chunks stop at the track boundary, or a read
@chunk: lda #10                     ; that straddles one costs a whole extra revolution
@first: sta cnt
        lda tmp4
        bne :+
        rts
:       cmp cnt
        bcs :+
        sta cnt
:       lda w16
        sta ld_sec
        lda w16+1
        sta ld_sec+1
        lda cnt
        sta ld_n
        stz ptr
        lda #>TBUF
        sta ptr+1
        jsr ldread
        lda w16                     ; on to the next chunk
        clc
        adc cnt
        sta w16
        bcc :+
        inc w16+1
:       lda tmp4
        sec
        sbc cnt
        sta tmp4
        lda cnt                     ; four tiles to a sector
        asl
        asl
        sta tmp2
        stz ptr
        lda #>TBUF
        sta ptr+1
        lda curbank
        sta ROMSEL_CPY
        sta ROMSEL
@tile:  ldx tmp3
        lda SPRREC,x
        and w16b
        beq @skip
        ldy #63
:       lda (ptr),y
        sta (tp),y
        dey
        bpl :-
        lda tp                      ; 64 on, and into bank 6 past the end of bank 5
        clc
        adc #64
        sta tp
        bcc @skip
        inc tp+1
        lda tp+1
        cmp #$C0
        bne @skip
        lda #BANK_TIL1
        sta curbank
        sta ROMSEL_CPY
        sta ROMSEL
        lda #$80
        sta tp+1
@skip:  lda ptr
        clc
        adc #64
        sta ptr
        bcc :+
        inc ptr+1
:       lsr w16b                    ; next bit, and next byte every eighth tile
        bne :+
        lda #$80
        sta w16b
        inc tmp3
:       dec tmp2
        beq :+
        jmp @tile
:       jmp @chunk

; sign extend A -> tmp3 (0 or $FF).  In LOW2 (the old MOS vector page) because main
; RAM below the screen is full: there is room to spare there.
        .segment "LOW2"
sext:   and #$80
        beq :+
        lda #$FF
:       sta tmp3
        rts

; ============================================================================
; Bridges between main RAM and the game logic, which lives at $8900 in bank 7
; because a Model B has no HAZEL to put it in.  t_ goes in, m_ comes back out:
; both leave bank 7 selected on return, so a tail jump through one is as good as
; a call.  pagelogic is the whole of the bank switch and the return path of m_.
; ============================================================================
pagelogic:                          ; A, X, Y and the carry all come through intact:
        pha                         ; these sit in the middle of calls that return values
        lda #BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        pla
        rts
.macro TOBANK n
.ident(.concat("t_", n)):
        jsr pagelogic
        jmp .ident(n)
.endmacro
.macro TOMAIN n
.ident(.concat("m_", n)):
        jsr .ident(n)
        jmp pagelogic
.endmacro
        TOBANK "init_tables"
        TOBANK "draw_health"
        TOBANK "draw_lives"
        TOBANK "draw_score"
        TOBANK "draw_stars"
        TOBANK "game_frame"
        TOBANK "help_screen"
        TOBANK "level_init"
        TOBANK "level_select"
        TOBANK "pause_menu"
        TOBANK "title_menu"
        TOBANK "winlose"
        TOMAIN "addsprite"
        TOMAIN "blank_palette"
        TOMAIN "build_sections"
        TOMAIN "calc_ring"
        TOMAIN "clamp_window"
        TOMAIN "drawsprite"
        TOMAIN "loadfile"
        TOMAIN "mark_dirty"

        .segment "LOW"              ; and the tail of the NMI page, below the MOS's bytes
        TOMAIN "music_start"
        TOMAIN "music_stop"
        TOMAIN "ringaddr"
        TOMAIN "rnd"

        .segment "CODE"
        TOMAIN "select_backbuf"
        TOMAIN "set_palette"
        TOMAIN "wait_flip"

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
