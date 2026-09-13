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
BANK_TILES= 5                     ; every level's tile data now fits one bank
BANK_LVL  = 7
BANK_MAP  = 6                     ; the map and the tables read alongside it

; bank 6: this level's overflow tiles, then the map and everything the renderer or
; the logic reads in the same breath as the map.  It is here rather than in bank 7
; because the game logic took that bank: the Model B it was written for had no
; HAZEL, and the map was the only thing big enough to make the room.  A Master
; does have HAZEL, so that placement is now a free choice rather than a forced
; one -- moving the logic there would hand bank 7 back.
;         $8000  tiles 256.. of this level (16 tiles: no level needs more)
LV_PAGE0  = $8500                 ; tile id -> tile data address: 256 lo ((id&3)<<6),
                                  ; 256 hi ($80 | id>>2).  A map byte is a tile id, so
                                  ; this is the whole translation -- and it is the same
                                  ; for every level and both sets, so build_tileaddr
                                  ; writes it once instead of every level shipping one.
LV_MAP    = $8900                 ; up to 8K, row major
;         $A900  LV_MAPROWLO, LV_MAPROWHI (built by level_init, see logic.s)
;         $B000  box stars, $B800 music

; bank 7
LOGIC_ADDR= $8900                 ; the game logic and menus: bank 7, above the tables
LV_HDR    = $8000
LV_OBJS   = $8100
LV_ATTR0  = $8500                 ; attribute (kill/push) by tile id
LV_ATTR1  = $8600
LV_ALTCLS = $8600                 ; 256 : tile id -> alt class (the map byte is
                                  ; the id, so the logic indexes this directly)
;         $8900..$AFFF free: the game logic lives here
LV_OBJST  = $B000                 ; object state arrays (16 x 149)
LV_GRID   = $B950                 ; 128 grid heads
LV_BOBJ   = $B9D0                 ; 255
LV_BNEXT  = $BAD0                 ; 255
;         $BC00  free (was LV_ALTPAGE, built per level; the map byte is the tile id now)
LV_ALTTAB = $BE00                 ; classes x 8 (global: loaded once)

; ---------------------------------------------------------------- screen shape
; Each buffer gets its own 20K screen, main and shadow, so both are an 80-char
; ring at $3000 with 27 rows visible and the status bar above.
ROWCHARS  = 80
RINGROWS  = 28                    ; playfield rows only: the bar, the partial-row source
VISROWS   = 27                    ; visible char rows (216 lines = 108 game px)
BUFROWS   = 28                    ; rows held (visible + partial top row source)
; The camera follows Cleo one for one, so her fall speed is also how far the window
; moves in a frame.  A char row is four map pixels.  Main and shadow are separate,
; so nothing in the layout forces a limit; this one is a play decision.
MAXDWY    = 8
BUF0      = $3000
ROWBYTES  = ROWCHARS*8
RINGCHARS = ROWCHARS*RINGROWS
RINGBYTES = RINGCHARS*8
; Three rows come out of the ring so the status bar can stop chasing it:
;   $3000  the row copy_partial fills with the window's top slice
;   $3280  a copy of the ring's last 80 chars, immediately before the ring, so a row
;          that straddles the ring end can still be read as one run
;   $3500  the ring, 28 rows -- both ends page aligned, so ringup stays a byte compare
;   $7B00  the bar
PARTADDR  = BUF0
MIRROR    = PARTADDR + ROWBYTES
RINGBASE  = MIRROR + ROWBYTES
BARADDR   = RINGBASE + RINGBYTES
RINGEND   = RINGBASE + RINGBYTES
CRTCBASE  = RINGBASE / 8          ; the CRTC counts characters, so the ring starts here
WINPX     = ROWCHARS*2            ; window width in pixels
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
tset:     .res 1                  ; tile set in bank 5 ($FF = none yet)
tchar:    .res 1                  ; drawtext's place in the string
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
RINGLO:    .res RINGROWS          ; ring row r -> screen address
RINGHI:    .res RINGROWS
GATHERL:   .res 24                ; per-row tile gather: tile address lo | bank (low nibble)
GATHERH:   .res 24                ;                       tile address hi
SECTAB:    .res 2*48              ; per buffer: 6 sections x 8 bytes
SPRLIST:   .res 5*MAXSPR          ; sprite draw list: id, xlo, xhi, ylo, yhi
SPRREC:    .res 2*MAXREC*10       ; per buffer drawn-sprite records: id,xl,xh,yl,yh, cxl,cxh,cy,w,h
GLYPHBUF:  .res 8                 ; one font glyph, copied out of bank 4 for the menus
RECCNT:    .res 2
KEEP:      .res MAXREC
dpass:     .res 1                 ; draw_sprites pass: 1 = box stars, 0 = the rest
MIRR_R:    .res 2                 ; per buffer: the mirror is valid from this char on
MIRR_LO:   .res 2                 ; the address of that char in the ring's last row
spclip:    .res 1                 ; drawsprite: the last sprite came off a window edge
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
PART_CXL:  .res 2                 ; per buffer: the window column it was last copied for (16 bit):
PART_CXH:  .res 2                 ;   a horizontal scroll shifts every column, not just dirty ones
PART_LO:   .res 2                 ; per buffer: window columns of row wcy drawn since that copy
PART_HI:   .res 2                 ;   (LO > HI = none)
BUF_BARQ:  .res 2
BUF_SEC0:  .res 4              ; per buffer: CRTC start of the frame's first section
BUF_SEC0T1: .res 4             ;   and how long it lasts (the vsync handler needs both)
BARDIRTY:  .res 2
BARBG:     .res 2                 ; per buffer: its bar needs the static template blitted
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
; ---------------------------------------------------------------- ring wrapping
; A screen address that runs off the end of the buffer folds back to its start.
; The buffer is the whole 20K and the test is the sign bit.
; These spell their skip with an anonymous label, so a caller that wants to branch
; over one has to count it: see spnext, which says :++ for that reason.  A named
; label here would end the enclosing routine's cheap-local scope.
.macro ringmod                      ; A = a map char row -> its ring slot
.if (RINGROWS & (RINGROWS - 1)) = 0
        and #(RINGROWS-1)
.else
        tax
        lda ringmodtab,x
.endif
.endmacro
; Both ends of the ring are page boundaries, so the fold is a compare on the high
; byte alone.  A = high byte after moving forward, folded back into the ring.
;
; Two spellings, by what the caller's carry is known to be: the sites reached
; through a bcc from an eight-bit add that carried arrive with it set, the ones
; reached from an adc that cannot overflow arrive with it clear.  Either way the
; cmp sets the carry before the sbc, so neither has to pay for a sec and the two
; are currently the same three instructions -- the names are the caller's contract,
; and they earn their keep the moment the fold stops being a compare (a ring ending
; at $8000 would test the sign bit instead, which leaves the carry alone, and then
; the clear form has to subtract one less and let the missing borrow make it up).
.macro ringup_cs                    ; carry known set
        cmp #>RINGEND
        bcc :+
        sbc #>RINGBYTES
:
.endmacro
.macro ringup_cc                    ; carry known clear
        cmp #>RINGEND
        bcc :+
        sbc #>RINGBYTES             ; the cmp has already set it
:
.endmacro
.macro ringdn                       ; A = high byte after moving back
        cmp #>RINGBASE
        bcs :+
        adc #>RINGBYTES
:
.endmacro

.macro spnext
        lda sp
        clc
        adc #8
        sta sp
        bcc :++                     ; past the fold's own anonymous label
        inc sp+1
        lda sp+1
        ringup_cs
        sta sp+1
:
.endmacro

; ============================================================================
; ringaddr: screen address of map char (w16 = cx 16 bit, A = cy) -> sp
; ============================================================================
ringaddr:
        ringmod
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
        ringup_cc
        sta sp+1
        rts

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
        lda rc_w
        deca
        clc
        adc rc_x
        sta w16
        lda rc_x+1
        adc #0
        lsr a
        ror w16
        lsr a
        ror w16                     ; w16 = tx1
        sta w16+1
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
        lda LV_PAGE0,x
        sta GATHERL,y
        lda LV_PAGE0+$100,x
        sta GATHERH,y
        dey
        bpl @gl
        setbank BANK_TILES          ; gather done (it read bank 6); the tiles all live in
                                    ; bank 5, so switch once here, not per tile in @run
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
        ; a row spans <= 640 bytes: it can only cross the ring end if sp is within 768
        cmp #(>RINGEND - 3)
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
:       lda GATHERL,x               ; every tile is in bank 5, selected once per tile row
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
        beq :+                      ; row cannot cross the ring end: no per-run check
        adc sp                      ; C is clear: the asl's above shifted out zeros (rc_n <= 4)
        lda sp+1
        adc #0
        cmp #>RINGEND
        bcc :+
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
        bcc :++                     ; past the fold's own anonymous label
        inc sp+1
        lda sp+1
        ringup_cs
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
        lda rc_sp+1                 ; a row is 640 bytes: only one starting in the last
        cmp #(>RINGEND - 5)         ; 1280 can reach the mirror's source row
        bcc :+
        lda rc_sp
        ldy rc_sp+1
        ldx rc_w
        jsr mirror_run
:
        lda rc_sp                   ; next char row: +640 with ring wrap
        clc
        adc #<ROWBYTES
        sta rc_sp
        lda rc_sp+1
        adc #>ROWBYTES
        ringup_cc
        sta rc_sp+1
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
        cmp #>RINGEND
        bcc :+
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
        cmp #ROWCHARS
        bcs @full                   ; not taken: C = 0 for the adc
        ; dx positive: cols (oldcx+80) .. wcx+79 = dx cols starting at wcx+80-dx
        sta rc_w
        lda wcx
        adc #ROWCHARS
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
        lda #ROWCHARS
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
        lda #ROWCHARS
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
        stza KEEP,x
        cpx cnt
        bcs @next
        lda sprmul5,x
        tax                         ; X = list offset, Y = offset into the record:
        lda SPRLIST,x               ; (rp),y -- NOT (rp,x), which indexes the pointer
        ldy #0                      ; itself and made every compare below read garbage
        cmp (rp),y
        beq @same                   ; same sprite, same place: it redraws its own pixels
        ; two box-star frames at the same place overwrite each other exactly -- every
        ; pixel opaque, and each box covers the art of the frame before it -- so a
        ; frame change there needs no erase either
        cmp #BOXID0
        bcc @next
        ldaz rp
        cmp #BOXID0
        bcc @next
        lda #1                      ; 1 = a different frame of the same thing
        sta tmp3
        bne @pos                    ; (always)
@same:  lda #2                      ; 2 = identical, so its pixels are already right
        sta tmp3
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
        lda tmp3
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
        and #$7F
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
        ; Two passes.  A box star is an opaque rectangle with its background baked in,
        ; so it has to go down before anything that shares its space -- drawn in list
        ; order it would paint that background over whatever was standing there.
        lda #1
        sta dpass
@pass:  stza spi
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     lda spi
        cmp NSPR
        bcs @endpass
        ldx spi
        lda sprmul5,x
        tax                         ; X = list offset
        lda SPRLIST,x
        cmp #BOXID0                 ; the box stars are the top of the id space
        lda #0
        rol                         ; 1 if this is one, 0 if not
        cmp dpass
        bne @next
        lda SPRLIST,x
        cmp #BOXID0+BOXN            ; a box star the logic says nothing can disturb, and
        bcc @write                  ; the same frame already in the same place: if
        ldy spi                     ; nothing has been repainted under it, its pixels
        lda KEEP,y                  ; are still right, so leave it alone
        cmp #2
        bne @write
        ldy #9                      ; and it was not cut off at a window edge, so all
        lda (rp),y                  ; of it is on screen and still intact
        bpl @next
@write: ldy #0
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
@endpass:
        dec dpass
        bmi :+
        jmp @pass                   ; (out of branch range on the 6502 build)
:       ldx curbuf
        lda NSPR
        sta RECCNT,x
        rts

; draw one sprite: A = id ; spx, spy = map px (ref point)
; A = sprite id. Game sprites (spbank = BANK_SPR): directory is in main RAM at
; SPR_TABLE; sprite data is in bank 4, or in ANDY ($8000, ROMSEL bit7) when the
; entry's flag bit2 is set. Title pieces (spbank != BANK_SPR): directory and data
; both live at TITLE_ADDR of that bank.
drawsprite:
        stza spclip                 ; set at every window edge the sprite is cut against
        cmp #BOXID0+BOXN            ; the "nothing can disturb it" aliases draw the same
        bcc :+                      ; picture as the ids BOXN below them
        sbc #BOXN
:       stza ptr+1
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
        bne :+
        jmp @out0                   ; (out of branch range on the 6502 build)
:       ldy #7
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
        inc spclip                  ; cut off at the left edge
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
        cmp #ROWCHARS
        bcs @out0                   ; not taken: C = 0 for the adc below
        sta sp_c0
        adc sp_w
        deca
        cmp #ROWCHARS
        bcc :+
        inc spclip                  ; and at the right
        lda #(ROWCHARS-1)
:       sta sp_c1
        stza sp_c
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
        inc spclip                  ; cut off at the top
        stz tmp
@ck:    lda w16+1
        bne @clampend
        lda w16
        cmp #BUFROWS*8
        bcc :+
@clampend:
        inc spclip                  ; and at the bottom
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
        ldx spclip                  ; bit 7 = this one came off an edge, so more of it
        beq :+                      ; may be visible next time and it has to be redrawn
        ora #$80
:       sta (rp),y
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
        lda sp_rb+1                 ; (see drawrect's @rowdone)
        cmp #(>RINGEND - 5)
        bcc :+
        lda sp_rb
        ldy sp_rb+1
        ldx sp_ncol
        inx
        jsr mirror_run
:
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
        adc #<ROWBYTES
        sta sp_rb
        lda sp_rb+1
        adc #>ROWBYTES
        ringup_cc
        sta sp_rb+1
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
        cmp #$41                    ; a blank-run tag reached below line 0 (the packer marks
        bne :+                      ; every line a run covers): the rest of this cell is all
        jmp blank                   ; transparent, so skip it -- $41 else draws a red pixel
:
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
        cmp #$41                    ; blank-run tag mid cell: the rest of the cell is empty
        beq pd
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
        lda wcx                     ; a horizontal scroll re-sources every column of the
        cmp PART_CXL,x              ; A row (it maps to ring row wcy shifted by wcx), so the
        bne @all                    ; dirty-column shortcut is only valid when wcx is unchanged
        lda wcx+1
        cmp PART_CXH,x
        bne @all
        ; same source row, lines and column as last time: only the columns drawn since
        lda PART_HI,x
        cmp #ROWCHARS
        bcc :+
        lda #(ROWCHARS-1)
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
        lda wcx
        sta PART_CXL,x
        lda wcx+1
        sta PART_CXH,x
        lda #ROWCHARS
        sta cnt
        lda #0
@go:    sta tmp4                    ; first column to copy
        tay                         ; range is clean once copied
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
        ; dest = the same column of the fixed partial row, which is all section A of
        ; the rupture chain ever displays
        lda tmp4
        stz ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        clc
        adc #<PARTADDR
        sta ptr
        lda ptr+1
        adc #>PARTADDR
        sta ptr+1
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
:       dec cnt
        beq @done
        jmp @fjmp
@done:  rts

; ============================================================================
; calc_ring: ringS = ((wcy & 31) * 80 + wcx) mod 2560 ; barq = ringS / 80
; ============================================================================
; copy_bar: if this buffer's bar rows are stale, write bar image into ring slots q-3, q-2
; The bar has a fixed home outside the ring, so it stays put however the window
; scrolls and is only written when its contents change.  It used to live in the two
; ring rows above the window, which move every frame the view scrolls vertically;
; re-copying 1280 bytes for that cost 13,310 cycles of an 80,000 cycle frame.
; bar_bg: blit the static bar template (icons, labels, blank digit slots) from bank 4
; into the current back buffer's fixed bar rows.  Source art, not a maintained buffer.
bar_bg:                             ; runs only when a buffer needs its bar (twice per
        lda #BANK_SPR               ; level).  The bar is black with a few icon spans, so
        sta curbank                 ; fill black and lay the spans (BARBUF is now the span
        sta ROMSEL_CPY              ; list: offset16, len, bytes... ending $FFFF).
        sta ROMSEL
        lda #<BARADDR               ; --- fill the bar rows with opaque black ($C0)
        sta w16b
        lda #>BARADDR
        sta w16b+1
        lda #$C0
        ldx #>(BARROWS*640)         ; 1280 bytes = 5 pages
        ldy #0
@bf:    sta (w16b),y
        iny
        bne @bf
        inc w16b+1
        dex
        bne @bf
        lda #<BARBUF                ; --- lay the icon spans
        sta w16
        lda #>BARBUF
        sta w16+1
@bs:    ldy #1
        lda (w16),y                 ; offset high ($FF = end)
        cmp #$FF
        beq @bsdone
        pha
        dey
        lda (w16),y                 ; offset low
        clc
        adc #<BARADDR
        sta w16b
        pla
        adc #>BARADDR
        sta w16b+1                  ; dest = BARADDR + offset
        ldy #2
        lda (w16),y
        sta tmp2                    ; len
        lda w16                     ; step past the 3-byte header
        clc
        adc #3
        sta w16
        bcc :+
        inc w16+1
:       ldy #0
@bc:    lda (w16),y
        sta (w16b),y
        iny
        cpy tmp2
        bne @bc
        tya                         ; step past the data
        clc
        adc w16
        sta w16
        bcc @bs
        inc w16+1
        bra @bs
@bsdone: rts

; ============================================================================
        .segment "LOGIC"           ; main RAM is full on a Master: this touches
                                    ; nothing but main RAM and the CRTC, so it can
                                    ; live in the bank the game logic already uses
; build_sections: fill SECTAB for the current buffer from ringS and wfine.
; entry i: R12n, R13n, R4, R9, R6, R7, T1lo, T1hi (T1 = duration of section i+1)
;
; The bar and the partial row have fixed homes, so only the playfield walks the ring.
; A row starting past RINGCHARS-80 straddles the ring end; it is read from the mirror
; sitting immediately below the ring base, which makes its address c - RINGCHARS in
; ring-offset terms, and every row after it follows on contiguously.  That costs one
; extra section whenever the window straddles.
; ============================================================================
LINE = 64
BARCRTC  = BARADDR / 8
PARTCRTC = PARTADDR / 8
        .code
; The row that straddles the ring end is shown from the mirror below the ring base,
; but only its chars from r = wcx mod 80 up: the ones before r are the part of that
; row the CRTC reads from the ring itself.  So the mirror is kept right on [r, 80)
; and no further -- writes below r are dropped by mirror_run -- and when the window
; scrolls left and r falls, the chars that have just come into range are fetched
; from the ring, which is always right.  Once per frame, before anything draws.
mirror_seek:
        ldx barq
        lda ringS
        sec
        sbc mulrowlo,x              ; r
        sta tmp2
        stz w16+1
        asl
        rol w16+1
        asl
        rol w16+1
        asl
        rol w16+1                   ; 8r
        clc
        adc #<(RINGEND-ROWBYTES)
        sta MIRR_LO
        lda w16+1
        adc #>(RINGEND-ROWBYTES)
        sta MIRR_LO+1
        ldx curbuf
        lda tmp2
        cmp MIRR_R,x
        bcs @ok                     ; not scrolled left: what was valid still is
        lda MIRR_R,x
        sec
        sbc tmp2
        tax                         ; chars r..old-1 have become needed
        lda MIRR_LO
        ldy MIRR_LO+1
        jsr mirror_run
        ldx curbuf
@ok:    lda tmp2
        sta MIRR_R,x
        rts

; Every write into the ring's last row from the fragment on is repeated RINGBYTES
; lower, so the mirror keeps up with the drawing.  A/Y = the first
; char of a run just drawn, X = how many chars; the callers only bother for rows that
; start within reach of the last 640 bytes.  A run steps and folds like the drawing
; did, so the chars that wrapped into ring row 0 fall below the source and are skipped.
; w16/w16b are borrowed and put back: scroll_validate holds dx/dy in them across the
; drawrect calls this runs inside.
mirror_run:
        sta tmp3
        stx tmp4                    ; n
        lda w16
        pha
        lda w16+1
        pha
        lda w16b
        pha
        lda w16b+1
        pha
        lda tmp3
        sta w16
        sty w16+1
        ; the run starts below the needed fragment: skip (fragment - start) / 8 chars
        lda w16+1
        cmp MIRR_LO+1
        bcc @below
        bne @inside
        lda w16
        cmp MIRR_LO
        bcs @inside
@below: lda MIRR_LO
        sec
        sbc w16
        sta tmp3
        lda MIRR_LO+1
        sbc w16+1
        lsr
        ror tmp3
        lsr
        ror tmp3
        lsr
        ror tmp3                    ; (the gate keeps this under 1280 bytes: 160 chars)
        lda tmp3
        cmp tmp4
        bcs @done                   ; it ends before the source row
        lda tmp4
        sec
        sbc tmp3
        sta tmp4
        lda MIRR_LO
        sta w16
        lda MIRR_LO+1
        sta w16+1
@inside:
        ; and it may run past the ring end (those chars wrapped into ring row 0)
        lda #<RINGEND
        sec
        sbc w16
        sta tmp3
        lda #>RINGEND
        sbc w16+1
        lsr
        ror tmp3
        lsr
        ror tmp3
        lsr
        ror tmp3
        lda tmp3
        cmp tmp4
        bcs :+
        sta tmp4
:       ldx tmp4
        beq @done
        lda w16
        sta w16b
        lda w16+1
        sec
        sbc #>RINGBYTES             ; RINGBYTES is whole pages, so the low byte holds
        sta w16b+1
@cp:    ldy #7
:       lda (w16),y
        sta (w16b),y
        dey
        bpl :-
        lda w16
        clc
        adc #8
        sta w16
        bcc :+
        inc w16+1
:       lda w16b
        clc
        adc #8
        sta w16b
        bcc :+
        inc w16b+1
:       dex
        bne @cp
@done:  pla
        sta w16b+1
        pla
        sta w16b
        pla
        sta w16+1
        pla
        sta w16
        rts
        .segment "LOGIC"            ; back to the bank
build_sections:
        lda curbuf
        asl
        tax
        lda #>BARCRTC               ; section 0 is the bar: fixed address, fixed length
        sta BUF_SEC0,x
        lda #<BARCRTC
        sta BUF_SEC0+1,x
        lda #<(BARROWS*8*LINE-2)
        sta BUF_SEC0T1,x
        lda #>(BARROWS*8*LINE-2)
        sta BUF_SEC0T1+1,x
        lda curbuf
        beq :+
        lda #48
:       tax
        ; --- T (the bar) : R4/R9/R6/R7 of its own, R12/R13 of whatever follows
        lda #1
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #2
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda wfine
        beq @coarse
        ; ---- f > 0 : T -> A (the partial row) -> P.. -> P2 -> Q
        lda #>PARTCRTC
        sta SECTAB,x
        lda #<PARTCRTC
        sta SECTAB+1,x
        lda wfine
        eor #7
        inca                        ; 8-f lines of it
        jsr @dur
        sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax                         ; A's entry
        lda #0
        sta SECTAB+2,x
        lda #7
        sec
        sbc wfine
        sta SECTAB+3,x
        lda #2
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda ringS                   ; the run starts one row into the window
        clc
        adc #ROWCHARS
        sta w16
        lda ringS+1
        adc #0
        sta w16+1
        jsr @wrap
        lda #VISROWS-1
        sta tmp4                    ; rows in the run
        lda barq                    ; which starts one ring row after the window (X is
        clc                         ; the live SECTAB entry index, so compute in A)
        adc #1
        cmp #RINGROWS
        bcc :+
        lda #0
:       sta tmp3
        jmp @run
@coarse:                            ; ---- f = 0 : T -> P.. -> Q
        lda ringS
        sta w16
        lda ringS+1
        sta w16+1
        lda #VISROWS
        sta tmp4
        lda barq                    ; the run starts on the window's ring row
        sta tmp3
@run:   ; w16 = the run's ring offset, tmp4 = its rows, X = the entry of the section
        ; before it.  Entry i carries section i+1's address and duration, and section
        ; i's own R4/R9/R6/R7, so each section is written across two entries.
        jsr @nfull                  ; rows that end before the ring end
        cmp tmp4
        bcs @one                    ; the whole run fits
        cmp #0
        beq @one                    ; it starts inside the last row: all of it folds
        sta tmp2
        jsr @emit                   ; first part: tmp2 rows, up to the ring end
        lda tmp2
        jsr @advance
        lda tmp4
        sec
        sbc tmp2
        sta tmp4
        lda tmp4
        sta tmp2
        jsr @emit                   ; second part, read through the mirror
        jmp @past
@one:   lda tmp4
        sta tmp2
        jsr @emit
@past:  lda tmp4
        jsr @advance                ; now the row below the playfield
        lda wfine
        beq @setq
        ; --- P2 : the top f lines of that row
        jsr @addr
        lda wfine
        jsr @dur
        sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax
        lda #0
        sta SECTAB+2,x
        lda wfine
        deca
        sta SECTAB+3,x
        lda #VISROWS
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
@setq:  jsr @addr                   ; Q starts on the row below the playfield
        lda #<(40*LINE-2)
        sta SECTAB+6,x
        lda #>(40*LINE-2)
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax
        lda #>BARCRTC               ; and hands the chain back to the bar
        sta SECTAB,x
        lda #<BARCRTC
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
; --- emit a run of tmp2 rows starting at w16 (a ring offset), following entry X
@emit:  jsr @addr
        lda tmp2
        jsr @lines
        sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        txa
        clc
        adc #8
        tax
        lda tmp2
        deca
        sta SECTAB+2,x
        lda #7
        sta SECTAB+3,x
        lda #30
        sta SECTAB+4,x
        sta SECTAB+5,x
        rts
; --- SECTAB+0/1,x = the CRTC address for the row at ring offset w16.  A row starting
; past RINGCHARS-80 straddles the end and is read from the mirror below the base,
; which is exactly the address w16 - RINGCHARS names.
@addr:  lda w16
        sta w16b
        lda w16+1
        sta w16b+1
        cmp #>(RINGCHARS-ROWCHARS+1)
        bcc :++
        bne :+
        lda w16b
        cmp #<(RINGCHARS-ROWCHARS+1)
        bcc :++
:       lda w16b
        sec
        sbc #<RINGCHARS
        sta w16b
        lda w16b+1
        sbc #>RINGCHARS
        sta w16b+1
:       lda w16b
        clc
        adc #<CRTCBASE
        sta tmp
        lda w16b+1
        adc #>CRTCBASE
        sta SECTAB,x
        lda tmp
        sta SECTAB+1,x
        rts
; --- A = rows -> A/tmp3 = that many rows of lines, as a T1 count
@lines: asl
        asl
        asl
        jmp @dur
; --- A = rows: advance w16 by that many rows, folding into 0..RINGCHARS
@advance:
        tay
:       lda w16
        clc
        adc #ROWCHARS
        sta w16
        bcc :+
        inc w16+1
:       dey
        bne :--
        ; fall through
; --- fold w16 into 0..RINGCHARS-1
@wrap:  lda w16+1
        cmp #>RINGCHARS
        bcc :++
        bne :+
        lda w16
        cmp #<RINGCHARS
        bcc :++
:       lda w16
        sec
        sbc #<RINGCHARS
        sta w16
        lda w16+1
        sbc #>RINGCHARS
        sta w16+1
:       rts
; --- rows of the run that finish before the ring end.  The run starts on ring row
; tmp3.  When the window has a char offset r = ringS mod 80, ring row RINGROWS-1 is the
; straddling row (@addr redirects it to the mirror), so RINGROWS-1-tmp3 rows come first.
; But when r == 0 the window is row aligned: that last ring row is whole and shown from
; the ring itself, with the wrap falling after it -- so it belongs to this run, giving
; RINGROWS-tmp3.  Getting this wrong emits a section that reads off the ring end into the
; bar (a duplicate bar mid screen when scrolling to a column that is a multiple of 80).
@nfull: stx tmp2                    ; X is the live SECTAB entry index: save it
        ldx barq
        lda ringS
        sec
        sbc mulrowlo,x              ; r = ringS mod 80
        ldx tmp2                    ; restore X (r survives in A)
        cmp #1                      ; C = 0 iff r == 0
        lda #RINGROWS
        bcc :+                      ; r == 0: the last ring row is whole, keep it here
        lda #RINGROWS-1             ; r  > 0: that row straddles, @addr sends it to the mirror
:       sec
        sbc tmp3
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
@subrow: lda w16
        sec
        sbc #ROWCHARS
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
@addrow: lda w16
        clc
        adc #ROWCHARS
        sta w16
        bcc :+
        inc w16+1
:       lda w16+1
        cmp #$10
        bcc :+                      ; not taken: C = 1 for the sbc
        sbc #$0A
        sta w16+1
:       rts

        .code

BARROWS = 2                        ; the status bar
QROWS  = 39 - VISROWS - BARROWS    ; blank rows after the display: 312 lines in all
QVSYNC = 4                         ; vsync at Q row 4 -> section 0 starts QROWS-4 later

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
        jsr mirror_seek
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
        stza DIRTYSEEN
        jsr copy_partial
        ldx curbuf
        lda BARBG,x                 ; first time this buffer is drawn: lay the template
        beq :+
        jsr bar_bg
        ldx curbuf                  ; bar_bg pages banks -> X clobbered
        stza BARBG,x
:       ldx curbuf
        lda BARDIRTY,x              ; a value changed: draw the digits over it
        beq :+
        jsr t_redraw_hud
        ldx curbuf                  ; redraw_hud clobbers X
        stza BARDIRTY,x
:
        stza NSPR
        jsr t_build_sections
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
        stza tmp
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
        cmp #ROWCHARS
        bcs @none                   ; not taken: C = 0 for the adc
        adc rc_w
        cmp #81
        bcc :+                      ; not taken: C = 1 for the sbc
        lda #ROWCHARS
        sbc w16
        sta rc_w
:       jmp drawrect
@none:  rts
; ============================================================================
; drawrect_clip: like drawrect but clips the rect to the current window
; (rows wcy..wcy+30, cols wcx..wcx+79).
calc_ring:
        lda wcy
        ringmod
        tax
        lda mulrowlo,x
        clc
        adc wcx
        sta ringS
        lda mulrowhi,x
        adc wcx+1
        sta ringS+1
        cmp #>RINGCHARS
        bcc :+
        bne @sub
        lda ringS
        cmp #<RINGCHARS
        bcc :+
@sub:   lda ringS
        sec
        sbc #<RINGCHARS
        sta ringS
        lda ringS+1
        sbc #>RINGCHARS
        sta ringS+1
:       ; q = S / 80
        lda ringS
        sta w16
        lda ringS+1
        sta w16+1
        ldx #0
@div:   lda w16
        sec
        sbc #ROWCHARS
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
        stza IDENT+$41               ; it must leave the screen byte alone.  $82 is its
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
        jsr build_ring              ; ring row -> screen address
        ; row slot -> chars
        stz w16
        stz w16+1
        ldx #0
@m80:   lda w16
        sta mulrowlo,x
        lda w16+1
        sta mulrowhi,x
        lda w16
        clc
        adc #ROWCHARS
        sta w16
        bcc :+
        inc w16+1
:       inx
        cpx #RINGROWS
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
        sta tset                    ; no tile set resident yet
        stz BARDIRTY
        stz BARDIRTY+1
        stz BARBG
        stz BARBG+1
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
        stza rc_x+1
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
        stza DIRTYCNT,x
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
:       ; ---- vsync: restart T1 first (constant latency), counter = vsync->T.  The
        ; latch (how long section 0 lasts) is programmed further down, after the
        ; flip, because with no status bar section 0's length depends on the fine
        ; scroll and so belongs to the buffer that is about to be displayed.
        lda VS2T
        sta VIA_T1LL
        lda VS2T+1
        sta VIA_T1CH
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
        lda ACCCON                  ; there is no shadow to switch: the flip is the
        and #$FE                    ; section chain moving to the other buffer's rows
        ora NEXTBUF
        sta ACCCON
        stz flipreq
@noflip:
        ; everything section 0 needs comes from the buffer that is about to be
        ; displayed -- its start address, and (with no status bar) its length
        ldx #0
        lda DISPSECT
        beq :+
        ldx #2
:       lda BUF_SEC0T1,x
        sta VIA_T1LL
        lda BUF_SEC0T1+1,x
        sta VIA_T1LH
        lda #12
        sta CRTC_IDX
        lda BUF_SEC0,x
        sta CRTC_DAT
        lda #13
        sta CRTC_IDX
        lda BUF_SEC0+1,x
        sta CRTC_DAT
        lda #$40                    ; drop any T1 tick that fired while we were in
        sta VIA_IFR                 ; here: it would step the chain on before the
        lda #0                      ; frame has even started, and the next section's
        sta SECIDX                  ; registers would land a frame early
        lda DISPSECT
        sta SECIDX
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
        tay                         ; the note goes in Y before X is pushed: on a 6502
        phx                         ; phx is txa/pha and would land on it
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
        stza MUSNOTE
        stza MUSNOTE+1
        stza MUSNOTE+2
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
        stza flipreq
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
crtctab: .byte 127,ROWCHARS,98,$28, 38,0,32,34, 0,7, $20,8, $06,$00
ringmodtab:
.repeat 256, i
        .byte i .mod RINGROWS
.endrepeat

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
mulrowlo: .res RINGROWS
mulrowhi: .res RINGROWS
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

; The 1770 answers at $FE24 (control) and $FE28 (registers).  Control has reset in
; bit 2 (active low) and density in bit 5.
; initialise: reset controller, restore head to track 0
disc_init:
        lda #$20
        sta FDC_CTRL                ; reset asserted (active low bit 2)
        lda #$25
        sta FDC_CTRL                ; drive 0, FM, reset released
        lda #$00                    ; restore, spin up, 6ms
        sta FDC_CMD
        jsr fdc_wait
        stza cur_trk
        rts

fdc_wait:
        ldx #20
:       dex
        bne :-
:
        lda FDC_STAT
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
        bcc ldr_trk
        sbc #10
        sta ld_sc
        inc ld_trk
        bra :-
ldr_trk: lda ld_trk
        cmp cur_trk
        beq ldr_rd
        sta cur_trk
        sta FDC_DATA
        lda #$10                    ; seek (no verify)
        sta FDC_CMD
        jsr fdc_wait
ldr_rd:  ; sectors to read on this track: min(ld_n, 10 - ld_sc)
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
        beq ldr_end
        stza ld_sc
        inc ld_trk
        bra ldr_trk
ldr_end:  rts

        .segment "LOW2"             ; main RAM under the screen is full; the old MOS
; ============================================================================
; Map access for the logic, which lives in bank 7 and so cannot select bank 6
; itself.  Each of these leaves bank 7 selected, so the logic calls them directly.
; ============================================================================
; A = tile row -> mapptr = address of that map row
maprow: tay
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
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

; build_tileaddr: the tile id -> data address table, into bank 6 at LV_PAGE0.  Ids
; 0..253 address 64 bytes each from $8000 in the tile bank; 254 and 255 are the two
; solid fills, which own no bytes there -- hi bit 6 says "fill from a constant" and
; lo bit 4 picks cyan over black.  Constant, so this runs once at startup.
build_tileaddr:
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        ldx #0
@t:     txa
        asl                         ; (id & 3) << 6: the rest shifts out
        asl
        asl
        asl
        asl
        asl
        sta LV_PAGE0,x
        txa
        lsr
        lsr
        ora #$80                    ; $80 | id >> 2
        sta LV_PAGE0+256,x
        inx
        bne @t
        lda #$C0                    ; the two solid ids carry a fill, not an address
        sta LV_PAGE0+256+SOLID_CYAN
        sta LV_PAGE0+256+SOLID_BLACK
        lda #$10
        sta LV_PAGE0+SOLID_CYAN
        stz LV_PAGE0+SOLID_BLACK
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

        .segment "LOW2"
; the screen address of each ring row, from the base of the buffer being drawn
build_ring:
        stz w16
        lda #>RINGBASE
        sta w16+1
        ldx #0
@r:     lda w16
        sta RINGLO,x
        lda w16+1
        sta RINGHI,x
        lda w16
        clc
        adc #<ROWBYTES
        sta w16
        lda w16+1
        adc #>ROWBYTES
        sta w16+1
        inx
        cpx #RINGROWS
        bne @r
        rts
        .segment "CODE"

; ---------------------------------------------------------------- level tiles
; There are two fixed tile sets, outdoors and indoors, each a bank of at most
; 256 tiles, and a level's header says which it wants.  Levels alternate, so
; this reads 16K about every other level and nothing in between.
load_tiles:
        setbank BANK_LVL
        lda LV_HDR+20               ; which tile set (header: 20 fixed bytes, then gset)
        cmp tset
        beq :+
        sta tset
        clc
        adc #FI_TILESO
        jmp loadfile
:       rts

; sign extend A -> tmp3 (0 or $FF).  In LOW2 (the old MOS vector page) because main
; RAM below the screen is full: there is room to spare there.
        .segment "LOW2"
sext:   and #$80
        beq :+
        lda #$FF
:       sta tmp3
        rts

; ============================================================================
; Bridges between main RAM and the game logic, which lives at $8900 in bank 7 --
; a choice inherited from the Model B, which had no HAZEL to put it in.  t_ goes
; in, m_ comes back out:
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
        TOBANK "build_sections"
        TOBANK "init_tables"
        TOBANK "draw_health"
        TOBANK "draw_lives"
        TOBANK "draw_score"
        TOBANK "redraw_hud"
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
        TOMAIN "calc_ring"
        TOMAIN "clamp_window"
        TOMAIN "drawsprite"
        TOMAIN "loadfile"
        TOMAIN "mark_dirty"

        .segment "CODE"
        TOMAIN "music_start"
        TOMAIN "music_stop"
        TOMAIN "ringaddr"
        TOMAIN "rnd"
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
