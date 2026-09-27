; ============================================================================
; CLEO - BBC Micro port : display engine
;   - double buffered ring framebuffers: main and shadow RAM, 20K each, on the
;     Master; two rings in main RAM on the Model B
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

IRQ1V     = $0204
ROMSEL_CPY= $F4

; The banks, the same numbers on both machines (the sockets are patched at boot):
;   4  the sprite row loop (with the mirrored blitter), sprites, SWAPTAB, MASKTAB0-3
;   5  the sprite row loop (with the copy blitter), gather5, sprites, the map at
;      $9C00, MASKTAB0-3; the title pack during the menus
;   6  bank6_entry/drawrect_clip, the tile blitter and the ring work, the level's
;      tiles from $8600; the menu overlay during the menus
;   7  the level's tables, then the logic, the game loop and the rest of the renderer
BANK_SPR  = 4
BANK_TIL1 = 5                     ; the second sprite bank
BANK_TILES= 6                     ; every level's tile data fits one bank
BANK_LVL  = 7
BANK_MAP  = 5                     ; the map, and the gather that reads it in place

; ---------------------------------------------------------------- screen shape
; An 80-char ring per buffer, with the 2-row status bar displayed above it.
ROWCHARS  = 80
  .if BHW
; Model B: 32K of main RAM, and all but 768 bytes of it is the display.  Two rings of
; 23 slots, each with a mirror row below it (the rupture chain reads the row that
; straddles the ring end from there: see docs/DESIGN.md), and the 2-row bar:
;   $0300 bar  $0800 mirror A  $0A80 ring A  $4400 mirror B  $4680 ring B  $8000
RINGROWS  = 23
VISROWS   = 21                    ; 168 lines = 84 game px
  .else
RINGROWS  = 32                    ; the whole 20K: the hardware fold IS the ring wrap
VISROWS   = 30                    ; visible char rows: 240 lines = 120 game px (the
                                  ; original is 108: a 128-line phone screen less a
                                  ; 20-line HUD).  30 fills the ring exactly: 31 held
                                  ; + the composed row.
  .endif
BUFROWS   = VISROWS + 1           ; rows held: the visible ones plus the bottom partial's
; The camera follows Cleo one for one, so her fall speed is also how far the window
; moves in a frame.  A char row is four map pixels: a play decision.
MAXDWY    = 8
ROWBYTES  = ROWCHARS*8
RINGCHARS = ROWCHARS*RINGROWS
RINGBYTES = RINGCHARS*8
  .if BHW
; 23 x 640 = $3980 is not a whole number of pages, so the fold is 16 bit -- but both
; ring ENDS are page aligned, which keeps the fold TEST a byte compare (ringup), and
; both bases are at xx80, which makes the low byte's fold a subtraction of $80.
; Main RAM is display from the bar's $0300 to $8000: nothing else lives in it
; (the code every bank calls is the low RAM below it: low.s).
RING_A    = $0A80
RING_B    = $4680
RING0     = RING_A                ; buffer 0's ring (the menus' too)
CLEAR0    = MIRR_A                ; the menus' clear: mirrors and rings, to $8000
MIRR_A    = RING_A - ROWBYTES
MIRR_B    = RING_B - ROWBYTES
RINGEND_A = RING_A + RINGBYTES
RINGEND_B = RING_B + RINGBYTES
.assert RINGEND_B = $8000 && (RINGEND_A & $FF) = 0, error, "the ring ends must be page aligned"
.assert (<RING_A) = $80 && (<RING_B) = $80, error, "ringup's low-byte fold assumes bases at xx80"
BARADDR   = $0300
.assert MIRR_A = BARADDR + BARROWS*ROWBYTES, error, "mirror A must follow the bar"
  .else
BUF0      = $3000
.assert (RINGCHARS & $FF) = 0, error, "the ring folds on a high-byte compare"
; The layout: the bar at $2B00 (below the screen, main RAM, single buffered), then each
; buffer's ring at $3000-$7FFF, main and shadow.  The ring is the entire screen and
; the CRTC folds it for free: an address that runs off $8000 comes back to $3000, the
; ring base, so a displayed row may straddle the end and no mirror copy is needed.
; That is the whole reason RINGROWS is 32 -- it is not a choice, it is the size of the
; region the hardware wraps.
RINGBASE  = BUF0
RING0     = RINGBASE              ; buffer 0's ring (the menus' too)
CLEAR0    = RINGBASE              ; the menus' clear: buffer 0's ring, to $8000
RINGEND   = RINGBASE + RINGBYTES
; The composed top row has to be INSIDE the screen: it is per buffer, and anything below
; $3000 is only main RAM to the CRTC (the bar gets away with it by being single buffered
; and scanned with D = 0).  It lives in the one ring row the window does not hold: the
; row ABOVE it, ring chars [ringS + BUFROWS*80, ringS + RINGCHARS) = [ringS - 80, ringS).
; The window start is char granular (ringS = wcy*80 + wcx), so that row is not a slot in
; the row tables: its column c is ring char (ringS + c + RINGCHARS - 80) mod RINGCHARS,
; a constant offset from its source, which makes it a ring row like any other.  It is
; window aligned, not slot aligned -- a row-aligned slot (barq + 31) would overlap the
; window's last row by ringS mod 80 chars with BUFROWS at 31 -- so its copy may fold
; at $8000 mid-run (copy_partial).
; The bar is BELOW the screen in memory, in main RAM, and there is only one of it.  The CRTC's
; start address is just RAM/8, so it can scan from anywhere under $8000 -- but with
; shadow selected for display (ACCCON D = 1) everything under $3000 reads HAZEL/ANDY
; instead of main RAM, so the bar's section runs with D = 0 and the playfield's with
; D = the buffer being shown.  Single buffered: it is drawn where it is displayed,
; inside the 40 lines between vsync and the first scanned bar line.
BARADDR   = $2B00
CRTCBASE  = RINGBASE / 8          ; the CRTC counts characters, so the ring starts here
  .endif
WINPX     = ROWCHARS*2            ; window width in pixels
VISLINES  = VISROWS*8
BINMAX    = BINMAXDEF             ; from the objects' grid cells and the walk rectangle
MAXREC    = MAXSPRDEF             ; (assets.inc)
MAXSPR    = MAXSPRDEF

DIRTYMAX = 20                     ; dirty tiles a buffer can queue: a switch marks 2 x its
                                  ; height at once, 18 for the tallest (level 7's main map);
                                  ; past this the buffer is redrawn whole (mark_dirty)
; key bits
K_LEFT  = 1
K_RIGHT = 2
K_UP    = 4
K_DOWN  = 8
K_FIRE  = 16

; ---------------------------------------------------------------- zero page
        .zeropage
  .if BHW
jv:       .res 2                  ; jmp (abs,x) has no 6502 form: it goes through here
  .endif
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
rc_wrap:  .res 1                  ; row may cross the ring end (needs per-run wrap check)
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
tmp4c8:   .res 1                  ; copy_partial: the column's byte offset within a row
sp_dbank: .res 1                  ; the bank the sprite's DATA is in: selected once the
                                  ;   prologue has finished reading the directory
sp_c0:    .res 1
sp_c1:    .res 1
sp_lb0:   .res 2
sp_r0:    .res 1
sp_r1:    .res 1
sp_ra0:   .res 1
sp_ra1:   .res 1
sp_rb:    .res 2                  ; screen address of the current row's first char
sp_rp:    .res 2                  ; source pointer for the current row (col base + row offset)
sp_rinc:  .res 1                  ; source bytes per row: 8 (full res) or 4 (half res)
sp_ncol:  .res 1                  ; columns-1
sp_row:   .res 1
sp_c:     .res 1
sp_lim:   .res 1
sp_cnt:   .res 1                  ; sprite column countdown
                                  ; the segment stops at $A3 (the cfgs), so the mask
                                  ; walk aliases zp the blit no longer needs; the rest
                                  ; of it is fixed zp (defs.inc: sp_mh, sp_mrp...)
mptr    = w16                    ; this column group's mask bytes, one per pixel row
mtab    = tmp3                    ; MASKTAB page for this column's phase (tmp3 = 0, tmp4 = page)
sp_msk  = tmp4c8                  ; the AND mask of the pair being drawn
sp_id   = sp_ext                  ; the sprite id, until sp_ext is set a few lines later
spi:      .res 1
lcnt:     .res 1
lidx:     .res 1
ringS:    .res 2                  ; window start char S (0..RINGCHARS-1)
barq:     .res 1                  ; row slot q = S/80

; level geometry
maplw:    .res 1                  ; log2 map width in tiles
maplh:    .res 1
mapw:     .res 2                  ; map width in px
maph:     .res 2
maxwx:    .res 2                  ; mapw - WINPX
maxwy:    .res 2                  ; maph - VISLINES/2

; misc
vsyncs:   .res 1                  ; counted by the vsync interrupt
flipreq:  .res 1                  ; 1 = flip pending
flipvs:   .res 1
keys:     .res 1                  ; current key bits
seed:     .res 2
SFXPTR:   .res 2
MUSPTR:   .res 2
  .if BHW                           ; the arithmetic gather's shape (gather5; the loader's,
half0:     .res 1                   ; per level): the Model B's hottest scalars (the Master's
half1:     .res 1                   ; gather is its table, LV_PAGE0).  The level's half
half2:     .res 1                   ; tiles: first id, the two range boundaries (bottom
halfhi5:   .res 1                   ; fills from half1, rowpairs from half2), the halves'
halfsub:   .res 1                   ; page, and half0 less the first half's slot in it
  .endif

; ---------------------------------------------------------------- the MOS's zero page
; $F0-$FF is the MOS's, but once the game has the machine only $F4 (ROMSEL's copy, which
; the interrupt restores) and $FC (where the MOS's interrupt entry keeps A) are touched.
; The rest holds the hottest scalars that were absolute (test/hotvars.mjs: a cycle and
; a byte an access); start-up zeroes it (init.s).  Defined here, ahead of their uses,
; so every access is assembled as zero page.
        .segment "ZPF0": zeropage   ; $F0-$F3
MAPSTRIDE: .res 2                   ; bytes per map row (1 << lw): drawrect's row step
mapshr:    .res 1                   ; 8 - lw (maprow, maprow6): both the loader's
MUSTICK:   .res 1                   ; a frame's tune step is due: the vsync's sound_tick
        .segment "ZPF5": zeropage   ; $F5-$FB
rowbit:    .res 1                   ; the char row being drawn, as a flag bit (1, 2)
dpass:     .res 1                   ; draw_sprites' pass
spclip:    .res 1                   ; set at every window edge a sprite is cut against
NSTARL:    .res 1                   ; the cached bin walk's lengths: stars,
NOTHL:     .res 1                   ;   everything else
spbank:    .res 1                   ; the bank drawsprite takes the images from
halfhi:    .res 1                   ; the halves' page (the loader's), for @hfill
        .segment "ZPFD": zeropage   ; $FD-$FF
MUSON:     .res 1                   ; the tune plays: the interrupt stub steps it
  .if BHW
crtcb:     .res 2                   ; build_sections: the buffer's CRTC base (display.s)
  .endif
        .zeropage

; ---------------------------------------------------------------- tables (uninitialised)
; Each table lives in the bank of the code that reads it, and only what more than one
; bank touches is in low RAM.  The mask tables are static data at a fixed address in
; both sprite banks (MASKTAB0, SWAPTAB in src/defs.inc); sprmul5 and the row tables
; are static too.
        .segment "TILBSS"           ; bank 6: the tile blitter's and the ring work's (the
                                    ; gather's arrays are low RAM's); boot zeroes it
BUF_CY:    .res 2
FLATTAB:   .res 2*(NFLAT+2)         ; the level's flat tiles: (even line, odd line) by
                                    ; id - FLAT0, the loader's; the solids are the last two
        .segment "LGCBSS"           ; bank 7: mark_dirty and draw_dirty are there
DIRTYLIST: .res 2*2*DIRTYMAX
        .segment "LOWBSS"           ; main RAM: the buffers' state bank 7 reads too
BUF_CX:    .res 4                   ; (bank 7 invalidates a buffer: high byte $80)
BUF_BOTOK: .res 2                   ; the slot below the playfield is black: scroll_validate
                                    ; (bank 6) clears it, blank_below (bank 7) sets it
DIRTYCNT:  .res 2                   ; (the game loop)
PBANK:     .res 4                   ; the physical bank of each of banks 4..7 (the loader's:
                                    ; cpu.inc -- read by what the loader cannot patch)
PBOARD:    .res 1                   ; and the board: BOARD_STD / WATFORD / SOLIDISK (defs.inc),
                                    ; right after PBANK (boot copies the five together)
        .segment "LGCBSS"           ; bank 7: the sprite prologue's records
SPRREC:    .res 2*MAXREC*10
RECCNT:    .res 2
KEEP:      .res MAXREC
        .segment "LGCBSS"           ; bank 7: the logic's, the display driver's and
BINR:      .res 4                   ; the interrupt's
BINOK:     .res 1
    .if BHW
BUF_SEC0:  .res 4
BUF_SEC0T1: .res 4
SECTAB:    .res 2*48
SFXDUR:    .res 1
LOADREQ:   .res 1                 ; 0 running, 1 stop asked, 2 stopped, 3 resume asked (load_begin)
    .else
        .segment "TABLES"           ; the Master: the interrupt handler and its chain
BUF_SEC0:  .res 4                   ; are in main RAM, and so is what they keep
BUF_SEC0T1: .res 4
SECTAB:    .res 2*48
SFXDUR:    .res 1
LOADREQ:   .res 1
dispD:     .res 1
NEXTBUF:   .res 1
    .endif
        .segment "MNUBSS"           ; bank 6's menu overlay: the tune's player lives there
MUSDUR:    .res 1                   ; (MUSON is in zero page: the interrupt reads it)
MUSNOTE:   .res 3
ISRT1:     .res 1
ISRT2:     .res 1
        .segment "LOWBSS"           ; main RAM: what more than one bank touches
SPRLIST:                          ; (a label, not an equate: the tools read labels.txt)
SPR_ID:    .res MAXSPR            ; the sprite draw list, one array per field (index =
SPR_XL:    .res MAXSPR            ;  the sprite's number, so no stride to multiply by):
SPR_XH:    .res MAXSPR            ;  id, x lo/hi, y lo/hi in map px
SPR_YL:    .res MAXSPR
SPR_YH:    .res MAXSPR
BARCACHE:  .res 16                  ; bar_bg resets it, bar_digit (bank 7) keeps it
DISPSECT:  .res 1
NEXTSECT:  .res 1

        .segment "TILCODE"     

; ---------------------------------------------------------------- macros
.macro crtc reg, val
        lda #reg
        sta CRTC_IDX
        lda val
        sta CRTC_DAT
.endmacro

; ---------------------------------------------------------------- ring wrapping
; A screen address that runs off the end of the ring folds back to its start.  On the
; Master the ring runs to $8000 and the test is the sign bit; on the Model B it is a
; compare with the buffer's ring end (ringehi).
; These spell their skip with an anonymous label, so a caller that wants to branch
; over one has to count it: see spnext, which says :++ for that reason.  A named
; label here would end the enclosing routine's cheap-local scope.
.macro ringmod                      ; A = a map char row -> its ring slot
.if (RINGROWS & (RINGROWS - 1)) = 0
        and #(RINGROWS-1)
.else
        .local n1, n2               ; a row is 0..255 and the table RINGROWS*5 long
        cmp #RINGROWS*5             ; (bank 6's): two subtractions bring the row into
        bcc n1                      ; it, 141 bytes short of a 256-entry table
        sbc #RINGROWS*5
n1:     cmp #RINGROWS*5
        bcc n2
        sbc #RINGROWS*5
n2:     tax
        lda ringmodtab,x
.endif
.endmacro
.macro ringmod7                     ; the same, by subtraction: for bank 7 (calc_ring,
  .if ::BHW                        ; ringaddr7), which has no copy of the table
:       cmp #RINGROWS
        bcc :+
        sbc #RINGROWS
        bcs :-
:
  .else
        ringmod
  .endif
.endmacro
; The ring's end is a page boundary, so the fold test is a compare on the high
; byte alone.  A = high byte after moving forward, folded back into the ring.
; The cmp leaves the carry set on the path that reaches the sbc, so the fold needs
; no sec of its own whatever the caller was holding.
.macro ringup p                     ; p names the pointer whose high byte A holds;
  .if ::BHW                        ; the Master's fold never needs it
        cmp ringehi                 ; the buffer's ring end, high byte (select_backbuf)
        bcc :+
        sbc #>RINGBYTES             ; C = 1 from the compare, and stays 1: A >= >RINGEND
        pha                         ; > >RINGBYTES.  The low byte folds by $80, which
        lda p                       ; borrows from A when p is below $80 (C still 1)
        sbc #<RINGBYTES
        sta p
        pla
        sbc #0
:
  .else
        bpl :+                      ; RINGEND = $8000: N from A (every caller's adc / inc a)
        sec
        sbc #>RINGBYTES
:
  .endif
.endmacro
.macro ringdn                       ; A = high byte after moving back
        cmp #>RINGBASE
        bcs :+
        adc #>RINGBYTES
:
.endmacro

.macro spnext                      ; sp on one char (8 bytes), folding at the ring end
        lda sp
        clc
        adc #8
        sta sp
        bcc :++                     ; past the fold's own anonymous label
        lda sp+1
        adc #0                      ; C = 1 (the bcc fell through): +1, 2 bytes not 6
        ringup sp
        sta sp+1
:
.endmacro

; ============================================================================
; ringaddr: screen address of map char (w16 = cx 16 bit, A = cy) -> sp
; ============================================================================
        .segment "TILCODE"          ; bank 6 (the sprite prologue has its own: ringaddr7)
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
        rol sp+1                    ; sp+1:A = cx*8; C = 0 (cx < 8192)
        adc RINGLO,x
        sta sp
        lda sp+1
@rh:    adc RINGHI,x                ; (Model B: the buffer's table, select_backbuf's)
        ringup sp
        sta sp+1
        rts
  .if .not BHW                      ; the Master's rows, one table for both buffers:
RINGLO:                             ; main and shadow share the addresses
  .repeat RINGROWS, r
        .byte <(RINGBASE + r*ROWBYTES)
  .endrepeat
RINGHI:
  .repeat RINGROWS, r
        .byte >(RINGBASE + r*ROWBYTES)
  .endrepeat
  .endif
  .if BHW
RINGHIOP := @rh + 1                 ; (after the rts: := ends the @ scope)
; the ring rows' addresses, assembled: both bases are xx80, so the low bytes are the
; two rings' alike and only the high bytes are per buffer
RINGLO:
  .repeat RINGROWS, r
        .byte <(RING_A + r*ROWBYTES)
  .endrepeat
RINGHI:                             ; ring A's, and the operand's value at start
  .repeat RINGROWS, r
        .byte >(RING_A + r*ROWBYTES)
  .endrepeat
RINGHI_B:
  .repeat RINGROWS, r
        .byte >(RING_B + r*ROWBYTES)
  .endrepeat
  .endif

; ============================================================================
; drawrect: draw map tiles into the current back buffer.
;   rc_x (map chars, 16 bit), rc_y (map char rows), rc_w (chars 1..80), rc_h (rows)
; ============================================================================
        .segment "TILCODE"          ; bank 6, with the tiles
drawrect:
        lda rc_h
        bne :+
        rts
:
  .if BHW
        lda mrow                    ; the map row the mirror follows (calc_ring): a rect
        sec                         ; that touches it says which window columns it wrote
        sbc rc_y
        cmp rc_h
        bcs @nomir
        lda rc_x
        sec
        sbc wcx                     ; the window column (rects are window clipped)
        pha
        clc
        adc rc_w
        tax
        dex                         ; ..the last one
        pla
        jsr mirdirty6
@nomir:
  .endif
        ; ---- per-rect invariants: tx0 = rc_x >> 2 ; tiles-1 = ((rc_x + rc_w - 1) >> 2) - tx0
        lda rc_x+1
        sta w16+1                   ; the ring address's copy, from this load too
        lsr                         ; C = bit 0, A = bit 1 (rc_x+1 <= 3)
        tax
        lda rc_x
        ror
        cpx #1                      ; C = bit 1
        ror                         ; A = tx0 (map width <= 256 tiles)
        sta rc_tx0
        lda rc_x                    ; tiles-1 = tx1 - tx0 = ((rc_x & 3) + rc_w - 1) >> 2,
        sta w16                     ; the copy the ring address needs, from the same load
        and #3                      ; so tx1 never needs building: max 3 + 80 - 1 = 82,
        sta rc_sc0                  ; one byte, no 16-bit shift, no w16
        asl
        asl
        asl                         ; C = 0 (rc_sc0 < 4): the adc's clc
        sta rc_ro0
        lda rc_sc0
        adc rc_w
        sbc #0                      ; C = 0 (<= 83, no carry): the -1
        lsr
        lsr
        sta rc_nt
        lda rc_y
        jsr ringaddr
        sta rc_sp+1                 ; ringaddr returns A = sp+1 (its last store)
        lda sp
        sta rc_sp
        ; ---- map row pointer: built once here (arithmetic, in low RAM: maprow6) and
        ; stepped on by the stride per tile row (@nextrow)
        lda rc_y
        lsr
        jsr maprow6
@rowy:
        jsr mapstrip                ; the row's gather, run in bank 5 beside the map
        wrsel BANK_TILES, BANK_TILES ; (gather5, below): GATHERL/H in low RAM; mapstrip
                                    ; comes back with A = this bank: the write bank too
        ; ---- draw this char row, and (without re-gathering) the odd row of the same tile row
        lda rc_y                    ; only a rect's first tile row can start on an odd
        and #1                      ; char row: after that @nextrow always lands even
        bne @second
        sta rc_sub                  ; A = 0: rc_y & 1 fell through
        lda rc_ro0
        sta rowoff
        lda #1                      ; the char row, as a half tile's flag bit
        sta rowbit
        jsr @drawrow
        dec rc_h
        beq @done
@second:
        lda #32
        sta rc_sub
        ora rc_ro0
        sta rowoff
        lda #2
        sta rowbit
        jsr @drawrow
        dec rc_h
        beq @done
@nextrow:                           ; one map row on
        lda ptr
        clc
        adc MAPSTRIDE
        sta ptr
        lda ptr+1
        adc MAPSTRIDE+1
        sta ptr+1
        jmp @rowy
@done:  rts
        ; ---- a fill, from @run's bpl (here, behind @drawrow, in its reach): the other
        ; fills to @solid; id 0, the level's solid, to @sol0 at the top of the bank
@fill:  bne @fx                     ; (Z from @run's load: 0 is the level's solid)
        jmp @sol0
@fx:    jmp @solid                  ; (C is set: set at every entry to @run)
        ; ---- id 0, the level's solid: one byte, the loader's (SOLIDF), stored down every
        ; line of the run.  It reads nothing from the bank, so it sits above the tiles
        ; (TILHI), out of the full code area below TILES -- still in this scope, for its
        ; jumps back into the loop.
        .pushseg
        .segment "TILHI"
        .assert * = TILES_END, error, "TILHI must start at TILES_END (defs.inc, the cfgs' B6H)"
@sol0:  lda #4                      ; (C is set at every entry to @run)
        sbc rc_subc                 ; chars in this run, as @tpset
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        asl
        tax
        asl
        asl
        sta tmp
        ldy rc_wrap
        beq :+
        adc sp                      ; C is clear: the asl's above shifted out zeros
        lda sp+1
  .if BHW
        adc ringneg
  .else
        adc #(256 - >RINGEND)
  .endif
        bcs @s0slow
:
  .if BHW
        lda @mt-2,x                 ; jmpx less its pha/pla
        sta jv
        lda @mt-1,x
        sta jv+1
@s0f:   lda #0                      ; SOLIDF: the fill, stored alone
        jmp (jv)
  .else
@s0f:   lda #0                      ; SOLIDF: the fill, stored alone
        jmpx @mt-2
  .endif
@s0slow:                            ; a run across the ring end (once a row at most): the
        lda @s0f+1                  ; pair cascade's char-at-a-time copy, as a pair
        sta tp
        sta tp+1
        jmp @fslow
@mt:    .word @m7, @m15, @m23, @m31
.macro MFIL k
        ldy #k
        sta (sp),y
        .repeat 7
        dey
        sta (sp),y
        .endrepeat
.endmacro
@m31:   MFIL 31
@m23:   MFIL 23
@m15:   MFIL 15
@m7:    ldy #7
        .repeat 6
        sta (sp),y
        dey
        .endrepeat
        sta (sp),y
        staz sp                     ; line 0 non-indexed
        jmp @advsp
        .popseg
@drawrow:
        inc rc_y                    ; the row this draws: nothing in @drawrow reads rc_y
        ; ---- screen base (per-rect ringaddr, +640 per row)
        lda rc_sp
        sta sp
        lda rc_sp+1
        sta sp+1
        ; a row spans <= 640 bytes: it can only cross the ring end if sp is within 768
  .if BHW
        cmp ringe3                  ; >RINGEND - 3 for the buffer being drawn
  .else
        cmp #(>RINGEND - 3)
  .endif
        lda #0
        sta rc_gi
        rol
        sta rc_wrap
        lda rc_sc0
        sta rc_subc
        lda rc_w
        sta cnt
        sec                         ; C is set at every entry to @run (@runend's sbc leaves
        ; it set on the loop back), so the sbc below needs no sec
@run:
        ldx rc_gi
        lda GATHERH,x               ; bit 7 clear: filled, not copied -- 0 the level's
        bpl @fill                   ; solid (id 0), $40 up a flat tile or the other solid
        sta tp+1                    ; a tile page, $80-$BF: the tile pointer's high byte
        lda GATHERL,x               ; every tile is in bank 6, selected once per tile row
        and #7                      ; the kind: 0 a full tile, 4..6 a half, 3 a mirror
        beq @full
        and rowbit                  ; a half tile: is this row its fill?  (A mirror's 3
        beq @hcopy                  ; is: @hfill tells them apart)
        jmp @hfill
@hcopy: lda GATHERL,x               ; no: the stored row -- (k&7)<<5 with this run's
        eor rowoff                  ; char offset less the row's 32: rowoff's bits
        and #$E0                    ; outside $E0 through the two eors
        eor rowoff
        bcs @tpsta                  ; (always: C is set at every entry to @run)
@full:  lda GATHERL,x
        ora rowoff                  ; (a full tile's lo byte is (id&3)<<6: bits 0-5 clear)
@tpsta: sta tp
@tpset:
        ; chars in this run: min(4 - rc_subc, cnt) -> rc_n, X = 2*rc_n, tmp = 8*rc_n
        lda #4
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
  .if BHW
        adc ringneg                 ; 256 - >RINGEND for the buffer being drawn
  .else
        adc #(256 - (>RINGEND))     ; = adc #$80: C set iff sp+1+C >= >RINGEND
  .endif
        bcs @slow
:
  .if BHW
        lda @jt-2,x                 ; jmpx less its pha/pla: every @b entry
        sta jv                      ; loads A before it reads it
        lda @jt-1,x
        sta jv+1
        jmp (jv)
  .else
        jmpx @jt-2
  .endif
@jt:    .word @b7, @b15, @b23, @b31
@slow:  ; a run that crosses the ring end: copy a char at a time through the fold.  It
        ; sits beside its test so that a branch reaches it (at most once per row).
@sc:    ldy #7                      ; X = 2*rc_n (@tpset's tax) counts the chars down
:       lda (tp),y
        sta (sp),y
        dey
        bpl :-
        lda tp                      ; a run stays inside its tile's 32-byte char row, so
        clc                         ; this never carries before the last char, and after
        adc #8                      ; that tp is dead (@run rewrites both bytes)
        sta tp
        spnext
        dex
        dex
        bne @sc
        jmp @runend                 ; (out of bra's reach from here)
        ; unrolled copy, one block per char in descending char order so that entry at
        ; char n-1 copies chars n-1..0.
.macro CPYN                         ; next line: A = (tp),y -> (sp),y ; y++
        lda (tp),y
        sta (sp),y
        iny
.endmacro
.macro CHARCPY c
.if c = 0
  .if ::BHW
        ldy #0                      ; line 0 (staz would reload the same 0 into Y)
        lda (tp),y
        sta (sp),y
        iny
  .else
        ldaz tp                     ; line 0 non-indexed
        staz sp
        ldy #1
  .endif
.else
        ldy #8*c
        lda (tp),y
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
@b31:   CHARCPY 3
@b23:   CHARCPY 2
@b15:   CHARCPY 1
@b7:    CHARCPY 0
@advsp: lda sp
        adc tmp                     ; C is already clear at every entry to @advsp
        sta sp
        bcc :+
        inc sp+1                    ; no ringup: both entries to @advsp have already
                                    ; proved the run stays below RINGEND (rc_wrap).
:
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
        adc #(<ROWBYTES)-1          ; C = 1: @runend's sbc cannot borrow (rc_n <= cnt)
        sta rc_sp
        lda rc_sp+1
        adc #>ROWBYTES
        ringup rc_sp
        sta rc_sp+1
        rts
  .if TILEMIRROR                    ; (cpu.inc: off by default -- no level needs a mirror)
        ; ---- a mirrored full tile: its source's chars right to left, each byte's two
        ; game pixels swapped -- ((b & $33) << 2) | ((b & $CC) >> 2); the dither is per
        ; game pixel, so a pixel's dots move as one.  A char at a time through spnext,
        ; which folds at the ring end: rare tiles (the packer mirrors only what the
        ; bank cannot hold, the least used first), so no unrolled copy.
@mir:   lda GATHERL,x
        and #$C0
        ora rc_sub                  ; the char row
        sta tp
        lda rc_subc                 ; the first char drawn is the source's 3 - rc_subc
        eor #3
        asl
        asl
        asl
        ora tp
        sta tp
        lda #4
        sec
        sbc rc_subc
        cmp cnt
        bcc :+
        lda cnt
:       sta rc_n
        sta tmp2
@mc:    ldy #7
:       lda (tp),y
        and #$33
        asl
        asl
        sta tmp
        lda (tp),y
        and #$CC
        lsr
        lsr
        ora tmp
        sta (sp),y
        dey
        bpl :-
        lda tp                      ; the source's char to the left (a run stays in its
        sec                         ; tile's char row: no borrow before the last char,
        sbc #8                      ; and after it tp is dead)
        sta tp
        spnext
        dec tmp2
        bne @mc
        jmp @runend
  .endif
        ; ---- fills: a flat tile, the other solid, a half tile's fill row -- no source
        ; bytes: a pair, even lines tp, odd tp+1, down every char (the level's solid,
        ; id 0, comes in at @fillgo from @sol0)
@solid: ldy GATHERL,x               ; the flat pair: even lines from tp, odd from tp+1
        lda FLATTAB,y               ; (tp is otherwise unused on this path)
        sta tp
        lda FLATTAB+1,y
        sta tp+1
        bcs @fillgo                 ; (always: C is set at every entry to @run)
@hfill:
  .if TILEMIRROR
        lda GATHERL,x               ; the kind: bit 2 clear is a mirror (3), set a half
        and #4
        beq @mir
  .endif
        lda GATHERH,x               ; the half's pair: k back out of its address
        sbc halfhi                  ; (C is set at every entry to @run)
        asl
        asl
        asl
        asl
        sta tmp                     ; (k >> 3) << 4
        lda GATHERL,x
        lsr
        lsr
        lsr
        lsr                         ; (k & 7) << 1: a half's GATHERL has bits 4 and 3 clear
        ora tmp
        tay
@hp0:   lda $FFFF,y                 ; lda HALFPAIR,y: the pair, from where the loader
        sta tp                      ; put the table (it patches both operands: HPAIR0,
@hp1:   lda $FFFF,y                 ; HPAIR1, defined after the row loop)
        sta tp+1
@fillgo:
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
        ldy rc_wrap                 ; test without destroying A (= 8*rc_n)
        beq :+
        adc sp                      ; C is clear: the asl's above shifted out zeros (rc_n <= 4)
        lda sp+1
  .if BHW
        adc ringneg
  .else
        adc #(256 - >RINGEND)
  .endif
        bcs @fslow                  ; (@fslow sits before the cascade: in reach on both)
  .if BHW
:       lda @ft-2,x                 ; jmpx @ft-2 less its pha/pla, and no load: A is
        sta jv                      ; dead, every entry is a FIL1, which loads tp+1
        lda @ft-1,x
        sta jv+1
        jmp (jv)
  .else
:       jmpx @ft-2
  .endif
@ft:    .word @f7, @f15, @f23, @f31
; the pair: even lines tp, odd lines tp+1 -- each byte loaded once a char and stored
; four times, every store setting its own Y (70 cycles a char, where alternating the
; loads down a dey chain was 88)
.macro PCHAR c
        lda tp
        ldy #8*c+6
        sta (sp),y
        ldy #8*c+4
        sta (sp),y
        ldy #8*c+2
        sta (sp),y
        ldy #8*c
        sta (sp),y
        lda tp+1
        ldy #8*c+7
        sta (sp),y
        ldy #8*c+5
        sta (sp),y
        ldy #8*c+3
        sta (sp),y
        ldy #8*c+1
        sta (sp),y
.endmacro
@fslow: lda rc_n
        sta tmp2
@fsc:   PCHAR 0
        spnext
        dec tmp2
        bne @fsc
        jmp @runend
@f31:   PCHAR 3
@f23:   PCHAR 2
@f15:   PCHAR 1
@f7:    PCHAR 0
        jmp @advsp

; @hfill's two loads of a half tile's pair: the table sits above the halves, wherever
; the level's tiles ended, and the loader patches the operands.  (Defined here, after
; the row loop: a label would end its @ scope, and := puts them in labels.txt.)
        .assert @hp1 = @hp0 + 5, error, "HPAIR1 must be 5 bytes past HPAIR0"
HPAIR0  := @hp0 + 1                 ; (the first := ends the @ scope: HPAIR1 goes by it)
HPAIR1  := HPAIR0 + 5
; (@s0f's operand, the solid's fill byte, is SOLIDF to the loader: build.sh finds the
; label in cleo.dbg, which lists cheap labels -- a symbol here would end the scope)

; ============================================================================
; scroll_validate: make the current buffer hold the window (wcx, wcy), ROWCHARS x
; BUFROWS, drawing only the strips it lacks
        .segment "TILCODE"          ; bank 6, with the row loop
scroll_validate:
        ldx curbuf                  ; (an invalid buffer holds BUF_CX = $80xx, which the
        txa                         ;  |dx| >= 80 test below sends to @full)
        asl
        tay
        ; dy = wcy - BUF_CY
        lda wcy
        sec
        sbc BUF_CY,x
        sta w16b
        ; dx = wcx - BUF_CX
        lda wcx
        sec
        sbc BUF_CX,y
        sta w16
        lda wcx+1
        sbc BUF_CX+1,y
        sta w16+1
        ; |dx| >= 80 -> full  (A still holds w16+1, flags still from the sbc)
        beq @dxpos
        cmp #$FF
        bne @full
        lda w16
        cmp #<-79
        bcc @full
        ; dx negative: draw cols wcx .. wcx+(-dx)-1, rows wcy..wcy+BUFROWS-1
        eor #$FF                    ; (A still holds w16)
        adc #0                      ; C = 1 from the cmp: A = -w16, and C = 0 (w16 <> 0)
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        bcc @docols                 ; C = 0 from the adc
@full:  ; (here, between two unconditional exits, in reach of every branch to it)
        lda wcy
        sta rc_y
        lda #BUFROWS
        sta rc_h
        bne @dorows                 ; BUFROWS <> 0
@dxpos: lda w16
        beq @dyc
        cmp #ROWCHARS
        bcs @full                   ; not taken: C = 0 for the adc
        ; dx positive: cols (oldcx+80) .. wcx+79 = dx cols starting at wcx+80-dx
        sta rc_w
        eor #$FF                    ; A = 255 - rc_w, C still 0 from the cmp above
        adc #ROWCHARS               ; A = ROWCHARS-1-rc_w, C = 1 (rc_w <= 79)
        adc wcx                     ; + wcx + 1 -> wcx + ROWCHARS - rc_w
        sta rc_x
        lda wcx+1
        adc #0
        sta rc_x+1
@docols:
        lda wcy
        sta rc_y
        lda #BUFROWS
        sta rc_h
        jsr drawrect
@dyc:   lda w16b
        beq @done
        bpl @dypos
        cmp #<-30
        bcc @full
        eor #$FF
        adc #0                      ; C = 1 from the cmp: A = -w16b, and C = 0
        sta rc_h
        lda wcy
        sta rc_y
        bcc @dorows                 ; C = 0 from the adc
@dypos: cmp #BUFROWS
        bcs @full                   ; not taken: C = 0 for the adc
        sta rc_h
        eor #$FF                    ; A = 255 - rc_h, C still 0 from the cmp above
        adc #BUFROWS                ; A = BUFROWS-1-rc_h, C = 1 (rc_h <= BUFROWS-1)
        adc wcy                     ; + wcy + 1 -> wcy + BUFROWS - rc_h
        sta rc_y
@dorows:
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
        lda #ROWCHARS
        sta rc_w
        jsr drawrect                ; (falls into @done)
@done:
        ldx curbuf
        stz BUF_BOTOK,x             ; the window moved: the slot below is stale again
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
        .segment "LGCCODE"          ; bank 7, with the records
match_sprites:
        ldx curbuf
        txa                         ; an invalid buffer (BUF_CX high byte $80: a level
        asl                         ; start, or a dirty list that overflowed) is about to
        tay                         ; be redrawn whole, so nothing in it is kept and
        lda BUF_CX+1,y              ; there is nothing to erase: its records go
        bpl @valid
        stz RECCNT,x
@valid: lda RECCNT,x
        cmp NSPR
        bcc :+
        lda NSPR
:       sta cnt                     ; n = min(RECCNT, NSPR)
        stz tmp4                    ; i
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
        lda SPR_ID,x
        cmpz rp                     ; (zp): offset 0 needs no index register
        beq @same
        ; two box-star frames at the same place overwrite each other exactly -- every
        ; pixel opaque, and each box covers the art of the frame before it -- so a
        ; frame change there needs no erase either
        cmp #BOXID0
        bcc @next
  .if BHW
        lda (rp),y                  ; Y = 0 from the cmpz above
  .else
        ldaz rp
  .endif
        cmp #BOXID0
        bcc @next
        lda #1                      ; 1 = a different frame of the same thing
        bne @pos
@same:  lda #2                      ; 2 = identical, so its pixels are already right
@pos:   sta tmp3
  .if BHW
        iny                         ; Y = 0 on both ways in (cmpz, ldaz)
  .else
        ldy #1
  .endif
        lda SPR_XL,x
        cmp (rp),y
        bne @next
        iny
        lda SPR_XH,x
        cmp (rp),y
        bne @next
        iny
        lda SPR_YL,x
        cmp (rp),y
        bne @next
        iny
        lda SPR_YH,x
        cmp (rp),y
        bne @next
        lda tmp3                    ; (X is still the sprite's number)
        sta KEEP,x                  ; same pixels in the same place: skip the erase
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc tmp4
        bne @l                      ; always: i+1 <= MAXSPR
@done:  rts

; erase_old: redraw tiles under old records that are not kept
        .segment "LGCCODE"          ; bank 7, with the records (the rects it redraws
erase_old:                          ; go to bank 6's drawrect_clip through callbank)
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
        bankimm lda, BANK_TILES, BANK_LVL   ; bank 6's BANKENTRY is drawrect_clip
        jsr callbank
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
        .segment "LGCCODE"          ; bank 7, with the logic that calls it
addsprite:
        ldx NSPR
        cpx #MAXSPR
        bcs @full
        sta SPR_ID,x
        lda spx
        sta SPR_XL,x
        lda spx+1
        sta SPR_XH,x
        lda spy
        sta SPR_YL,x
        lda spy+1
        sta SPR_YH,x
        inc NSPR
@full:  rts

; draw all listed sprites into current buffer (skipping unchanged kept ones)
        .segment "LGCCODE"          ; bank 7, with the prologue and the records
draw_sprites:
        ; Two passes.  A box star is an opaque rectangle with its background baked in,
        ; so it has to go down before anything that shares its space -- drawn in list
        ; order it would paint that background over whatever was standing there.
        lda #1
        sta dpass
@pass:  stz spi                     ; A dead: lda recp next
        lda recp
        sta rp
        lda recp+1
        sta rp+1
@l:     ldx spi                     ; X = the sprite's number: every field is ,x
        cpx NSPR
        bcs @endpass
        ldy SPR_ID,x                ; Y = id for both compares
        cpy #BOXID0
        lda dpass
        adc #$FF
        beq @next
        cpy #BOXID0+BOXN            ; a box star the logic says nothing can disturb, and
        bcc @write                  ; the same frame already in the same place: if
        lda KEEP,x                  ; nothing has been repainted under it, its pixels
                                    ; are still right, so leave it alone
        cmp #2
        bne @write
        ldy #9                      ; and it was not cut off at a window edge, so all
        lda (rp),y                  ; of it is on screen and still intact
        bpl @next
@write: ldy #1
        lda SPR_XL,x
        sta spx
        sta (rp),y
        iny
        lda SPR_XH,x
        sta spx+1
        sta (rp),y
        iny
        lda SPR_YL,x
        sta spy
        sta (rp),y
        iny
        lda SPR_YH,x
        sta spy+1
        sta (rp),y
        ldy #8
        lda #0
        sta (rp),y
        lda SPR_ID,x
        staz rp                     ; sta (rp) - offset 0 needs no index
        jsr drawsprite
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc spi
        bne @l                      ; spi <= NSPR: never wraps to 0
@endpass:
        dec dpass
        bpl @pass                   ; (in range on both machines)
        ldx curbuf
        lda NSPR
        sta RECCNT,x
        rts

; draw one sprite: A = id ; spx, spy = map px (ref point)
; Game sprites (spbank = BANK_SPR): the directory is the level's, in bank 7 at
; SPR_TABLE (ldprog.s); the data is in bank 4, or bank 5 when the entry's flag bit 4
; is set.
; Title pieces (spbank != BANK_SPR): directory and data both live at TITLE_ADDR of
; that bank.
        .segment "LGCCODE"          ; bank 7, with the records and SPRMASK
drawsprite:
  .if BHW
        ldx #0                      ; X is dead on entry (ldx spbank below)
        stx spclip                  ; set at every window edge the sprite is cut against
  .else
        stza spclip                 ; set at every window edge the sprite is cut against
  .endif
        cmp #BOXID0+BOXN            ; the "nothing can disturb it" aliases draw the same
        bcc :+                      ; picture as the ids BOXN below them
        sbc #BOXN
:
        sta sp_id
  .if BHW
        stx ptr+1                   ; X = 0 still
  .else
        stza ptr+1
  .endif
        asl                         ; id*8 -> offset
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        ldx spbank
        bankimm cpx, BANK_SPR, BANK_LVL
        bne @titledir
        adc #<(SPR_TABLE-1)         ; C = 1 from the cpx (X = BANK_SPR): the -1 takes it back
        .assert <SPR_TABLE <> 0, error, "drawsprite: adc #<(SPR_TABLE-1) needs <SPR_TABLE nonzero"
        sta ptr
        lda ptr+1
        adc #>SPR_TABLE
        sta ptr+1
        ldy #6
        lda (ptr),y
        sta sp_flags
        bankimm ldx, BANK_SPR, BANK_LVL
        and #$10                    ; bit 4: the data is in bank 5
        beq :+
        bankimm ldx, BANK_TIL1, BANK_LVL
:       stx sp_dbank            ; wanted later: the directory is still being read
        lda sp_id
        asl
        tax
        lda SPRMASK,x
        sta sp_mbase
        lda SPRMASK+1,x
        sta sp_mbase+1
        bcc @entry2                 ; C = 0 from the asl: sp_id < 128
@titledir:
        ; ---- title piece: directory + data at TITLE_ADDR of bank(spbank)
        pha                         ; the entry's low byte, kept across the mask fetch
        lda spbank              ; title pieces keep directory and data in one bank
        sta sp_dbank
        .assert <TITLE_ADDR = 0, error, "drawsprite: the title directory/mask arithmetic needs a page-aligned TITLE_ADDR"
        lda sp_id                   ; the entry and its mask's address come across
        asl                         ; through low RAM (dirfetch), the mask's first:
                                    ; dirfetch reuses ptr and MAPBUF.  C = 0
        adc #<(TITLE_ADDR+$80)
        sta ptr
        lda #>(TITLE_ADDR+$80)      ; no carry: 2*id < $80
        sta ptr+1
        jsr dirfetch
        lda MAPBUF
        sta sp_mbase
        lda MAPBUF+1
        sta sp_mbase+1
        pla
        sta ptr
        lda #>TITLE_ADDR
        sta ptr+1
        jsr dirfetch
        lda MAPBUF+6                ; dirfetch left ptr = MAPBUF
        sta sp_flags
@entry2:                            ; (title pieces: ptr = MAPBUF, dirfetch's copy)
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
        lsr
        sta sp_mh                   ; mask bytes per column group = pixel rows
        lda sp_flags
        and #2
        bne :+
        asl sp_ext                  ; half-res: two scanlines per stored row
:       ; ---- horizontal: sx = spx - refx - wx ; c0 = sx >> 1
        ldy #4
        lda (ptr),y
        and #$80                    ; sext inlined: the jsr/rts was 12 cycles of the 39
        beq @sxp
        lda #$FF
@sxp:   sta tmp3
        lda spx
        sec
        sbc (ptr),y
        tax
        lda spx+1
        sbc tmp3
        tay
        txa
        sec
        sbc wx
        sta w16
        tya
        sbc wx+1
        cmp #$80
        ror a                       ; sign into bit 7, old bit 0 out to C
        ror w16                     ; arithmetic shift right 1 -> c0 (16 bit)
        tax                         ; A still holds w16+1: just restore N,Z (X is dead)
        beq @cpos
        cmp #$FF
        bne @out0
        ; c0 negative (-128..-1): cstart = 0 ; visible if c0 + W > 0
        lda w16
        sbc #2                      ; C = 1 from the cmp #$FF: w16 >= $80, so C stays 1
        adc sp_w                    ; w16 - 2 + W + 1 = c0 + W - 1
        bmi @out0
        inc spclip
        sta sp_c1
        lda #0                      ; stz sp_c0, with the zero kept for the negate
        sta sp_c0
        ; first visible column index = -c0
        sbc w16                     ; C = 1 (bmi fall-through): A = -c0, 1..128
        sta sp_c                    ; starting image column
        bne @vert                   ; always: -c0 is never 0
@cpos:  lda w16
        cmp #ROWCHARS
        bcs @out0                   ; not taken: C = 0 for the adc below
        sta sp_c0
        adc sp_w
        sbc #0                      ; C = 0 still (c0 + W < 256): A - 1, as deca
        cmp #ROWCHARS
        bcc :+
        inc spclip                  ; and at the right
        lda #(ROWCHARS-1)
:       sta sp_c1
  .if BHW
        lda #0                      ; A is dead at @vert: no need to keep it
        sta sp_c
        beq @vert                   ; always (Z from the lda #0)
  .else
        stza sp_c
        bra @vert
  .endif
@out0:  rts
@vert:
        ; ---- vertical: sy = spy - refy - wy ; lb0 = 2*sy + wfine
        ldy #5
        lda (ptr),y
        jsr sext
        lda spy
        sec
        sbc (ptr),y
        tax
        lda spy+1
        sbc tmp3
        tay
        txa
        sec
        sbc wy
        tax
        tya
        sbc wy+1
        sta sp_lb0+1
        txa
        asl                         ; C = old bit 7, exactly what 'asl w16' left
        rol sp_lb0+1
        clc
        adc wfine
        sta sp_lb0
        bcc @nc
        inc sp_lb0+1                ; lb0 (16 bit signed)
        clc                         ; only this arm arrives with C set
@nc:
        ; lend = lb0 + ext - 1
  .if BHW
        ldx sp_ext                  ; X is dead here: ext - 1, carry kept
        dex
        txa
  .else
        lda sp_ext
        deca
  .endif
        adc sp_lb0
        sta w16
        lda sp_lb0+1
        adc #0
        sta w16+1                   ; w16 = lb1
        ; clip lstart = max(lb0,0) ; lend = min(lb1, BUFROWS*8-1)
        lda sp_lb0+1
        bmi @top
        bne @out0                   ; lb0 >= 256 -> below
        lda sp_lb0
        cmp #BUFROWS*8
        bcs @out0
        sta tmp                     ; lstart
        bcc @ck                     ; C = 0: the bcs above was not taken
@top:   lda w16+1
        bmi @out0                   ; lb1 < 0
        inc spclip                  ; cut off at the top
        sta tmp                     ; A = w16+1 = 0 here: lb0 < 0 <= lb1 < 256
@ck:    lda w16+1
        bne @clampend
        lda w16
        cmp #BUFROWS*8
        bcc :+
@clampend:
        inc spclip                  ; and at the bottom
        lda #BUFROWS*8-1
:       tax                         ; lend (X: tmp2 is not read again before the row loop sets it)
        cmp tmp
        bcc @out0
        and #7
        sta sp_ra1
        txa
        lsr
        lsr
        lsr
        sta sp_r1
        lda tmp
        and #7
        sta sp_ra0
        lda tmp
        lsr
        lsr
        lsr
        sta sp_r0                   ; sta sets no flags: Z still from the third lsr
@nopart:
        ; ---- record rect in current sprite record
        ldy #5
        lda wcx
        clc
        adc sp_c0
        sta w16                     ; @rows needs this same sum: keep it, don't rebuild it
        sta (rp),y
        iny
        lda wcx+1
        adc #0
        sta w16+1
        sta (rp),y
        iny
        lda wcy                     ; C = 0: wcx+1 <= $7F, so the adc #0 above cannot carry
        adc sp_r0
        sta (rp),y
        iny
  .if BHW
        ldx sp_c1                   ; width = c1 + 1 - c0 (X dead: ldx spclip below)
        inx
        txa
        sec
        sbc sp_c0
  .else
        lda sp_c1
        sec
        sbc sp_c0
        inca
  .endif
        sta (rp),y
        iny
        lda sp_r1
        sbc sp_r0                   ; C still set by the width sbc above (sp_c1 >= sp_c0)
        adc #0                      ; and set by this one (sp_r1 >= sp_r0): + 1
        ldx spclip
        beq :+                      ; may be visible next time and it has to be redrawn
        ora #$80
:       sta (rp),y
  .if BHW
        lda mrow                    ; the mirror's row, relative to the window: if the
        sec                         ; sprite covers it, note the columns (see drawrect)
        sbc wcy
        cmp sp_r0
        bcc @nomir
        cmp sp_r1
        beq @mir
        bcs @nomir
@mir:   lda sp_c0
        ldx sp_c1
        jsr mirdirty
@nomir:
  .endif
        ; ---- column base pointer & step
        lda sp_flags
        bitimm 1
        beq @nomirror
        ; mirror: image column = W-1-c (the column loop then steps backwards)
        clc
        lda sp_w
        sbc sp_c                    ; C=0 subtracts the extra 1: sp_w - sp_c - 1
        sta sp_c
        lda sp_flags                ; only the mirror arm clobbers A
@nomirror:
        ; ---- select the inner blitter once per sprite (patched jmp in the column loop)
        bitimm 8                    ; bit3: copy blitter
        beq :+
        ldx #8
        bne :++
:       and #3                      ; A is still sp_flags: bit #imm does not alter A
        asl
        tax
:
        stx sp_disp                 ; the loop copy in the data's bank patches its own jump
        lda sp_c
        and #3                      ; phase of the first column drawn, and its page:
        ora #>MASKTAB0              ; MASKTAB0 is 1K aligned, so phase = page & 3
        sta sp_mpg0
@rows:
        lda sp_r0
        sta sp_row
        ; screen base for (wcx + c0, wcy + r0): one ringaddr, then +80 chars per row
        ; (w16 = wcx + sp_c0 was already built when the record rect was written)
        clc
        adc wcy
        jsr ringaddr7               ; this bank's own copy (no crossing)
        sta sp_rb+1                 ; A = sp+1: ringaddr's last store
        lda sp
        sta sp_rb
        ; source row pointer = column base + r0*8 - lb0 (>>1 for half res); +8 (+4) per row
        lda tmp                     ; tmp is still lstart, and sp_r0 = lstart >> 3,
        and #$F8                    ; so r0*8 is lstart & $F8: no reload and no shifts
        sec
        sbc sp_lb0
        sta w16
        lda #0
        sbc sp_lb0+1
        sta w16+1
        ldx #8
        lda sp_flags
        and #2
        bne :+
        lda w16+1
        asl                         ; C = the sign: an arithmetic >> 1
        ror w16+1
        ror w16
        ldx #4
:       stx sp_rinc
        ; sp_rp = sp_ptr + w16 + sp_c * lines (the column base needs no copy of its own)
        lda sp_ptr
        clc
        adc w16
        tay
        lda sp_ptr+1
        adc w16+1
        sta sp_rp+1
        tya
        ldx sp_c
        beq @mdone
        clc
@mul:   adc sp_lines
        bcc :+
        inc sp_rp+1
        clc
:       dex
        bne @mul
@mdone: sta sp_rp
        stx mtab                    ; X = 0 here: the MASKTAB pages are indexed by the mask byte
        lda w16+1                   ; the same offset in pixel rows (signed >> 1)
        asl                         ; C = the sign
        ror w16+1
        ror w16
        ; mask row pointer = mask plane + (first image column / 4) * pixel rows + that offset
        lda sp_c
        lsr
        lsr
        tay                         ; column groups to step over
        lda sp_mbase
        clc
        adc w16
        tax
        lda sp_mbase+1
        adc w16+1
        sta sp_mrp+1
        txa
        cpy #0
        beq @mgdone
        clc
@mgrp:  adc sp_mh
        bcc @mgnc
        inc sp_mrp+1
        clc
@mgnc:  dey
        bne @mgrp
@mgdone: sta sp_mrp
        lda sp_c1
        sec
        sbc sp_c0
        sta sp_ncol                 ; columns-1
        ; the row loop and the inner blocks are assembled into each sprite data bank
        ; (SPRITE_LOOPS below): call the copy in the bank the directory named, through
        ; low RAM's direct switch (both banks enter at BANKENTRY) and back to this bank
        lda sp_dbank
        jmp callbank
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
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
  .if k = 0
    .if ::BHW
        sta (sp),y                  ; box sprite: Y = 0 still, from ldaz's ldy #0
    .else
        staz sp                     ; box sprite: every byte opaque, plain copy
    .endif
  .else
        sta (sp),y
  .endif
.else
  .if k = 0
        beq done                    ; 0: both pixels transparent, no store
        bpl masked                  ; (N from the load: cmp would set it from the subtraction)
        cmp #$C0
        bcc opaque                  ; bit7 alone: single opaque byte
        jmp solid                   ; bit 7+6: this and the next 7 bytes all opaque
masked: cmp #$41                    ; and the mirror image of that: this and the next 7
        beq blank                   ; all transparent, so the cell is left alone
  .else
        bmi opaque                  ; bit 7: both pixels opaque (see encode_sprite).  Tested
        beq done                    ; before the transparent case because the sprite data is
                                    ; 45.7% opaque against 24.1% transparent, and both read
                                    ; the same load's flags -- $00 is never negative
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
  .if mirror
        bra skip                    ; only the mirrored form has anything at 'opaque' to
  .endif                            ; jump over; unmirrored, this branched to the next
opaque:                             ; instruction, 3 cycles on every masked byte
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
        ldy #1
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        iny
        lda (ptr),y
        sta (sp),y
        jmp sprretP
.endif
.endif
name:
        lda tmp2
        cmp #7
  .if copy
        bne partial                 ; in reach: the copy form's lines are short
  .else
        bne @np
  .endif
        lda tmp
        beq l0                      ; the whole cell: the overwhelmingly common case, and
        asl                         ; it needs no table at all (the table's dispatch is
        tax                         ; 21 cycles to reach the same place)
  .if ::BHW
        lda et-2,x                  ; jmpx without its pha/pla: A is dead at l1..l7
        sta jv
        lda et-1,x
        sta jv+1
        jmp (jv)
  .else
        jmpx et-2                   ; X = 2..14: l0 is reached by the beq, not the table
  .endif
  .if .not copy
@np:    jmp partial
  .endif
et:     .word l1,l2,l3,l4,l5,l6,l7
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
pd:                                 ; l7's exit, and the partial loop's
        .if mirror
        jmp sprretM
        .else
        jmp sprretP
        .endif
partial:
        ldy tmp
.if copy
pl:     lda (ptr),y
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta (sp),y
.else
pl:     lda (ptr),y
        bmi po                      ; bit 7: both pixels opaque.  Tested before the
        beq ps                      ; transparent case for the same reason SPRLINE does
                                    ; it -- 45.7% opaque against 24.1% transparent, and
                                    ; both read this load's flags ($00 is never negative)
        cmp #$41
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
        iny                         ; Y < tmp2 <= 6: never wraps to 0
        bne pl
.endmacro

; ---- MODE 1 masked blitter.  A col entry has no spare bit, so the mask is a plane of
; its own: one bit per game pixel, a data byte's two pixels as a 2-bit pair, four
; horizontally adjacent columns packed into one byte (column 4g+j in bits 7-2j, 6-2j),
; column-group-major: for group g, one byte per pixel row -- the shape of the data, so
; mptr walks like ptr.  MASKTAB0..3 turn a whole mask byte into the AND mask for the
; column of that phase, no shifting: $FF (both transparent) $CC $33 $00 (both opaque).
; The two scanlines of a pixel row share a mask, so lines go in pairs, and a sprite's
; first line in a cell is always even (refy is a multiple of 4 game px).  The data has
; 0 in transparent pixels, so screen = (screen AND mask) OR data.  Mirrored: the pair's
; mask is SWAPTAB of the table's answer ($33 <-> $CC), and the data byte is swapped.
.macro MLINE mirror                 ; masked store of line Y
  .if mirror
        lda (ptr),y
        tax
        lda SWAPTAB,x
        sta sp_ext                  ; dead during the blit
        lda (sp),y
        and sp_msk
        ora sp_ext
  .else
        lda (sp),y
        and sp_msk
        ora (ptr),y
  .endif
        sta (sp),y
.endmacro
.macro CLINE mirror                 ; plain store of line Y
        lda (ptr),y
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta (sp),y
.endmacro
.macro MPAIR k, mirror              ; lines k, k+1 of the cell
        .local opq, done
  .if k = 0
        ldaz mptr                   ; (Master: lda (mptr); the tay reloads Y)
  .else
        ldy #k/2
        lda (mptr),y
  .endif
        tay
        lda (mtab),y
        beq opq                     ; $00: both pixels opaque, plain stores
        cmp #$FF
        beq done                    ; both transparent
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta sp_msk
        ldy #k
        MLINE mirror
        iny
        MLINE mirror
        bcc done                    ; C = 0: the cmp #$FF above was not equal
opq:    ldy #k
        CLINE mirror
        iny
        CLINE mirror
done:
.endmacro
.macro SPRMSK name, mirror
        .local partial, et, p0, p1, p2, p3, p2j, pl, pop, pnext
partial:                            ; lines tmp..tmp2: tmp even, tmp2 odd (above name, so
        lda tmp                     ; name's bne reaches it)
        sta sp_lim
pl:     lsr                         ; A = sp_lim on both ways in
        tay
        lda (mptr),y
        tay
        lda (mtab),y
        beq pop
        cmp #$FF
        beq pnext
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta sp_msk
        ldy sp_lim
        MLINE mirror
        iny
        MLINE mirror
        bcc pnext                   ; C = 0: the cmp #$FF above was not equal
pop:    ldy sp_lim
        CLINE mirror
        iny
        CLINE mirror
pnext:
  .if ::BHW
        inc sp_lim
        inc sp_lim
        lda sp_lim
  .else
        lda sp_lim
        inca
        inca
        sta sp_lim
  .endif
        cmp tmp2
        bcc pl
  .if mirror
        jmp sprretMk
  .else
        jmp sprretPk
  .endif
name:
        lda tmp2
        cmp #7
        bne partial
        lda tmp                     ; even: 0,2,4,6 -> entry p0..p3
        beq p0
        cmp #4
        bcc p1
  .if mirror
        beq p2j
        jmp p3
p2j:    jmp p2
  .else
        beq p2
        jmp p3
  .endif
p0:     MPAIR 0, mirror
p1:     MPAIR 2, mirror
p2:     MPAIR 4, mirror
p3:     MPAIR 6, mirror
  .if mirror
        jmp sprretMk
  .else
        jmp sprretPk
  .endif
.endmacro
; The row loop and the inner blocks, assembled once into EACH sprite data bank (the
; loop reads image bytes, so it must be resident with them) and reached through
; callbank from the prologue, which lives with the directory in bank 7.
.macro SPRITE_LOOPS withmirror, withcopy, bank   ; withmirror = 0: no mirrored blitter
                                    ; (the bank has no SWAPTAB); withcopy = 0: none drawn
                                    ; by the copy blitter (no sprFC); bank: this copy's
ds_entry:                           ; BANKENTRY: the dispatch jump is patched here,
        wrsel bank, bank            ; in the bank that owns it -- so the write bank is
        ldx sp_disp                 ; set here, not in low RAM's callbank (A = the bank)
        lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
ds_rowloop:
        lda sp_rb
        sta sp
        lda sp_rb+1
        sta sp+1
        lda sp_rp
        sta ptr
        lda sp_rp+1
        sta ptr+1
        lda sp_mrp
        sta mptr
        lda sp_mrp+1
        sta mptr+1
        lda sp_mpg0
        sta mtab+1
        ; ra range for this row
        stz tmp                     ; ra0' = 0 unless this is the first row
        lda sp_row
        cmp sp_r0
        bne :+
        ldx sp_ra0
        stx tmp
:       ldx #7
        cmp sp_r1
        bne :+
        ldx sp_ra1
:       stx tmp2                    ; ra1'
        lda sp_ncol
        sta sp_cnt                  ; columns-1 (countdown)
ds_colloop:
ds_dispatch:
        jmp sprFN                   ; operand patched per sprite
  .if withmirror
sprdisp_tab: .word sprFN, sprFM, sprFN, sprFM
  .else
sprdisp_tab: .word sprFN, sprFN, sprFN, sprFN
  .endif
  .if withcopy
        .word sprFC
  .else
        .word sprFN
  .endif
  .if withmirror
sprretMk:                           ; mask blitter, mirrored: the image column descends,
        dec mtab+1                  ; so the phase (= page & 3) does too; below phase 0
        lda mtab+1                  ; it is the previous group's phase 3
        cmp #>(MASKTAB0-$100)       ; (mtab+1 stays in MASKTAB0..3: only below 0 wraps)
        bne @mk
        lda #>MASKTAB3
        sta mtab+1
        lda mptr                    ; C = 1 from the cmp (equal)
        sbc sp_mh
        sta mptr
        bcs @mk
        dec mptr+1
@mk:
sprretM:                            ; next column, mirrored: source pointer - lines
        lda ptr
        sec
        sbc sp_lines
        sta ptr
        bcs sprnext
        dec ptr+1
        bcc sprnext                 ; C = 0: the bcs was not taken
  .endif
sprretPk:                           ; mask blitter: next phase is the next page; past
        inc mtab+1                  ; phase 3 it is the next group's phase 0
        lda mtab+1
        and #3
        bne @pk
        lda #>MASKTAB0              ; past MASKTAB3: back to MASKTAB0
        sta mtab+1
        lda mptr
        clc
        adc sp_mh
        sta mptr
        bcc @pk
        inc mptr+1
@pk:
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
        lda sp_rp                   ; C = 0: sp_row < sp_r1 (the rows count up to it)
        adc sp_rinc
        sta sp_rp
        bcc :+
        inc sp_rp+1
        clc
:
        lda sp_mrp
        adc #4                      ; C is clear
        sta sp_mrp
        bcc @mrnc
        inc sp_mrp+1
        clc
@mrnc:
        lda sp_rb
        adc #<ROWBYTES
        sta sp_rb
        lda sp_rb+1
        adc #>ROWBYTES
        ringup sp_rb
        sta sp_rb+1
        jmp ds_rowloop
ds_done: rts

        SPRMSK sprFN, 0
  .if withmirror
        SPRMSK sprFM, 1
  .endif
.endmacro
        .segment "SPR4CODE"
        .scope spr4
        SPRITE_LOOPS 1, ::SPR4_COPY, ::BANK_SPR   ; (assets.inc: the packer puts the box stars in one
        .if ::SPR4_COPY             ;  bank and no mirrored image in the other)
        SPRFULL sprFC, 0, 1
        .endif
        .endscope
        .assert spr4::ds_entry = BANKENTRY, error, "bank 4's row loop must start the bank"
  .if BHW                           ; (the Master's is shorter: its gap is the price of
        .assert * = B4_CODE_END, error, "bank 4's code must end where its sprites start: set B4_CODE_END in tools/assets.py"
  .else                             ;  level files both machines read)
        .assert * <= B4_CODE_END, error, "bank 4's code runs into its sprites: B4_CODE_END in tools/assets.py"
  .endif
        .segment "SPR5CODE"
        .scope spr5
        SPRITE_LOOPS ::SPR5_MIRROR, 1, ::BANK_TIL1
        SPRFULL sprFC, 0, 1
        .endscope
        .assert spr5::ds_entry = BANKENTRY, error, "bank 5's row loop must start the bank"
        .segment "TILCODE"     

; Every image is full-res, so entries 0/1 of sprdisp_tab (the half-res flag clear)
; alias the full blitters: the flag bit is vestigial.

; ============================================================================
; copy_partial: copy lines wfine..7 of ring row wcy into lines 0..(7-wfine) of the
; ring row above the window (the "A" section's source), all 80 columns.
; ============================================================================
        .segment "LGCCODE"          ; bank 7, beside render_core
copy_partial:                       ; the whole row, every frame the fine scroll is not 0
        lda wfine                   ; (tracking the columns drawn since the last copy
        bne :+                      ;  saves under 0.3% of a frame: measured)
        rts
:
        lda #ROWCHARS
        sta cnt
        lda #0
        sta tmp4                    ; first column to copy
        clc
        adc wcx
        sta w16
        lda wcx+1
        adc #0
        sta w16+1
  .if BHW
        lda barq                    ; the composed row is the ring row above the window,
        bne @nomir                  ; the last slot when the window starts at slot 0
        lda tmp4                    ; C = 0 from the w16+1 adc (wcx < $8000)
        adc cnt
        tax
        dex
        lda tmp4
        jsr mirdirty                ; (bank 7's copy)
@nomir:
  .endif
        lda wcy
        jsr ringaddr7               ; sp = source start (row wcy, column wcx)
        ; source: sp is the char, and the copy starts wfine lines into it.  Offsetting
        ; sp by wfine (under 8, and a char is 8-aligned) keeps its page crossings on
        ; the real char boundaries, so spnext's fold still lands where it should
        lda sp
        clc
        adc wfine
        sta sp
        ; dest: the same column of the composed row, ring char (ringS + col - 80)
        ; mod RINGCHARS -- the row above the window -- as a real address in the ring
        lda tmp4                    ; C = 0: sp was a char (8-aligned) + wfine (< 8)
        adc #<(-ROWCHARS)           ; ringS + tmp4 - 80: this low add cannot carry (tmp4 <= 79)
        adc ringS
        sta ptr
        lda ringS+1
        adc #$FF                    ; C = 1: >= 0, already in the ring
        bcs @pnf
  .if BHW
        tax                         ; < 0: + RINGCHARS, 16 bit (23 rows is not whole pages)
        lda ptr
        adc #<RINGCHARS
        sta ptr
        txa
  .endif
        adc #>RINGCHARS
@pnf:   asl ptr                     ; char -> byte address (A:ptr), + RINGBASE (the rols
        rol                         ; leave C clear: the offset is under $5000)
        asl ptr
        rol
        asl ptr
        rol
  .if BHW
        tax
        lda ptr                     ; the base is xx80, and which xx is the buffer's
        adc #<RING_A
        sta ptr
        txa
        adc ringbhi
  .else
        adc #>RINGBASE
  .endif
        sta ptr+1
        ; Y is the dest line, 0..7-wfine, and the source line is Y + wfine through the
        ; offset sp: enter the unrolled copy at the pair for this wfine.  (A loop here
        ; is 40 bytes smaller and ~1% of a frame slower: every frame with vertical
        ; movement recomposes all 80 columns.)
        ldx wfine
        lda @ftab-2,x               ; the branch displacement for this wfine
        sta @fjmp+1
        ldx cnt                     ; char counter in X: dex/beq is 3 cycles cheaper
@fjmp:  bne @g4                     ; patched; always taken: Z = 0 at every arrival
@ftab:  .byte @g4-@ftab, 0, @g2-@ftab, 0, @g0-@ftab   ; wfine 2: six lines, 4: four, 6: two
@g4:    ldy #5
        lda (sp),y
        sta (ptr),y
        dey
        lda (sp),y
        sta (ptr),y
@g2:    ldy #3
        lda (sp),y
        sta (ptr),y
        dey
        lda (sp),y
        sta (ptr),y
@g0:    ldy #1
        lda (sp),y
        sta (ptr),y
        dey
        lda (sp),y
        sta (ptr),y
        ; next char, both with the ring fold on the page crossing: the composed row
        ; can straddle the ring end like any other row
        spnext
        dex
        beq @done
        lda ptr
        clc
        adc #8
        sta ptr
        bcc @fjmp
        lda ptr+1
        adc #0                      ; C = 1: the bcc fell through; ringup's cmp resets it
        ringup ptr
        sta ptr+1
        bne @fjmp                   ; Z = 0: A is a ring high byte, never 0
@done:  rts

; ============================================================================
; blank_below: the 6845 always displays the first scanline of a frame, whatever R6
; says, so the blanking section's row 0 line 0 -- the ring slot below the playfield --
; is one line more under the picture.  Elsewhere it is the next map line; parked on
; the map's bottom row it is whatever that never-drawn slot last held.  So when the
; window sits on the bottom row, blank the slot, once per buffer per arrival.
; ============================================================================
        .segment "LGCCODE"          ; bank 7, beside render_core
blank_below:
        lda wfine
        bne @no
        lda wy
        cmp maxwy
        bne @no
        lda wy+1
        cmp maxwy+1
        bne @no
        ldx curbuf
        lda BUF_BOTOK,x
        bne @no
        inc BUF_BOTOK,x
        lda wcx                     ; the row below the playfield: map char row
        sta w16                     ; wcy + VISROWS at the window's column -- rows
        lda wcx+1                   ; are not slot aligned, so this is a run of 80
        sta w16+1                   ; chars that may straddle the ring end
        lda wcy
        adc #VISROWS-1              ; C = 1 from cmp maxwy+1 (equal)
        jsr ringaddr7               ; sp = its ring address
        ldx #ROWCHARS
@char:  lda #0
        ldy #7
@b:     sta (sp),y
        dey
        bpl @b
        spnext                      ; 8 on, folding at the ring end
        dex
        bne @char
@no:    rts

; ============================================================================
; bar_bg: the bar has a fixed home outside the ring, so it stays put however the
; window scrolls and is only written when its contents change (in the ring it would
; move with every vertical scroll: 1280 bytes to copy again, 13,310 cycles).  Its
; template (icons, labels, blank digit slots) is the BAR file, which the
; loader puts in place with the title (ldprog.s) and nothing redraws.  The template
; buries the digits, so this resets the digit cache: its "already drawn" values are
; no longer true.  One bar, one cache: not one per buffer.
; ============================================================================
        .segment "LGCCODE"
bar_bg:
        ldx #8
        lda #$FF
@bci:   sta BARCACHE,x
        dex
        bpl @bci
        rts

; ============================================================================
  .if .not BHW                   ; (Model B: its rupture chain is display.s)
        .segment "LGCCODE"          ; bank 7, with the logic: this touches nothing but
                                    ; main RAM and the CRTC
; build_sections: fill SECTAB for the current buffer from ringS and wfine.
; entry i: R12n, R13n, R4, R9, R6, R7, T1lo, T1hi (T1 = duration of section i+1)
;
; The bar has a fixed home; the composed row and the playfield walk the ring.  A row
; that straddles the ring end is folded by the CRTC, so the playfield is always one
; section however the window sits.
; ============================================================================
LINE = 64
BARLEAD = 10                        ; us the bar's T1 fires early, beyond the lead every
                                    ; step has, so ACCCON D can be switched in the
                                    ; blanking of the bar's last line
BARCRTC  = BARADDR / 8
        .code
        .segment "LGCCODE"          ; back to the bank
build_sections:
        lda curbuf
        asl
        tax
        lda #>BARCRTC               ; section 0 is the bar: fixed address, fixed length
        sta BUF_SEC0,x
        lda #<BARCRTC
        sta BUF_SEC0+1,x
        lda #<(BARROWS*8*LINE-2-BARLEAD)   ; the bar's step fires early: see the ISR
        sta BUF_SEC0T1,x
        lda #>(BARROWS*8*LINE-2-BARLEAD)
        sta BUF_SEC0T1+1,x
        txa                         ; X = curbuf*2: Z iff curbuf = 0, and then X is 0
        beq :+
        ldx #48
:       lda #1
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
        eor #7                      ; wfine is still in A from the test above
        inca                        ; 8-f lines of it
        jsr @dur
        lda ringS                   ; section A shows the composed row: the ring row
        sec                         ; above the window, ringS - 80 mod RINGCHARS
        sbc #ROWCHARS
        sta w16
        lda ringS+1
        sbc #0
        bpl :+
        adc #>RINGCHARS             ; went below 0: + RINGCHARS (whole pages; C clear)
:       sta w16+1
        jsr @addr
        txa
        adc #8                      ; C = 0 out of @addr: its sum is under $1000
        tax                         ; A's entry
        stz SECTAB+2,x
        lda wfine
        eor #7                      ; 7 - wfine, wfine in 0..7
        sta SECTAB+3,x
        lda #2
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda ringS                   ; the run starts one row into the window
        adc #ROWCHARS               ; C = 0 from the adc #8 above
        sta w16
        lda ringS+1
        adc #0
        sta w16+1
        jsr @wrap
        lda #VISROWS-1
        sta tmp4                    ; rows in the run

        bra @run
@coarse:                            ; ---- f = 0 : T -> P.. -> Q
        lda ringS
        sta w16
        lda ringS+1
        sta w16+1
        lda #VISROWS
        sta tmp4

@run:   ; w16 = the run's ring offset, tmp4 = its rows, X = the entry of the section
        ; before it.  Entry i carries section i+1's address and duration, and section
        ; i's own R4/R9/R6/R7, so each section is written across two entries.
        ; The run is never split: a row that straddles the ring end is folded by
        ; the CRTC.
        lda tmp4
        sta tmp2
        jsr @emit
@past:  lda tmp4
        jsr @advance                ; now the row below the playfield
        jsr @addr                   ; P2, or else Q, starts on the row below the playfield
        lda wfine
        beq @sq2
        ; --- P2 : the top f lines of that row
        jsr @dur
        txa
        clc
        adc #8
        tax
        stza SECTAB+2,x             ; stz abs,x
        lda wfine
        deca
        sta SECTAB+3,x
        lda #VISROWS
        sta SECTAB+4,x
        lda #30
        sta SECTAB+5,x
        lda SECTAB-8,x              ; w16 has not moved since the P2 @addr above, so the
        sta SECTAB,x                ; address it left in the previous entry is this one's
        lda SECTAB-8+1,x
        sta SECTAB+1,x
@sq2:   lda #<(40*LINE-2)
        sta SECTAB+6,x
        sta SECTAB+8+6,x            ; Q's own entry (X+8) carries the same duration
        lda #>(40*LINE-2)
        sta SECTAB+7,x
        sta SECTAB+8+7,x
        lda #>BARCRTC               ; and hands the chain back to the bar
        sta SECTAB+8,x
        lda #<BARCRTC
        sta SECTAB+8+1,x
        lda #QROWS-1
        sta SECTAB+8+2,x
        lda #7
        sta SECTAB+8+3,x
        stza SECTAB+8+4, x
        lda #QVSYNC
        sta SECTAB+8+5, x
        ; the bar's step fired BARLEAD early, so the section after the bar -- whose
        ; duration entry 0 carries -- runs BARLEAD longer to end where it should
        ldx curbuf
        beq @e0
        ldx #48
@e0:    lda SECTAB+6,x
        adc #BARLEAD                ; C = 0: the last carry-writer was the adc #8 above
        sta SECTAB+6,x
        bcc @e1
        inc SECTAB+7,x
@e1:    rts
; --- emit a run of tmp2 rows starting at w16 (a ring offset), following entry X
@emit:  jsr @addr
        lda tmp2
        jsr @lines
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
; --- SECTAB+0/1,x = the CRTC address for the row at ring offset w16.  Ring offsets are
; 0..RINGCHARS-1 and CRTCBASE is $600, so the sum is always under $1000 and MA12 is
; clear: a section's START address never needs folding.  The fold happens mid-scan, in
; hardware, which is the whole reason the ring begins at $3000.
        .assert <CRTCBASE = 0, error, "@addr adds the high byte only"
@addr:  lda w16
        sta SECTAB+1,x
        lda w16+1
        clc
        adc #>CRTCBASE
        sta SECTAB,x
        rts
        ; --- A = rows -> A/tmp3 = that many rows of lines, as a T1 count
@lines: asl
        asl
        asl
        jmp @dur
        ; --- A = rows: advance w16 by that many rows, folding into 0..RINGCHARS-1
@advance:
        tay
        clc
        lda w16
        adc mulrowlo,y
        sta w16
        lda w16+1
        adc mulrowhi,y
        sta w16+1
        ; fall through
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
; A = lines -> SECTAB+6/7,x = lines*64-2 (every caller stored it), A = tmp3 = hi
@dur:   sta tmp3                    ; n*64 == (n*256)>>2: start from hi=n, lo=0 and
        lda #0                      ; shift right twice instead of left six times
        lsr tmp3
        ror
        lsr tmp3
        ror
        sbc #1                      ; C = 0 out of the ror pair, so this is A - 2
        bcs :+
        dec tmp3
:       sta SECTAB+6,x
        lda tmp3
        sta SECTAB+7,x
        rts

  .endif

        .segment "TILCODE"     

BARROWS = 2                        ; the status bar
QROWS  = 39 - VISROWS - BARROWS    ; blank rows after the display: 312 lines in all
  .if BHW
QVSYNC = 8                         ; vsync at Q row 8 of 16: the picture starts 64 lines after
                                   ; it, 4 lines below where a MODE 1 screen sits
  .else
QVSYNC = 3                         ; vsync at Q row 3 of 7: four rows (32 lines) between the
                                   ; vsync and the bar, which is where the bar is drawn, and
                                   ; three below.  Measured against the Master MOS's own
                                   ; standard frame (R7 = 35): the picture sits exactly
                                   ; where it does.
  .endif

; ============================================================================
; Frame control
; ============================================================================
; select_backbuf: point the blitters at the current back buffer -- on the Master CPU
; access to its RAM (ACCCON X), on the Model B its ring's constants -- and the
; sprite records at its half
        .segment "TILCODE"          ; bank 6 (it patches ringaddr's operand)
select_backbuf:
  .if BHW
        ldx curbuf                  ; the buffer's ring: its base and end, the two
        lda @bhi,x                  ; derived constants the blitters' wrap tests use,
        sta ringbhi                 ; and its row table for ringaddr
        lda @ehi,x
        sta ringehi
        sec
        sbc #3
        sta ringe3
        lda #0
        sbc ringehi                 ; C = 1 still: ringehi >= 3, so the sbc #3 kept it
        sta ringneg
  .else
        php                         ; the ISR writes ACCCON's D bit; this read-modify-
        sei                         ; write of the X bit must not straddle one
        lda ACCCON
        and #$FB
        ldx curbuf
        beq :+
        ora #$04
:       sta ACCCON
        plp
  .endif
        lda @rlo,x                  ; X = curbuf (0/1): its sprite record base
        sta recp
        lda @rhi,x
        sta recp+1
  .if BHW
        lda @thl,x                  ; ringaddr's high bytes: this buffer's table
        sta RINGHIOP
        lda @thh,x
        sta RINGHIOP+1
        rts
@thl:   .byte <RINGHI, <RINGHI_B
@thh:   .byte >RINGHI, >RINGHI_B
@bhi:   .byte >RING_A, >RING_B
@ehi:   .byte >RINGEND_A, >RINGEND_B
  .else
        rts
  .endif
@rlo:   .byte <SPRREC, <(SPRREC+MAXREC*10)
@rhi:   .byte >SPRREC, >(SPRREC+MAXREC*10)

; render everything queued for the current back buffer and request flip
        .segment "LGCCODE"          ; bank 7, with the game loop
render_frame:
        jsr wait_flip               ; the previous frame's flip must land before this
                                    ; buffer is touched
        ; ---- the bar first.  It is single buffered and drawn where it is displayed,
        ; so it has to be finished before the CRTC reaches it: T starts QROWS-QVSYNC
        ; rows after the vsync wait_flip just returned from (32 lines on the Master,
        ; 64 on the Model B).  Only digits: the template comes with the title (the BAR
        ; file) and nothing erases it -- the menus keep to the ring (menu_sections).
        lda BARDIRTY
        beq :+
        jsr t_redraw_hud
  .if BHW
        dec BARDIRTY                ; only ever set to 1: 1 -> 0
  .else
        stz BARDIRTY
  .endif
:
        ; derive char window
        lda wx+1
        lsr
        sta wcx+1
        lda wx
        ror
        sta wcx
        lda wy
        and #3
        asl
        sta wfine
        lda wy+1                    ; wcy = wy >> 2, a full 16-bit shift: the tall maps
        lsr                         ; go past wy = 512, where shifting the high byte
        sta wcy                     ; once only loses 128 rows
        lda wy
        ror
        lsr wcy
        ror
        sta wcy
        jsr render_core
        stz NSPR                    ; A dead: build_sections starts ldx/lda
        jsr build_sections
        ; hand over to ISR
        lda curbuf
  .if .not BHW
        sta NEXTBUF
  .endif
        beq :+
        lda #48
:       sta NEXTSECT
        lda #1
        sta flipreq
render_done:                        ; (label for the phase timer harness)
        ; no wait here: the next logic step runs while the flip is pending and
        ; the next render_frame waits for it before touching the buffer
        eor curbuf                  ; A = 1: curbuf ^ 1
        sta curbuf
        rts

; spin until any pending flip has been taken by the vsync ISR
wait_flip:
        lda flipreq
        bne wait_flip
        rts

; menu_sections: the menus' frame.  build_sections, then buffer 0's first section (the
; bar's, in play) shows two ring rows below the window instead: the menus never draw
; there and clear_ring has made them black, so the menus look as they did but the bar
; is neither shown nor touched while they run -- it is laid once and left in place.
MENUBAR  = (RING0 + VISROWS*ROWBYTES) / 8
        .assert VISROWS + BARROWS <= RINGROWS, error, "the menus' bar rows must be in the ring"
menu_sections:
        jsr build_sections
        lda #>MENUBAR
        sta BUF_SEC0
        lda #<MENUBAR
        sta BUF_SEC0+1
        rts

; ---------------------------------------------------------------- load mode
; A disc load stops the chain: the loader runs with interrupts off (disc.s).  Stopped
; mid-chain the CRTC repeats whatever section
; it was in -- a few lines over and over, no vsync -- and monitors and capture cards
; drop out of sync and take seconds to come back, so a level's first moments are
; missed.  So a load first asks the chain to stop at a frame boundary: the next bar
; step programs a standard 39-row frame instead of the bar, with the vsync on the
; row the chain puts it, so the sync never moves, and turns the T1 interrupt off.
; The palette is black throughout, so what the frame shows does not matter.
; load_end lets the next vsync re-arm the chain: its re-phase writes R4 = curR7 +
; QROWS-1-QVSYNC, which with curR7 = LDR7 is the standard frame's own total, and the
; bar step at that frame's end takes the display back as if it had never stopped.
LDR4 = BARROWS + VISROWS + QROWS - 1      ; 38: a standard 312-line frame
LDR7 = BARROWS + VISROWS + QVSYNC         ; the row the chain's vsync is on
; On both machines the switch is the interrupt handler's bar step (@ldsw: below for
; the Master, display.s for the Model B), so it happens at the frame boundary however
; long the handler's other work runs.  (Polling for the bar's T1 with interrupts off
; does not: when the vsync's own work runs past that T1, the switch lands one section
; late and makes a short frame.)
load_begin:
        lda #1
        sta LOADREQ
:       lda LOADREQ
        cmp #2
        bne :-
        rts
load_end:                           ; (with interrupts off: disc.s)
        lda #3                      ; resume asked: the next real vsync arms T1, turns
        sta LOADREQ                 ; its interrupt on and clears this (curR7 holds
        lda #$42                    ; LDR7 from the switch); until then a T1 flag is
        sta VIA_IFR                 ; stale.  A vsync flag raised meanwhile is stale too
        rts

        .segment "LGCCODE"          ; bank 7 drives the frame and keeps the records; bank
render_core:                        ; 6 gets two fixed calls a frame (low RAM's selbb and
        jsr selbb                   ; validate) and the rects through callbank
        jsr calc_ring
        jsr match_sprites
        jsr erase_old
        jsr validate                ; scroll_validate (bank 6: it draws the new strips)
        jsr draw_dirty              ; (bank 7 from here: the rects through callbank)
        jsr blank_below
        jsr draw_sprites
        jsr copy_partial
    .if BHW
        jmp mirror_copy             ; the straddling row's copy (display.s)
    .else
        rts                         ; (the hardware folds the straddling row)
    .endif


; ---------------------------------------------------------------- the gather, in bank 5
; A tile row's ids, straight from the map (ptr, the row's first tile; rc_nt+1 of them),
; into GATHERL/GATHERH in low RAM, which the row loop in bank 6 reads: low RAM's
; mapstrip pages this bank in around it.  The Master's gather is a table (LV_PAGE0);
; the Model B's is arithmetic, on the level's half shape (zero page) and mirror shape
; (below), both the loader's.
        .segment "MAP5CODE"
gather5:
        ldy rc_nt
@gl:
  .if .not BHW
        ; the Master: the map row read in place (this is bank 5), then the table --
        ; LV_PAGE0 in main RAM, the level's (the loader's) -- gives the pair the Model
        ; B's gather below computes
        lda (ptr),y
        tax
        lda LV_PAGE0,x
        sta GATHERL,y
        lda LV_PAGE0+$100,x
        sta GATHERH,y
        dey
        bpl @gl
  .else
        ; the tiles are contiguous from TILES (page aligned, 64 bytes each), so the
        ; address is arithmetic: no table beside them.  Id 0 (the level's solid) and
        ; the ids from FLAT0 are fills, flagged by a high byte with bit 7 clear: 0 for
        ; the solid, $40 for a flat tile -- two bytes alternating down every char, the
        ; low byte indexing the pair in FLATTAB (the loader's; the two solids are its
        ; last two entries, for a level's other solid).
        ; Between the full tiles and the flats are the HALF tiles (ids from half0,
        ; the loader's): one 32-byte char row stored at halfhi:00 + k*32, the other
        ; either a fill (its pair in HALFPAIR) or the same row again.  Their low byte
        ; carries the flags: bit 2 = a half, bit 0 = the top row is the fill, bit 1 the
        ; bottom (neither: both rows are the stored one).
        lda (ptr),y
        beq @gsol                   ; id 0: the solid, a zero high byte (GATHERL unread)
        cmp #FLAT0
        bcs @gflat
        cmp half0
        bcs @ghalf
        tax
        lsr
        lsr
        clc
        adc #>TILES
        sta GATHERH,y
        txa
        and #3
        lsr
        ror
        ror                         ; (id & 3) << 6
        sta GATHERL,y
        dey
        bpl @gl
        bmi @gdone
@gsol:  sta GATHERH,y
        dey
        bpl @gl
        bmi @gdone
@gflat: sbc #FLAT0                  ; (C is set)
        asl
        sta GATHERL,y
        lda #$40                    ; a fill (the row loop's bpl), not the solid (0)
        sta GATHERH,y
        dey
        bpl @gl
        bmi @gdone
@ghalf:
  .if TILEMIRROR
        cmp mir0
        bcs @gmir
  .endif
        tax                         ; X = the id, for the range tests
        sbc halfsub                 ; k, the slot from the halves' page: C is clear after
                                    ; the mirror test (halfsub = half0 - HALFOFF - 1), set
                                    ; without it (the loader's halfsub = half0 - HALFOFF)
        sta tmp
        lsr
        lsr
        lsr
        clc
        adc halfhi5
        sta GATHERH,y
        lda tmp
        asl
        asl
        asl
        asl
        asl                         ; (k & 7) << 5: the shifts drop the rest
        cpx half1                   ; a half: bit 2, the fill row's flag by range:
        adc #5                      ; below half1 4|1 (top fills), else 4|2 (C from cpx)
        cpx half2
        bcc @gh2                    ; below half2: done
        eor #2                      ; from half2 (so from half1): 6 -> 4, both stored
@gh2:   sta GATHERL,y
        dey
        bpl @gl
        bmi @gdone
  .if TILEMIRROR
@gmir:  sbc mir0                    ; a mirrored tile: its source's slot (C is set),
        tax                         ; addressed as a full tile's, kind 3
        lda MIRTAB,x
        tax
        lsr
        lsr
        clc
        adc #>TILES
        sta GATHERH,y
        txa
        and #3
        lsr
        ror
        ror                         ; (slot & 3) << 6
        ora #3
        bne @gh2                    ; (always)
  .endif
    .endif
@gdone: rts
; the title pack's directory entries and mask addresses: the eight bytes at (ptr)
; into MAPBUF, ptr left pointing at the copy (low.s dirfetch)
fetch8:
        ldy #7
:       lda (ptr),y
        sta MAPBUF,y
        dey
        bpl :-
        lda #<MAPBUF
        sta ptr
        lda #>MAPBUF
        sta ptr+1
        rts
        .segment "MAP5BSS"          ; the level's mirror shape (the loader's), for the
  .if BHW                           ; Model B's arithmetic gather (the half shape,
   .if TILEMIRROR                   ; half0-halfsub, is in zero page)
mir0:      .res 1                   ; the first mirrored tile's id (the loader's)
MIRTAB:    .res MAXMIR              ; per mirrored id: the slot of the tile it mirrors
   .endif
  .endif
  .if BHW
        .assert * = B5_CODE_END, error, "bank 5's code must end where its sprites start: set B5_CODE_END in tools/assets.py"
  .else
        .assert * <= B5_CODE_END, error, "bank 5's code runs into its sprites: B5_CODE_END in tools/assets.py"
  .endif
        .segment "TIL6ENT"         ; the start of bank 6
; ============================================================================
; callbank's way into this bank (BANKENTRY): the write bank first -- A is the bank, as
; callbank left it -- then drawrect_clip
bank6_entry:
        .assert * = BANKENTRY, error, "bank6_entry must start bank 6"
        wrsel BANK_TILES, BANK_TILES
; drawrect_clip: drawrect, with the rect clipped to the current window
; (rows wcy..wcy+BUFROWS-1, cols wcx..wcx+ROWCHARS-1)
drawrect_clip:
        ; rows
        lda rc_y
        sec
        sbc wcy                     ; rel row start (may be negative), kept in A
        bpl :+
        ; start above window: shrink
        clc
        adc rc_h
        beq @none
        bmi @none
        sta rc_h
        lda wcy
        sta rc_y
        lda #0                      ; clipped to the top: rel is now 0
:       sta tmp                     ; stored here, so the common path never reloads it
        clc
        adc rc_h                    ; rel end+1
        cmp #BUFROWS+1
        bcc :+
        lda #BUFROWS                ; bcc not taken: C = 1 already, for the sbc
        sbc tmp
        beq @none
        bmi @none
        sta rc_h
:       ; cols: rel = rc_x - wcx (16 bit signed)
        lda rc_x
        sec
        sbc wcx
        tay                         ; rel lo, kept in Y
        lda rc_x+1
        sbc wcx+1
        tax                         ; rel hi, kept in X (N,Z as the sbc left them)
        bpl @right
        ; rel < 0: the visible width is w + rel, and rel is already two's complement,
        ; so add rather than negate-and-subtract.  Only a result whose high byte comes
        ; out exactly 0 survives: anything else is the whole rect off the left edge.
        tya
        clc
        adc rc_w                    ; the low sum: the width, if it survives
        beq @none
        inx                         ; hi + C = 0 only for hi = $FF with a carry out
        bne @none
        bcc @none                   ; (inx and branches leave C alone)
        ldx wcx                     ; rel is now exactly 0, so the right clip is just
        stx rc_x                    ; min(width, ROWCHARS): the width is still in A
        ldx wcx+1
        stx rc_x+1
        cmp #ROWCHARS+1
        bcc :+
        lda #ROWCHARS
:       sta rc_w
        jmp drawrect
@right: bne @none                   ; Z from the tax: rel >= 256 -> off right
        tya
        cmp #ROWCHARS
        bcs @none                   ; not taken: C = 0 for the adc
        adc rc_w
        cmp #ROWCHARS+1
        bcc :+                      ; not taken: C = 1 for the sbc
        sbc #ROWCHARS               ; the excess e = lo + w - ROWCHARS (C stays 1)
        eor #$FF
        adc rc_w                    ; w - e = ROWCHARS - lo
        sta rc_w
:       jmp drawrect
@none:  rts

; ============================================================================
; calc_ring: ringS = ((wcy mod RINGROWS) * 80 + wcx) mod RINGCHARS ; barq = ringS / 80
; ============================================================================
        .segment "LGCCODE"          ; bank 7, with the row multiples
calc_ring:
        lda wcy
        ringmod7
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
        lda ringS                   ; running value: low in A, high in Y
        ldy ringS+1
        ldx #$FF                    ; quotient, pre-decremented
        sec                         ; the loop's own bcs guarantees C=1 all the way
@div:   inx                         ; round, so the only entries needing a sec are
        sbc #ROWCHARS               ; this one and the one after a borrow
        bcs @div                    ; no borrow: high byte unchanged, value still >= 0
        sec                         ; dey does not touch the carry
        dey
        bpl @div                    ; borrow absorbed by the high byte
@dd:    stx barq                    ; high byte went negative: X is the quotient
  .if BHW
        adc #ROWCHARS-1             ; C = 1 (the sec before dey): A + 80, the remainder,
        sta wcxm                    ; where the window starts in its slot
        lda #RINGROWS-1             ; the window row that lives in the last slot, and
        sbc barq                    ; the map row it shows.  C = 1: the adc carried
        clc
        adc wcy
        sta mrow
  .endif
        rts

        .segment "TILCODE"          ; back to the render helpers


; ============================================================================
; dirty tiles: redraw changed map tiles (both buffers keep their own list)
; ============================================================================
        .segment "LGCCODE"          ; bank 7, with the logic that calls it
mark_dirty:                         ; A = tx, X = ty  (adds to both buffers' lists)
        sta tmp
        stx tmp2
        ldx #1
@b:     lda DIRTYCNT,x
        cmp #DIRTYMAX
        bcs @over
        asl                         ; cnt*2, C = 0 (cnt < DIRTYMAX)
        cpx #1
        bcc @b0                     ; buffer 0: its list is at 0
        adc #2*DIRTYMAX-1           ; buffer 1: C = 1, so this adds 2*DIRTYMAX
@b0:    tay
        lda tmp
        sta DIRTYLIST,y
        lda tmp2
        sta DIRTYLIST+1,y
        inc DIRTYCNT,x
@next:  dex
        bpl @b
        rts
@over:  txa                         ; the list is full: that buffer is redrawn whole
        asl                         ; instead (an unreachable window x; match_sprites
        tay                         ; drops its records, scroll_validate redraws it)
        lda #$80
        sta BUF_CX+1,y
        bne @next                   ; (always)

        .segment "LGCCODE"          ; bank 7 (drawrect_clip through callbank)
draw_dirty:
        ldx curbuf
        lda DIRTYCNT,x
        beq @done
        sta lcnt
        lda #0                      ; the buffer's list: 0, or 2*DIRTYMAX for buffer 1
        cpx #1
        bcc @d0
        lda #2*DIRTYMAX
@d0:    sta lidx
@l:     stz rc_x+1                  ; A is dead here: loaded just below
        ldy lidx
        lda DIRTYLIST,y
        asl
        rol rc_x+1
        asl
        rol rc_x+1
        sta rc_x
        lda DIRTYLIST+1,y
        iny                         ; Y is dead from here: advance the index in it
        iny
        sty lidx
        asl
        sta rc_y
        lda #4
        sta rc_w
        lsr                         ; 4 >> 1 = 2
        sta rc_h
        bankimm lda, BANK_TILES, BANK_LVL   ; bank 6's BANKENTRY is drawrect_clip
        jsr callbank
        dec lcnt
        bne @l
        ldx curbuf
        stz DIRTYCNT,x              ; A is dead: both callers reload it at once
@done:  rts

  .if .not BHW                   ; (Model B: display.s, in bank 7)
        .segment "CODE"

; ============================================================================
; IRQ handling
; ============================================================================
irq_handler:
        stx irq_x
        sty irq_y
        bit VIA_IFR
        bvs @t1arm                  ; the T1 arm grew past bvc's reach: one cycle each way
        jmp @notT1
@t1arm: ; ---- rupture chain step.  This is a CRTC restart: the next section's address
        ; was armed during the previous one and is latched at the boundary.  What the
        ; new section needs quickly is its shape.  R9 and R4 together decide where the
        ; section ENDS: the CRTC latches end-of-frame at the start of the scanline
        ; where row = R4 and line = R9, so for a 2-line section (a partial with
        ; R9 = 1) both must be in place before the start of scanline 1 -- 128 cycles
        ; after the restart.  R6 is compared from scanline 1 on, so Q's R6 = 0 has
        ; the same deadline.  Everything else has a row or more to spare.  The chain is
        ; phased (VS2T) so the step fires ~50 cycles BEFORE the restart, the
        ; hold below carries the first write past it, and the three deadline registers
        ; then land about 40, 60 and 80 cycles in, with the rest behind them.  Writing
        ; R4 third put it at ~140 for a 2-line P2: that section never ended, Q's R6
        ; hit never came, and both borders lit up on every scroll frame.
        ; R12/R13 go LAST, after the T1 reload and the index bookkeeping, so they land
        ; on scanline 1 (measured: ~140-175 cycles in).  Written straight after R7 they
        ; fell at ~105-125, across the end of scanline 0 -- and on a partial (R4 = 0,
        ; written on row 0 = its last row) some 6845s end the frame at once, the VL6845
        ; among them (Tom Seddon's r4-3), and reload the start address as that scanline
        ; ends: a Master with such a chip lost the R12 write and showed the playfield
        ; from A's high byte with P's low byte, 256 chars adrift, a 16-char tear down
        ; every row whenever the fine scroll was not 0.  Two-line sections still have
        ; 80 cycles in hand before the next restart.
        ; ACCCON D is different again: it is the memory map, sampled by every fetch,
        ; so it must be in place BEFORE the boundary -- the bar's T1 fires a further
        ; BARLEAD us early so D lands in the horizontal blanking of the bar's last line.
        lda LOADREQ
        beq @chain
        jmp @ldcheck                ; a load asked for, under way or ending: load_begin
@chain: ldx SECIDX
        cpx DISPSECT                ; the first step is the start of the bar itself, which
        beq @noD                    ; is only main RAM to the CRTC while D = 0: leave it
        lda ACCCON
        and #$FE
        ora dispD
        sta ACCCON
@noD:   ldy #5                      ; ~26 cycles: the first CRTC write must follow the
@hold:  dey                         ; restart, and the step fires ahead of it
        bne @hold
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
        ldy SECTAB+4,x
        sty CRTC_DAT
        lda #7
        sta CRTC_IDX
        lda SECTAB+5,x
        sta CRTC_DAT
        sta curR7                   ; the vsync handler re-phases the frame from this
        lda SECTAB+6,x
        sta VIA_T1LL
        lda SECTAB+7,x
        sta VIA_T1LH
        lda VIA_T1CL                ; clear T1 flag
        ; next entry; the chain stops at Q, the only entry whose R7 is the vsync row: a
        ; late vsync must not walk the chain off the end of SECTAB.  Every other
        ; section's R7 is 30, so C = 1 on the way past, as the adc below needs.
        lda curR7                   ; R7, just written
        cmp #QVSYNC
        beq :+
        txa
        adc #7                      ; C is set (30 >= QVSYNC), so this adds 8
        sta SECIDX                  ; (X still indexes this entry for R12/R13 below)
:       lda #12                     ; the next section's address, last: see above
        sta CRTC_IDX
        lda SECTAB,x
        sta CRTC_DAT
        lda #13
        sta CRTC_IDX
        lda SECTAB+1,x
        sta CRTC_DAT
@xit:   ldy irq_y                   ; @exit inlined: no jmp on the chain-step path
        ldx irq_x
        lda $FC
        rti
@ldcheck:
        cmp #1
        bne @ldt1
        ldx SECIDX                  ; stop asked: only the bar step, a frame boundary,
        cpx DISPSECT                ; makes the switch
        beq @ldsw
        jmp @chain
@ldsw:  ; ---- this restart is a standard frame, not the bar: see load_begin.  The same
        ; hold as the bar's, so R4 lands in the first scanline; R9 = 7 and R6 = BARROWS
        ; are the vsync's pre-arm already, and R12/R13 hold the bar.
        ldy #5
@ldhold: dey
        bne @ldhold
        lda #4
        sta CRTC_IDX
        lda #LDR4
        sta CRTC_DAT
        lda #7
        sta CRTC_IDX
        lda #LDR7
        sta CRTC_DAT
        sta curR7                   ; load_end's first vsync re-phases to LDR4 from this
        lda #$40
        sta VIA_IER                 ; T1 off: the chain is stopped
        lda VIA_T1CL
        lda #2
        sta LOADREQ
        bne @xit                    ; (Z = 0: lda #2)
@ldvsync:                           ; stopped: the standard frame free-runs; count the
        inc vsyncs                  ; vsync and keep the keys and the sound alive
        jmp @sk
@ldt1:  lda VIA_T1CL                ; stopped or ending: T1 runs on with its interrupt
                                    ; off, so its flag is stale: was this the vsync?
        bit irq_x                   ; (a 3-cycle pad for the jmp it replaces)
@notT1:
        lda VIA_IFR
        and #$02
        bne :+
        beq @xit                    ; (Z = 1: the bne fell through)
:       ; ---- vsync: restart T1 first (constant latency), counter = vsync->T.  The
        ; latch (how long section 0 lasts) is programmed further down, after the
        ; flip: section 0 belongs to the buffer that is about to be displayed.
        lda #<VS2T                  ; (an immediate: VS2T allows for its timing)
        sta VIA_T1LL
        lda #>VS2T
        sta VIA_T1CH
        lda #$02
        sta VIA_IFR
        lda LOADREQ                 ; (after the restart: it sets the chain's phase)
        cmp #2
        beq @ldvsync                ; stopped: T1 runs on with its interrupt off
        cmp #3
        bne :+
        stz LOADREQ                 ; resume: T1's interrupt on again, below
:       lda #$C0
        sta VIA_IER
        ; re-phase: the vsync fired at row curR7, so end this frame at row
        ; curR7 + QROWS-1-QVSYNC with 8-line rows -> T starts exactly QROWS-QVSYNC rows
        ; after the vsync even if the CRTC row counter had run past its vertical total
        ; (which otherwise never recovers)
        lda #9
        sta CRTC_IDX
        lda #7
        sta CRTC_DAT
        lda #6                      ; pre-arm the bar's R6 now, in Q, where the display
        sta CRTC_IDX                ; is already off and a new R6 cannot show: the step
        lda #BARROWS                ; ISR at the bar's start is too close to the second
        sta CRTC_DAT                ; scanline to be trusted with it
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
        lda NEXTBUF                 ; the flip is the section chain moving to the other
        sta dispD                   ; buffer's rows; D follows it, but only from the
        stz flipreq                 ; first playfield section -- the bar needs D = 0
@noflip:
        ; everything section 0 needs comes from the buffer that is about to be
        ; displayed -- its start address (menu_sections moves it) and its length
        ldx #0
        ldy DISPSECT                ; held in Y: SECIDX wants the same byte below
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
        lda #$40
        sta VIA_IFR
        sty SECIDX
        lda #1                      ; the bar is below $3000: it is only main RAM to the
        trb ACCCON                  ; CRTC while D = 0
@sk:    jsr scan_keys
        jsr sound_tick
        lda MUSTICK                 ; bank 6's menu overlay, stepped as the Model B's
        beq @exit                   ; interrupt stub does (low.s)
        dec MUSTICK
        lda ROMSEL_CPY
        pha
        ldpbank lda, BANK_TILES     ; (the handler is in main RAM, loaded unpatched: PBANK)
        sta ROMSEL_CPY
        sta ROMSEL
        jsr music_tick
        pla
        sta ROMSEL_CPY
        sta ROMSEL
@exit:
        ldy irq_y
        ldx irq_x
        lda $FC
        rti

; CA1 fires at the end of the 2-line vsync pulse.  -35 would put each step ~5 us INTO its
; section; the further -36 puts it ~30 us before the restart, so that the shape
; registers land early in the first scanline -- see the chain step in irq_handler.
VS2T = (QROWS-QVSYNC)*8*LINE - 2*LINE - 35 - 36 - 8 + 2   ; -8: the step's load-flag test; +2 (ticks): the
                                    ; vsync handler loads it as immediates, 4 cycles sooner
                                    ; than from memory
  .endif

; ---------------------------------------------------------------- keyboard
        PLACEH "CODE", "LGCCODE"    ; the interrupt's own work: bank 7 with the Model B's
scan_keys:                          ; handler, main RAM with the Master's
        lda #$7F
        sta VIA_DDRA
        lda #3
        sta VIA_ORB                 ; disable keyboard autoscan
        stz keys                    ; built in place: the interrupt is atomic to its readers
        ldx #9
@k:     lda keytab,x
        sta VIA_ORANH
        lda VIA_ORANH
        bpl :+
        lda keybits,x
  .if BHW
        ora keys
        sta keys
  .else
        tsb keys
  .endif
:       dex
        bpl @k
        rts
keytab:  .byte $61,$19, $42,$79, $48,$39,$49, $68,$29, $62
keybits: .byte K_LEFT,K_LEFT, K_RIGHT,K_RIGHT, K_UP,K_UP,K_FIRE, K_DOWN,K_DOWN, K_FIRE

; ---------------------------------------------------------------- sound
; sfx format: steps of (b0,b1,b2,frames) written to the SN76489 ; end = $FF
sound_tick:
        lda SFXREQ
        beq @play
        ; start new sfx
        asl
        tax
        stz SFXREQ                  ; (Model B: A = 0 -- the index is in X)
        lda sfxtab-2,x
        sta SFXPTR
        lda sfxtab-1,x
        sta SFXPTR+1
        bne @go                     ; an sfx is never in page 0: straight to its first step
@play:  lda SFXPTR+1
        beq @music
        dec SFXDUR
        bne @music
@go:    ldaz SFXPTR                 ; (zp): the first byte needs no index
        cmp #$FF
        beq @end
        jsr sndwrite
        ldy #1
        lda (SFXPTR),y
        jsr sndwrite
        iny
        lda (SFXPTR),y
        jsr sndwrite
        iny
        lda (SFXPTR),y
        sta SFXDUR
        lda SFXPTR

        adc #4
        sta SFXPTR
        bcc @music
        inc SFXPTR+1
        bne @music                  ; SFXPTR+1 <> 0 after the inc
@end:   jsr sndwrite                ; A = $FF (the end mark): noise off
        lda #$DF                    ; channel 2 off
        jsr sndwrite
        stz SFXPTR+1
@music:
        lda MUSON                   ; the tune is stepped at the interrupt's tail (the
        sta MUSTICK                 ; Model B's stub in low.s, the Master's handler): its
        rts                         ; player is in bank 6's menu overlay.  Only raised
                                    ; here, at the vsync: the T1 steps share that tail
  .ifdef DBGSND
@dbgsil: .byte $9F, $BF, $FF, 0
  .endif

.macro SNDWRITE_BODY
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
.endmacro
sndwrite:
        SNDWRITE_BODY
.macro sndw                         ; the player's own copy, in its bank
        jsr sndwrite_m
.endmacro

; ---------------------------------------------------------------- music
; 144-byte period table then the sequence (4-byte records: frames, note0..2;
; frames = 0 -> loop), in the menu overlay beside its player (banks.s MUSIC_ADDR).
MUSIC_SEQ  = MUSIC_ADDR + 144
MUSIC_TAB  = MUSIC_ADDR             ; the player is in the data's bank: no copy needed
        .segment "MNUCODE"          ; the menu overlay (bank 6), with the tune
sndwrite_m:
        SNDWRITE_BODY
music_tick:
  .if BHW                        ; the overlay comes off the disc, so the loader
        ldx PBOARD                  ; cannot patch a companion in: the write bank by hand
        beq @wr                     ; (A = this bank's socket, from the interrupt stub;
        cpx #BOARD_SOLIDISK         ;  MUSDUR and MUSNOTE below are this bank's)
        beq @sol
        ldpbank ldx, BANK_TILES     ; Watford: a store to $FF30 + bank 6's socket
        sta WRSEL_WATFORD,x
        bcc @wr                     ; C = 0: PBOARD = 1 < BOARD_SOLIDISK
@sol:   sta WRSEL_SOLIDISK          ; Solidisk: the socket on port B
@wr:
  .endif
        lda MUSON
        beq @done
        dec MUSDUR
        bne @done
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
        tay                         ; set the voice: Y = the note (0 = rest), X = the voice
        txa                         ; (X is not touched: sndw keeps it)
        asl
        asl
        asl
        asl
        asl
        sta ISRT1                   ; ch << 5
        cpy #0
        bne @note
        ora #$0F                    ; rest: A is still ch<<5; attenuation 15
        bne @vol                    ; (always)
@note:  tya
        asl                         ; notes are 24..95: the table indexed from 2*24
        tay
        lda MUSIC_TAB-48,y
        and #15
        ora ISRT1
        ora #$80
        sndw
        lda MUSIC_TAB-48,y
        lsr
        lsr
        lsr
        lsr
        sta ISRT2
        lda MUSIC_TAB-47,y
        asl
        asl
        asl
        asl
        ora ISRT2
        sndw
        lda musvol,x
        ora ISRT1
@vol:   ora #$90
        sndw
:       inx
        cpx #3
        bne @v
@done:  rts

; A = next music byte; MUSPTR += 1.  Preserves X.  Z reflects A; Y = A.  Bank 6 selected.
musbyte:
        ldaz MUSPTR
        inc MUSPTR
        bne :+
        inc MUSPTR+1
:       tay
        rts
musvol: .byte 3, 8, 8

music_start:
        lda #<MUSIC_SEQ
        sta MUSPTR
        lda #>MUSIC_SEQ
        sta MUSPTR+1
        lda #1
        sta MUSDUR
  .if BHW
        lsr                         ; A = 0, C = 1
        sta MUSNOTE
        sta MUSNOTE+1
        sta MUSNOTE+2
        rol                         ; A = 1
  .else
        stz MUSNOTE
        stz MUSNOTE+1
        stz MUSNOTE+2
  .endif
        sta MUSON
        rts

        .segment "LGCCODE"          ; (bank 7 stops it: the overlay may be gone)
music_stop:
  .if BHW
        lsr MUSON                   ; MUSON is 0 or 1: 6 cycles, as lda #0 / sta
  .else
        stz MUSON
  .endif
        lda #$9F
        jsr sndwrite
        lda #$BF
        jsr sndwrite
        lda #$DF
        jsr sndwrite
        lda #$FF
        jmp sndwrite

; ---------------------------------------------------------------- interrupt takeover
        .segment "BOOT"             ; start-up's, in main RAM (once only)
take_over:
        sei
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
        .assert <(40*LINE) = 0, error, "take_over clears flipreq with the latch's low byte"
        sta flipreq                 ; A = 0
        lda #>(40*LINE)
        sta VIA_T1CH
        lda #$C2                    ; enable CA1 (vsync) + T1
        sta VIA_IER
        sta VIA_IFR                 ; $C2: T1 and CA1, the only sources ever enabled
        cli
        rts

; ============================================================================
; CRTC / palette setup
; ============================================================================
  .if .not BHW                   ; (Model B: display.s)
        .segment "BOOT"             ; start-up's, in main RAM
crtc_init:
        ; standard 20K-mode timings, no interlace, cursor off
        ldx #13
:       stx CRTC_IDX
        lda crtctab,x
        sta CRTC_DAT
        dex
        bpl :-
        lda crtctab+7
        sta curR7
        rts
crtctab: .byte 127,ROWCHARS,98,$28, 38,0,32,34, 0,7, $20,8, $06,$00
  .endif

        .segment "LGCCODE"          ; bank 7 (the menus call it through xcall)
set_palette:
        ; MODE 1: a pixel's two bits land in bits 3 and 1 of the palette index, the other
        ; two bits are don't-cares, so all 16 entries are written: logical 0..3 = K C M Y
        ldx #15
:       txa
        lsr
        lsr                         ; C = bit 1
        and #2                      ; bit 3, as bit 1
        adc #0                      ; + bit 1: the logical colour
        tay
        txa
        asl
        asl
        asl
        asl
        ora @cmyk,y
        sta ULA_PAL
        dex
        bpl :-
        rts
@cmyk:  .byte 0^7, 6^7, 5^7, 3^7    ; physical black, cyan, magenta, yellow (inverted)

blank_palette:
        lda #$F7                    ; (i << 4) | 7, i = 15 down to 0
        sec
:       sta ULA_PAL
        sbc #$10
        bcs :-
        rts

        .segment "LOWCODE"          ; low RAM
; ============================================================================
; Map access for the logic, which lives in bank 7 and so cannot select bank 5
; itself.  Each of these leaves bank 7 selected, so the logic calls them directly.
; ============================================================================
; A = tile row -> mapptr = address of that map row
maprow:                             ; row * 2^lw = (row << 8) >> (8 - lw): mapshr is
        ldy #0                      ; the loader's; no table to page in.  X
        sty z:mapptr                ; is kept (the logic calls this with it live);
        ldy mapshr                  ; Y comes back 0
        beq :++
:       lsr
        ror z:mapptr                ; (z: mapptr is logic.s's, defined after this)
        dey
        bne :-
:       clc
        adc #>LV_MAP
        sta z:mapptr+1
        rts

; A = (mapptr),y ; Y preserved
mapbyte:
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        lda (mapptr),y
        jmp pagelogic

; store A at (mapptr),y ; Y preserved
mapput: pha
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_MAP, 0           ; (a store follows)
        pla
        sta (mapptr),y
        .assert * = pagelogic, error, "mapput falls into pagelogic"



; sign extend A -> tmp3 (0 or $FF)
        .segment "LGCCODE"          ; (its one caller is the sprite prologue: bank 7)
sext:   and #$80
        beq :+
        lda #$FF
:       sta tmp3
        rts

; ============================================================================
; pagelogic: bank 7 back, for reading and (on the write-select boards) for writing --
; the return path of every crossing from bank 7 (map access, callbank, the thunks)
; ============================================================================
        .segment "LOWCODE"
pagelogic:                          ; A, X, Y and the carry all come through intact:
        pha                         ; these sit in the middle of calls that return values
        bankimm lda, BANK_LVL, 0
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_LVL, 0           ; (the write bank too: bank 7's code stores)
        pla
        rts
; The logic and the game loop share bank 7, so these t_ (in) and m_ (out) names are
; plain aliases.
t_game_frame = game_frame
t_level_init = level_init
t_redraw_hud = redraw_hud
m_addsprite  = addsprite
m_clamp_window = clamp_window
m_rnd        = rnd
m_mark_dirty = mark_dirty
        .segment "LGCCODE"
; bank 7's own ringaddr, for the sprite prologue, copy_partial and blank_below: the
; ring modulus by subtraction (no table this side), the row multiple from bank 7's
; mulrowlo/hi, and on the Model B the buffer's base from select_backbuf (both bases
; are xx80: ringbhi is the page)
ringaddr7:
        ringmod7
        tax
        lda mulrowlo,x              ; slot * 80 + cx (C = 0: ringmod7 leaves by its bcc)
        adc w16
        sta sp
        lda mulrowhi,x
        adc w16+1
        asl sp                      ; x 8, the high byte kept in A
        rol
        asl sp
        rol
        asl sp
        rol                         ; C = 0: bit 13 of the char (< 8192)
        pha
        lda sp
  .if BHW
        adc #<RING_A
        sta sp
        pla
        adc ringbhi
  .else
        adc #<RINGBASE
        sta sp
        pla
        adc #>RINGBASE
  .endif
        ringup sp
        sta sp+1
        rts
; The menus live in bank 6's overlay (menu.s under MNUCODE) and are called from bank
; 7; what they call back in bank 7 crosses the same way, through low RAM's xcall (X =
; the bank, ctgt = the target; a tail call: xcall returns to the stub's caller).  The
; overlay comes off the disc after the boot loader's bank patches, so its stubs read
; bank 7's physical number from PBANK; bank 7's own are patched.  What the menus call
; in main RAM or in bank 6 is a plain name.
.macro XCALL name, target, tomenus
.ident(name):
        ldx #<target
        stx ctgt
        ldx #>target
        stx ctgt+1
  .if tomenus
        bankimm ldx, BANK_TILES, BANK_LVL   ; bank 7's stubs, into the overlay
  .else
        ldpbank ldx, BANK_LVL       ; the overlay's, into bank 7 (not patched: PBANK)
  .endif
        jmp xcall
.endmacro
        .segment "LGCCODE"
        XCALL "t_title_menu", title_menu, 1
        XCALL "t_help_screen", help_screen, 1
        XCALL "t_level_select", level_select, 1
        XCALL "t_winlose", winlose, 1
        .segment "MNUCODE"
        XCALL "m_blank_palette", blank_palette, 0
        XCALL "m_set_palette", set_palette, 0
m_wait_flip:                        ; (its own copy: two instructions)
        lda flipreq
        bne m_wait_flip
        rts
        XCALL "m_music_stop", music_stop, 0
        XCALL "m_build_sections", menu_sections, 0
        XCALL "m_div10_16", div10_16, 0
        XCALL "m_calc_ring", calc_ring, 0
        XCALL "m_drawsprite", drawsprite, 0
m_music_start = music_start
m_ringaddr = ringaddr
m_select_backbuf = select_backbuf

; ============================================================================
; Random
; ============================================================================
        .segment "LGCCODE"     
rnd:    lsr seed+1
        ror seed
        bcc :+
        lda seed+1
        eor #$B4
        sta seed+1
:       lda seed
        rts
