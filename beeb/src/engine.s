; ============================================================================
; CLEO - BBC Micro port : display engine
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
OSGBPB    = $FFD1
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
  .if .not MODELB                 ; (Model B: LV_PAGE0 is a label in bank 5, with the tiles)
LV_PAGE0  = $8500                 ; tile id -> tile data address: 256 lo ((id&3)<<6),
                                  ; 256 hi ($80 | id>>2).  A map byte is a tile id, so
                                  ; this is the whole translation -- and it is the same
                                  ; for every level and both sets, so build_tileaddr
                                  ; writes it once instead of every level shipping one.
LV_MAP    = $8900                 ; up to 8K, row major
  .endif
;         $A900  LV_MAPROWLO, LV_MAPROWHI (built by level_init, see logic.s)
;         $B000  box stars, $B800 music

; bank 7
  .if .not MODELB                 ; (Model B: these are labels, placed by the linker)
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
LV_BINSTAR= $BBD0                 ; cached bin-walk lists: star object indices, then
LV_BINOTH = $BC00                 ;   everything else (BINMAX each)
LV_ALTTAB = $BE00                 ; classes x 8 (global: loaded once)
  .endif

; ---------------------------------------------------------------- screen shape
; Each buffer gets its own 20K screen, main and shadow, so both are an 80-char
; ring at $3000 with 27 rows visible and the status bar above.
ROWCHARS  = 80
  .if MODELB
; Model B: 32K of main RAM, and all but 768 bytes of it is the display.  Two rings of
; 23 slots, each with a mirror row below it (the rupture chain reads the row that
; straddles the ring end from there: see modelb/DESIGN.md), and the 2-row bar:
;   $0300 bar  $0800 mirror A  $0A80 ring A  $4400 mirror B  $4680 ring B  $8000
; 23 x 640 is not a whole number of pages, so the fold is 16 bit -- but both ring
; ENDS are page aligned, which keeps the fold TEST a byte compare (ringup).
RINGROWS  = 23
VISROWS   = 21                    ; 168 lines = 84 game px
BUFROWS   = VISROWS + 1
MAXDWY    = 8
  .else
VSPEG     = 3                     ; vsyncs a rendered frame (game.s): 16.7 Hz of render
RINGROWS  = 32                    ; the whole 20K: the hardware fold IS the ring wrap
  .ifdef VISROWSDEF
VISROWS   = VISROWSDEF            ; a test build: the Model B's window on the Master, so
  .else                           ; the two can be run in lock step (modelb/tools)
VISROWS   = 30                    ; visible char rows: 240 lines = 120 game px.  The
  .endif
                                  ; original is 108 (a 128-line phone screen less a
                                  ; 20-line HUD); the ring at $3000 has room for more.
                                  ; 30 fills the ring exactly: 31 held + the composed row.
BUFROWS   = VISROWS + 1           ; rows held: the visible ones plus the bottom partial's
; The camera follows Cleo one for one, so her fall speed is also how far the window
; moves in a frame.  A char row is four map pixels.  Main and shadow are separate,
; so nothing in the layout forces a limit; this one is a play decision.
MAXDWY    = 8
  .endif
ROWBYTES  = ROWCHARS*8
RINGCHARS = ROWCHARS*RINGROWS
RINGBYTES = RINGCHARS*8
  .if MODELB
; 23 x 640 = $3980 is not a whole number of pages, so the fold is 16 bit -- but both
; ring ENDS are page aligned, which keeps the fold TEST a byte compare (ringup), and
; both bases are at xx80, which makes the low byte's fold a subtraction of $80.
; Main RAM is display from the bar's $0300 to $8000: nothing else lives in it
; (the code every bank calls is bank 5's now: modelb/DESIGN.md).
RING_A    = $0A80
RING_B    = $4680
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
; Three rows come out of the ring so the status bar can stop chasing it:
;   $3000  the row copy_partial fills with the window's top slice
;   $3280  a copy of the ring's last 80 chars, immediately before the ring, so a row
;          that straddles the ring end can still be read as one run
;   $3500  the ring, 28 rows -- both ends page aligned, so ringup stays a byte compare
;   $7B00  the bar
; The ring is the entire screen and the CRTC folds it for free: an address that runs
; off $8000 comes back to $3000, which is the ring base, so a displayed row may straddle
; the end and no mirror copy is needed.  That is the whole reason RINGROWS is 32 -- it
; is not a choice, it is the size of the region the hardware wraps.
RINGBASE  = BUF0
RINGEND   = RINGBASE + RINGBYTES
; The composed top row has to be INSIDE the screen: it is per buffer, and anything below
; $3000 is only main RAM to the CRTC (the bar gets away with it by being single buffered
; and scanned with D = 0).  It lives in the one ring row the window does not hold: the
; row ABOVE it, ring chars [ringS + BUFROWS*80, ringS + RINGCHARS) = [ringS - 80, ringS).
; The window start is char granular (ringS = wcy*80 + wcx), so that row is not a slot in
; the row tables: its column c is ring char (ringS + c + RINGCHARS - 80) mod RINGCHARS,
; a constant offset from its source, which makes it a ring row like any other -- a
; horizontal scroll leaves it valid and only the newly drawn columns need recomposing.
; (It was a row-aligned slot once, partq = barq + 31, which overlapped the window's last
; row by ringS mod 80 chars whenever BUFROWS was 31: that is why VISROWS sat at 29.)
; 30 would need the composed row at ring char ringS + 2480 exactly -- window aligned,
; not slot aligned -- and a copy that folds at $8000 mid-run.
; The bar is BELOW the screen, in main RAM, and there is only one of it.  The CRTC's
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
  .if MODELB                      ; the level's own bounds, computed by the packer
BINMAX    = BINMAXDEF             ; from the objects' grid cells and the walk rectangle
MAXREC    = MAXSPRDEF             ; (assets.inc)
MAXSPR    = MAXSPRDEF
  .else
BINMAX    = 40                    ; cached object list: 24-32 objects a frame is the most
                                  ; seen across the levels, and the walk falls back to
                                  ; processing directly if it ever overflows
MAXREC    = 32
MAXSPR    = 32
  .endif

; key bits
K_LEFT  = 1
K_RIGHT = 2
K_UP    = 4
K_DOWN  = 8
K_FIRE  = 16

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
  .if .not MODELB                 ; the Master's three hottest main-RAM scalars (profiled:
NSPR:     .res 1                  ;  63-91, 44-65 and 31-45 accesses a frame); the Model B
BINI:     .res 1                  ;  had these in zero page already and has its own three
sp_mh:    .res 1                  ;  (defs.inc).  The menus' tchar and menuptr went out.
  .endif
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
sp_col:   .res 2                  ; current column base pointer
sp_rb:    .res 2                  ; screen address of the current row's first char
sp_rp:    .res 2                  ; source pointer for the current row (col base + row offset)
sp_rinc:  .res 1                  ; source bytes per row: 8 (full res) or 4 (half res)
sp_ncol:  .res 1                  ; columns-1
sp_row:   .res 1
sp_c:     .res 1
sp_lim:   .res 1
sp_cnt:   .res 1                  ; sprite column countdown
                                  ; full past $A5 -- the MOS's disc code scribbles on
                                  ; $A8-$BF during a load -- so these alias zp the blit
                                  ; no longer needs, and the rest sit in main RAM (mrest)
mptr    = w16                     ; this column group's mask bytes, one per pixel row
mtab    = tmp3                    ; MASKTAB page for this column's phase (tmp3 = 0, tmp4 = page)
sp_msk  = tmp4c8                  ; the AND mask of the pair being drawn
sp_id   = sp_ext                  ; the sprite id, until sp_ext is set a few lines later
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
  .if .not MODELB
        .segment "TABLES"           ; the file TABLES, loaded to $0400 at start-up: the
                                  ; static tables assembled, everything else zero
MASKTAB0:                         ; four contiguous pages, one per column phase (SPRMSK):
                                  ; 1K aligned, so phase = page & 3.  MASKTABk[m] is the AND
                                  ; mask for column k of mask byte m: its bit pair
                                  ; (m >> (6 - 2k)) & 3 -> $FF $CC $33 $00 (none, right,
                                  ; left, both opaque)
  .repeat 4, k
    .repeat 256, m
        .byte ($0033CCFF >> (((m >> (6 - 2*k)) & 3) * 8)) & $FF
    .endrepeat
  .endrepeat
MASKTAB1 = MASKTAB0 + $100
MASKTAB2 = MASKTAB0 + $200
MASKTAB3 = MASKTAB0 + $300
        .assert (MASKTAB0 & $3FF) = 0, error, "MASKTAB0 must be 1K aligned"
                                   ; and $82, which init_tables zeroes on purpose: $41 is
                                   ; the blank-run tag and must leave the screen byte
                                   ; alone, $82 is its mirror, $44 forces a black left
                                   ; pixel.  Substituting X for IDENT,x is therefore wrong.
RINGLO:                           ; ring row r -> screen address (both buffers: main and
  .repeat RINGROWS, r             ;  shadow share the addresses)
        .byte <(RINGBASE + r*ROWBYTES)
  .endrepeat
RINGHI:
  .repeat RINGROWS, r
        .byte >(RINGBASE + r*ROWBYTES)
  .endrepeat
GATHERL:   .res 24                ; per-row tile gather: tile address lo | bank (low nibble)
GATHERH:   .res 24                ;                       tile address hi
SPRLIST:                          ; (a label, not an equate: the tools read labels.txt)
SPR_ID:    .res MAXSPR            ; the sprite draw list, one array per field (index =
SPR_XL:    .res MAXSPR            ;  the sprite's number, so no stride to multiply by):
SPR_XH:    .res MAXSPR            ;  id, x lo/hi, y lo/hi in map px
SPR_YL:    .res MAXSPR
SPR_YH:    .res MAXSPR
SPRREC:    .res 2*MAXREC*10       ; per buffer drawn-sprite records: id,xl,xh,yl,yh, cxl,cxh,cy,w,h
RECCNT:    .res 2
KEEP:      .res MAXREC
dpass:     .res 1                 ; draw_sprites pass: 1 = box stars, 0 = the rest
spclip:    .res 1                 ; drawsprite: the last sprite came off a window edge
BUF_CX:    .res 4                 ; per buffer held window (cx lo,hi) x2
BUF_CY:    .res 2                 ; (a buffer is invalid when its BUF_CX high byte is $80:
                                  ;  scroll_validate sees |dx| >= 80 and redraws it whole;
                                  ;  window x in chars never reaches $400)
BUF_BOTOK: .res 2                 ; the slot below the playfield is black (blank_below)
BUF_SEC0:  .res 4              ; per buffer: CRTC start of the frame's first section
BUF_SEC0T1: .res 4             ;   and how long it lasts (the vsync handler needs both)
BARDIRTY:  .res 1                 ; one bar, so one flag
BINR:      .res 4                  ; gx0,gx1,gy,gy1 the cached lists were built for
NSTARL:    .res 1                  ; entries in the star list
NOTHL:     .res 1                  ;   and in the other one
BINOK:     .res 1                  ; 0 = rebuild (level load, or a list overflowed)
MAPSTRIDE: .res 2                  ; bytes per map row (1 << maplw): drawrect walks the
                                   ; row pointer by this instead of re-deriving it
BARCACHE:  .res 16                 ; the nine digit values last blitted into the one bar
                                   ; its bar was last drawn with, $FF = unknown
DIRTYLIST: .res 2*2*16            ; per buffer dirty tiles (tx, ty)
DIRTYCNT:  .res 2
DISPSECT:  .res 1
dispD:     .res 1                 ; ACCCON D for the PLAYFIELD sections: which buffer is
                                  ;   displayed.  The bar's section forces D = 0, because
                                  ;   below $3000 D = 1 reads HAZEL/ANDY, not main RAM.                 ; SECTAB offset the ISR chain uses (0/48)
curR7:     .res 1                 ; last R7 written by the chain (for the vsync re-phase)
NEXTSECT:  .res 1
SECIDX:    .res 1
OLDIRQ:    .res 2
OLDIER:    .res 1
SFXREQ:    .res 1
SFXDUR:    .res 1
LOADREQ:   .res 1                 ; 0 running, 1 stop asked, 2 stopped, 3 resume asked (load_begin)
MUSON:     .res 1
MUSTMP:    .res 1                 ; musbyte scratch (ISR context: must not touch tmp)
MUSDUR:    .res 1
MUSNOTE:   .res 3
ISRT1:     .res 1
ISRT2:     .res 1
KEYSCAN:   .res 1
NEXTBUF:   .res 1
  .else
; Model B: main RAM is the screen, so each table lives in the bank of the code that
; reads it, and only what more than one bank touches is in the 512 bytes of low RAM.
; The mask tables are static data at a fixed address in both sprite banks (MASKTAB0,
; SWAPTAB in modelb/src/defs.inc); sprmul5 and the row tables are static too.
        .segment "TILBSS"           ; bank 5: the tile blitter's gather, above the tiles
GATHERL:   .res 24
GATHERH:   .res 24
half0:     .res 1                   ; the level's half tiles: first id, the two range
half1:     .res 1                   ;   boundaries (bottom fills from half1, rowpairs
half2:     .res 1                   ;   from half2), the halves' page (the loader's)
halfhi:    .res 1
halfsub:   .res 1                   ; half0 less the slot the first half takes in that
                                    ;   page: id - halfsub = the half's slot from the page
rowbit:    .res 1                   ; the char row being drawn, as a flag bit (1, 2)
        ; bank 5 still, with the ring work that keeps it (init5 zeroes the segment)
RINGLO:    .res RINGROWS            ; the buffer being drawn (select_backbuf rebuilds them)
RINGHI:    .res RINGROWS
BUF_CY:    .res 2
BUF_BOTOK: .res 2                 ; the slot below the playfield is black (blank_below)
FLATTAB:   .res 32                  ; the level's flat tiles: (even line, odd line) by
                                    ; id - FLAT0, the loader's; the solids are the last two
DIRTYLIST: .res 2*2*16
        .segment "LOWBSS"           ; main RAM: the buffers' state bank 7 reads too
BUF_CX:    .res 4                   ; (bank 7 invalidates a buffer: high byte $80)
spbank:    .res 1
DIRTYCNT:  .res 2                   ; (the game loop)
farx:      .res 1                   ; X across a far call (farcall needs X: m_mark_dirty)
PBANK:     .res 4                   ; the physical bank of each of banks 4..7 (the loader's:
                                    ; cpu.inc -- read by what the loader cannot patch)
PBOARD:    .res 1                   ; and the board: BOARD_STD / WATFORD / SOLIDISK (defs.inc),
                                    ; right after PBANK (start7 copies the five together)
        .segment "LGCLOBSS"         ; bank 7, below the level's tables: the sprite
SPRREC:    .res 2*MAXREC*10         ; prologue's records
RECCNT:    .res 2
KEEP:      .res MAXREC
dpass:     .res 1
spclip:    .res 1
        .segment "LGCBSS"           ; bank 7: the logic's, the display driver's and
BINR:      .res 4                   ; the interrupt's
NSTARL:    .res 1
NOTHL:     .res 1
BINOK:     .res 1
BUF_SEC0:  .res 4
BUF_SEC0T1: .res 4
SECTAB:    .res 2*48
SFXDUR:    .res 1
LOADREQ:   .res 1                 ; 0 running, 1 stop asked, 2 stopped, 3 resume asked (load_begin)
KEYSCAN:   .res 1
        .segment "MNUBSS"           ; bank 5's menu overlay: the tune's player lives there
MUSTMP:    .res 1                   ; (MUSON is in low RAM: the interrupt stub reads it)
MUSDUR:    .res 1
MUSNOTE:   .res 3
ISRT1:     .res 1
ISRT2:     .res 1
        .segment "LOWBSS"           ; main RAM: what more than one bank touches (the
SPRLIST:                          ; (a label, not an equate: the tools read labels.txt)
SPR_ID:    .res MAXSPR            ; the sprite draw list, one array per field (index =
SPR_XL:    .res MAXSPR            ;  the sprite's number, so no stride to multiply by):
SPR_XH:    .res MAXSPR            ;  id, x lo/hi, y lo/hi in map px
SPR_YL:    .res MAXSPR
SPR_YH:    .res MAXSPR
BARCACHE:  .res 16                  ; bar_bg (bank 4) resets it, bar_digit (bank 7) keeps it
DISPSECT:  .res 1
NEXTSECT:  .res 1
  .endif

        PLACE "CODE", "TILCODE"

; ---------------------------------------------------------------- macros
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
.elseif ::MODELB
        .local n1, n2               ; a row is 0..255 and the table RINGROWS*5 long:
        cmp #RINGROWS*5             ; two subtractions bring the row into it (main RAM
        bcc n1                      ; is short of a 256-entry table)
        sbc #RINGROWS*5
n1:     cmp #RINGROWS*5
        bcc n2
        sbc #RINGROWS*5
n2:     tax
        lda ringmodtab,x
.else
        tax
        lda ringmodtab,x
.endif
.endmacro
.macro ringmod7                     ; the same, by subtraction: for bank 7 (calc_ring,
  .if ::MODELB                        ; once a frame), which has no copy of the table
:       cmp #RINGROWS
        bcc :+
        sbc #RINGROWS
        bcs :-
:
  .else
        ringmod
  .endif
.endmacro
; Both ends of the ring are page boundaries, so the fold is a compare on the high
; byte alone.  A = high byte after moving forward, folded back into the ring.
; The cmp leaves the carry set on the path that reaches the sbc, so the fold needs
; no sec of its own whatever the caller was holding.
.macro ringup p                     ; p names the pointer whose high byte A holds;
  .if ::MODELB                        ; the Master's fold never needs it
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

.macro spnext
        lda sp
        clc
        adc #8
        sta sp
        bcc :++                     ; past the fold's own anonymous label
        lda sp+1
  .if ::MODELB
        adc #0                      ; C = 1 (the bcc fell through): +1, 2 bytes not 6
  .else
        inca
  .endif
        ringup sp
        sta sp+1
:
.endmacro

; ============================================================================
; ringaddr: screen address of map char (w16 = cx 16 bit, A = cy) -> sp
; ============================================================================
        PLACE "CODE", "TILCODE"     ; Model B: bank 5 (bank 7's sprite prologue: ringaddr7)
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
        adc RINGHI,x
        ringup sp
        sta sp+1
        rts

; ============================================================================
; drawrect: draw map tiles into the current back buffer.
;   rc_x (map chars, 16 bit), rc_y (map char rows), rc_w (chars 1..80), rc_h (rows)
; ============================================================================
        PLACE "CODE", "TILCODE"     ; Model B: bank 5, with the tiles (the whole of it)
drawrect:
        lda rc_h
        bne :+
        rts
:
  .if MODELB
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
        jsr mirdirty5
@nomir:
  .endif
:       ; ---- per-rect invariants  (the ':' is kept: it holds the anonymous label count): tx0 = rc_x >> 2 ; tiles-1 = ((rc_x + rc_w - 1) >> 2) - tx0
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
  .if MODELB
        sbc #0                      ; C = 0 (<= 83, no carry): the -1
  .else
        deca
  .endif
        lsr
        lsr
        sta rc_nt
        lda rc_y
        jsr ringaddr
        sta rc_sp+1                 ; ringaddr returns A = sp+1 (its last store)
        lda sp
        sta rc_sp
        ; ---- map row pointer: the row tables only ever step it on by one map row, so
        ; build it once here and add the stride per tile row (see @nextrow) rather than
        ; index LV_MAPROW* and re-add rc_tx0 every time round.  The tables live in the
        ; map bank, so this needs the bank selected too.
  .if MODELB
        lda rc_y                    ; the row tables are in the map's bank, which this
        lsr                         ; code cannot page in over itself: main RAM does it
        jsr maprow5                 ; (the same instructions, between two bank switches)
  .else
        setbank BANK_MAP
        lda rc_y
        lsr
        tax
        lda LV_MAPROWLO,x
        clc
        adc rc_tx0
        sta ptr
        lda LV_MAPROWHI,x
        adc #0
        sta ptr+1
  .endif
@rowy:
  .if MODELB
        jsr mapstrip                ; the row's rc_nt+1 map bytes into MAPBUF, likewise
        wrsel BANK_TILES, BANK_TILES ; (mapstrip comes back with A = this bank: the
  .endif                            ;  write bank too, done here rather than in low RAM)
        ldy rc_nt
@gl:
  .if MODELB
        ; the tiles are contiguous from TILES (page aligned, 64 bytes each), so the
        ; address is arithmetic: no table beside them.  Ids from FLAT0 are fills -- a
        ; flat tile is two bytes alternating down every char (FLATTAB, the loader's;
        ; the two solids are the last two entries) -- flagged by bit 6 of the high
        ; byte, the low byte indexing the pair.
        ; Between the full tiles and the flats are the HALF tiles (ids from half0,
        ; the loader's): one 32-byte char row stored at halfhi:00 + k*32, the other
        ; either a fill (its pair in HALFPAIR) or the same row again.  Their low byte
        ; carries the flags: bit 2 = a half, bit 0 = the top row is the fill, bit 1 the
        ; bottom (neither: both rows are the stored one).
        lda MAPBUF,y
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
@gflat: sbc #FLAT0                  ; (C is set)
        asl
        sta GATHERL,y
        lda #$C0
        sta GATHERH,y
        dey
        bpl @gl
        bmi @gdone
@ghalf: tax                         ; X = the id, for the range tests
        sbc halfsub                 ; k, the slot from the halves' page (C is set)
        sta tmp
        lsr
        lsr
        lsr
        clc
        adc halfhi
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
:       eor #2                      ; from half2 (so from half1): 6 -> 4, both stored
@gh2:   sta GATHERL,y
        dey
        bpl @gl
@gdone:
  .else
        lda (ptr),y
        tax
        lda LV_PAGE0,x
        sta GATHERL,y
        lda LV_PAGE0+$100,x
        sta GATHERH,y
        dey
        bpl @gl
  .endif
  .if .not MODELB
        setbank BANK_TILES          ; gather done (it read bank 6); the tiles all live in
        ; bank 5, so switch once here, not per tile in @run
  .endif
        ; ---- draw this char row, and (without re-gathering) the odd row of the same tile row
        lda rc_y                    ; only a rect's first tile row can start on an odd
        and #1                      ; char row: after that @nextrow always lands even
        bne @second
        sta rc_sub                  ; A = 0: rc_y & 1 fell through
        lda rc_ro0
        sta rowoff
  .if MODELB
        lda #1                      ; the char row, as a half tile's flag bit
        sta rowbit
  .endif
        jsr @drawrow
        dec rc_h
        beq @done
@second:
        lda #32
        sta rc_sub
        ora rc_ro0
        sta rowoff
  .if MODELB
        lda #2
        sta rowbit
  .endif
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
  .if .not MODELB
        setbank BANK_MAP            ; @drawrow left the tile bank selected
        bne @rowy                   ; (always: A = BANK_MAP, not zero)
  .else
        jmp @rowy
  .endif
@done:  rts
@drawrow:
        inc rc_y                    ; the row this draws: nothing in @drawrow reads rc_y
        ; ---- screen base (per-rect ringaddr, +640 per row)
        lda rc_sp
        sta sp
        lda rc_sp+1
        sta sp+1
        ; a row spans <= 640 bytes: it can only cross the ring end if sp is within 768
  .if MODELB
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
        lda GATHERH,x               ; bit 6: solid cyan/black tile, filled not copied
        sta tp+1                    ; it is also the tile pointer's high byte, so keep it
        asl                         ; bit 6 to N; C = bit 7, set for every entry (a
        bpl :+                      ; tile page is $80-$BF, a fill $C0): the sec holds
        jmp @solid
:       lda GATHERL,x               ; every tile is in bank 5, selected once per tile row
  .if MODELB
        and #7
        beq @full
        and rowbit                  ; a half tile: is this row its fill?
        beq @hcopy
        jmp @hfill
@hcopy: lda GATHERL,x               ; no: the stored row -- (k&7)<<5 with this run's
        eor rowoff                  ; char offset less the row's 32: rowoff's bits
        and #$E0                    ; outside $E0 through the two eors
        eor rowoff
        bcs @tpsta                  ; (always: C is set at every entry to @run)
@full:  lda GATHERL,x
  .endif
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
  .if MODELB
        adc ringneg                 ; 256 - >RINGEND for the buffer being drawn
  .else
        adc #(256 - (>RINGEND))     ; = adc #$85 ; C set iff sp+1+C >= >RINGEND
  .endif
        bcs @slow
:
  .if MODELB
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
:       spnext                      ; (the label KEPT, unreferenced: anonymous count)
        dex
        dex
        bne @sc
        jmp @runend                 ; (out of bra's reach from here)
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
  .if ::MODELB
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
.if .paramcount = 2                 ; @p0 omits it: @advsp is the next instruction
        jmp next
.endif
.endmacro
@b31:   CHARCPY 3, @t3
@b23:   CHARCPY 2, @t2
@b15:   CHARCPY 1, @t1
@b7:    CHARCPY 0, @t0
@advsp: lda sp
        adc tmp                     ; C is already clear at every entry to @advsp
        sta sp
        bcc :++
        inc sp+1                    ; no ringup: both entries to @advsp have already
:                                   ; proved the run stays below RINGEND (rc_wrap).
        ; KEPT, unreferenced, so the anonymous-label count through drawrect is unchanged
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
        ; ---- solid tile: store one constant, no bank switch, no source pointer
  .if MODELB
@solid: ldy GATHERL,x               ; the flat pair: even lines from tp, odd from tp+1
        lda FLATTAB,y               ; (tp is otherwise unused on this path)
        sta tp
        lda FLATTAB+1,y
        sta tp+1
        bcs @fillgo                 ; (always: C is set at every entry to @run)
@hfill: lda GATHERH,x               ; the half's pair: k back out of its address
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
  .else
@solid: lda GATHERL,x
        and #$10
        beq :+
        deca                        ; $10 -> $0F: four dots of logical 1 (cyan); else 0 = black
:       sta tp                      ; fill value (tp is otherwise unused on this path)
  .endif
        lda #4                      ; (@fillgo)
  .if MODELB
        sec                         ; (@hfill's path; the Master's one entry has C = 1)
  .endif
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
  .if MODELB
        adc ringneg
  .else
        adc #(256 - >RINGEND)
  .endif
        bcs @fslow                  ; (@fslow sits before the cascade: in reach on both)
  .if MODELB
:       lda @ft-2,x                 ; jmpx @ft-2 less its pha/pla, and no load: A is
        sta jv                      ; dead, every entry is a FIL1, which loads tp+1
        lda @ft-1,x
        sta jv+1
        jmp (jv)
  .else
:       lda tp
        jmpx @ft-2
  .endif
@ft:    .word @f7, @f15, @f23, @f31
  .if MODELB                        ; the pair alternates down the lines: each entry
.macro FIL1 k                       ; is an odd line, so the cascade's parity is fixed
        ldy #k
        lda tp+1
        sta (sp),y
.endmacro
.macro FILN                         ; the next line down is even: tp
        dey
        lda tp
        sta (sp),y
.endmacro
.macro FILO                         ; and the one below odd: tp+1
        dey
        lda tp+1
        sta (sp),y
.endmacro
  .else
.macro FIL1 k
        ldy #k
        sta (sp),y
.endmacro
.macro FILN                         ; next line down: y-- ; A -> (sp),y
        dey
        sta (sp),y
.endmacro
.macro FILO
        dey
        sta (sp),y
.endmacro
  .endif
@fslow: lda rc_n
        sta tmp2
@fsc:
  .if MODELB
        FIL1 7
        FILN
        FILO
        FILN
        FILO
        FILN
        FILO
        FILN                        ; line 0 (even): Y = 1 -> 0
  .else
        lda tp
        ldy #7
        sta (sp),y
        dey
        sta (sp),y
        dey
        sta (sp),y
        dey
        sta (sp),y
        dey
        sta (sp),y
        dey
        sta (sp),y
        dey
        sta (sp),y
        staz sp                     ; line 0 non-indexed
  .endif
:                                   ; KEPT, unreferenced, so the anonymous-label
        ; count through drawrect is unchanged
        spnext
        dec tmp2
        bne @fsc
        jmp @runend
@f31:   FIL1 31
        FILN
        FILO
        FILN
        FILO
        FILN
        FILO
        FILN
@f23:   FIL1 23
        FILN
        FILO
        FILN
        FILO
        FILN
        FILO
        FILN
@f15:   FIL1 15
        FILN
        FILO
        FILN
        FILO
        FILN
        FILO
        FILN
@f7:    FIL1 7
        FILN
        FILO
        FILN
        FILO
        FILN
        FILO
  .if MODELB
        FILN                        ; line 0 (even): Y = 1 -> 0
  .else
        staz sp                     ; line 0 non-indexed
  .endif
        jmp @advsp

  .if MODELB
; @hfill's two loads of a half tile's pair: the table sits above the halves, wherever
; the level's tiles ended, and the loader patches the operands.  (Defined here, after
; the row loop: a label would end its @ scope, and := puts them in labels.txt.)
        .assert @hp1 = @hp0 + 5, error, "HPAIR1 must be 5 bytes past HPAIR0"
HPAIR0  := @hp0 + 1                 ; (the first := ends the @ scope: HPAIR1 goes by it)
HPAIR1  := HPAIR0 + 5
  .endif

; ============================================================================
; scroll_validate: make current buffer hold window (wcx, wcy) x 80 x 31
        PLACE "CODE", "TILCODE"     ; Model B: bank 5, with the row loop (F_RENDER5)
scroll_validate:
        ldx curbuf                  ; (an invalid buffer holds BUF_CX = $80xx, which the
:       txa                         ;  |dx| >= 80 test below sends to @full)                         ; (anonymous label kept: it holds the label count)
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
:       lda w16                     ; (anonymous label kept: it holds the label count)
        cmp #<-79
        bcc @full
:       ; dx negative: draw cols wcx .. wcx+(-dx)-1, rows wcy..wcy+BUFROWS-1
        eor #$FF                    ; (A still holds w16)
  .if MODELB
        adc #0                      ; C = 1 from the cmp: A = -w16, and C = 0 (w16 <> 0)
  .else
        inca
  .endif
        sta rc_w
        lda wcx
        sta rc_x
        lda wcx+1
        sta rc_x+1
  .if MODELB
        bcc @docols                 ; C = 0 from the adc
  .else
        bra @docols
  .endif
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
  .if MODELB
        adc #0                      ; C = 1 from the cmp: A = -w16b, and C = 0
  .else
        inca
  .endif
        sta rc_h
        lda wcy
        sta rc_y
  .if MODELB
        bcc @dorows                 ; C = 0 from the adc
  .else
        bra @dorows
  .endif
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
; ============================================================================
; Persistent sprite records.  match_sprites: KEEP[i] = new sprite i identical to record i
; ============================================================================
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with the records
match_sprites:
        ldx curbuf
        lda RECCNT,x
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
  .if MODELB
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
  .if MODELB
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
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with the records (the rects it
erase_old:                          ; redraws are bank 5's tile blitter: a far call each)
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
  .if MODELB
        bankimm lda, BANK_TILES, BANK_LVL   ; bank 5's, by low RAM's direct switch (its
        jsr callbank                ; BANKENTRY is drawrect_clip)
  .else
        jsr drawrect_clip
  .endif
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
        PLACE "CODE", "LGCLO"       ; Model B: the logic's bank writes SPRLIST in low RAM
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
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with the prologue and the records
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
        bpl @pass                   ; (in range on both builds)
:       ldx curbuf
        lda NSPR
        sta RECCNT,x
        rts

; draw one sprite: A = id ; spx, spy = map px (ref point)
; A = sprite id. Game sprites (spbank = BANK_SPR): directory is in main RAM at
; SPR_TABLE; sprite data is in bank 4, or in ANDY ($8000, ROMSEL bit7) when the
; entry's flag bit2 is set. Title pieces (spbank != BANK_SPR): directory and data
; both live at TITLE_ADDR of that bank.
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with the records and SPRMASK
drawsprite:
  .if MODELB
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
  .if MODELB
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
  .if .not MODELB               ; (Model B: the directory is in this bank)
        ldx #BANK_LVL           ; SPR_TABLE is in bank 7; the whole prologue reads
        stx ROMSEL_CPY          ; the directory and none of it reads sprite data
        stx ROMSEL
  .endif
  .if MODELB
        clc
        adc sprtab                  ; the directory sits above the map: where the
        sta ptr                     ; loader put it (low.s)
        lda ptr+1
        adc sprtab+1
        sta ptr+1
        jsr dirfetch                ; the directory is in bank 6: its eight bytes come
  .else                             ; into low RAM and ptr points there
        adc #<(SPR_TABLE-1)         ; C = 1 from the cpx (X = BANK_SPR): the -1 takes it back
        .assert <SPR_TABLE <> 0, error, "drawsprite: adc #<(SPR_TABLE-1) needs <SPR_TABLE nonzero"
        sta ptr
        lda ptr+1
        adc #>SPR_TABLE
        sta ptr+1
  .endif
  .if MODELB
        lda MAPBUF+6                ; dirfetch left ptr = MAPBUF
  .else
        ldy #6
        lda (ptr),y
  .endif
        sta sp_flags
        bankimm ldx, BANK_SPR, BANK_LVL
  .if MODELB
        lsr                         ; C = flags bit 2
        lsr
        lsr                         ; and bit 1 = flags bit 4
        bcc :+
  .else
        bitimm 4
        beq :+
  .endif
        bankimm ldx, (BANK_SPR|$80), BANK_LVL
:
  .if MODELB
        and #2
  .else
        bitimm $10              ; A still holds the flags byte
  .endif
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
  .if MODELB
        pha                         ; the entry's low byte, kept across the mask fetch
  .else
        sta ptr                     ; only this path uses id*8 as the low byte unadjusted
        lda #>TITLE_ADDR            ; title ids are < 16: id*8 has no high byte
        sta ptr+1
  .endif
        lda spbank              ; title pieces keep directory and data in one bank
        sta sp_dbank
        .assert <TITLE_ADDR = 0, error, "drawsprite: the title directory/mask arithmetic needs a page-aligned TITLE_ADDR"
  .if MODELB                        ; bank 6 is not this one: the entry and the mask
        lda sp_id                   ; address come across through low RAM, the mask
        asl                         ; first (dirfetch reuses ptr and MAPBUF); C = 0
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
  .else
        sta ROMSEL_CPY
        sta ROMSEL
        ldy #6
        lda (ptr),y
        sta sp_flags
        lda sp_id                   ; the mask address table behind the directory
        asl
        tax
        lda TITLE_ADDR+$80,x
        sta sp_mbase
        lda TITLE_ADDR+$81,x
        sta sp_mbase+1
  .endif
@entry2:
  .if MODELB                        ; both ways in end with dirfetch: ptr = MAPBUF
        lda MAPBUF
        sta sp_ptr
        lda MAPBUF+1
        sta sp_ptr+1
        lda MAPBUF+2
        sta sp_w
  .else
        ldaz ptr
        sta sp_ptr
        ldy #1
        lda (ptr),y
        sta sp_ptr+1
        iny
        lda (ptr),y
        sta sp_w
  .endif
        beq @out0
:                                   ; keep the bare label: it preserves the anonymous-label count
  .if MODELB
        lda MAPBUF+7                ; ptr = MAPBUF (dirfetch)
  .else
        ldy #7
        lda (ptr),y
  .endif
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
  .if MODELB
        sbc #0                      ; C = 0 still (c0 + W < 256): A - 1, as deca
  .else
        deca
  .endif
        cmp #ROWCHARS
        bcc :+
        inc spclip                  ; and at the right
        lda #(ROWCHARS-1)
:       sta sp_c1
  .if MODELB
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
  .if .not MODELB               ; (Model B: the data's bank runs the loop, below)
        lda sp_dbank            ; done with the directory: the blitter wants the data
        sta ROMSEL_CPY
        sta ROMSEL
  .endif
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
  .if MODELB
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
        ; clip lstart = max(lb0,0) ; lend = min(lb1, 247)
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
:                                   ; (kept: it holds the anonymous label count)
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
  .if MODELB
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
  .if MODELB
        adc #0                      ; and set by this one (sp_r1 >= sp_r0): + 1
  .else
        inca
  .endif
        ldx spclip
        beq :+                      ; may be visible next time and it has to be redrawn
        ora #$80
:       sta (rp),y
  .if MODELB
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
  .if MODELB
        stx sp_disp                 ; the loop copy in the data's bank patches its own jump
  .else
        lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
  .endif
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
  .if MODELB
        jsr ringaddr7               ; this bank's own copy (no crossing)
  .else
        jsr ringaddr
  .endif
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
  .if MODELB
        ; the row loop and the inner blocks are assembled into each sprite data bank
        ; (SPRITE_LOOPS below): call the copy in the bank the directory named, through
        ; low RAM's direct switch (both banks enter at BANKENTRY) and back to this bank
        lda sp_dbank
        jmp callbank
  .endif
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
    .if ::MODELB
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
        asl                         ; it needs no table at all (was lda/asl/tax/jmpx, 21
        tax                         ; cycles of dispatch to reach the same place)
  .if ::MODELB
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
  .if ::MODELB
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
  .if ::MODELB
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
  .else
        tax
        jmpx et
et:     .word p0, p1, p2, p3
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
; The row loop and the inner blocks.  On the Master this is plain code after the
; prologue; on the Model B it is assembled once into EACH sprite data bank (the loop
; reads image bytes, so it must be resident with them) and reached by a far call
; from the prologue, which lives with the directory in bank 5.
.macro SPRITE_LOOPS withmirror, withcopy, bank   ; withmirror = 0: a copy for a bank
  .if ::MODELB                      ; whose images are never drawn mirrored (no sprFM,
                                    ; no SWAPTAB); withcopy = 0: none drawn by the copy
                                    ; blitter (no sprFC); bank: the one this copy is in
ds_entry:                           ; the far entry: the dispatch jump is patched here,
        wrsel bank, bank            ; in the bank that owns it -- so the write bank is
        ldx sp_disp                 ; set here, not in low RAM's callbank (A = the bank)
        lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
  .endif
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
  .if ::MODELB
        .segment "SPR4CODE"
        .scope spr4
        SPRITE_LOOPS 1, ::SPR4_COPY, ::BANK_SPR   ; (assets.inc: the packer puts the box stars in one
        .if ::SPR4_COPY             ;  bank and no mirrored image in the other)
        SPRFULL sprFC, 0, 1
        .endif
        .endscope
        .segment "SPR4END"          ; the same entry address in both banks (BANKENTRY),
        jmp spr4::ds_entry          ; for low RAM's callbank
        .segment "SPR6CODE"
        .scope spr6
        SPRITE_LOOPS ::SPR6_MIRROR, 1, ::BANK_TIL1
        SPRFULL sprFC, 0, 1
        .endscope
        .segment "SPR6END"
        jmp spr6::ds_entry
        .segment "TIL5END"          ; and bank 5's, for erase_old's rects: through
        jmp bank5_entry             ; the stub that sets the write bank (banks.s)
        PLACE "CODE", "TILCODE"
  .else
        SPRITE_LOOPS 1, 1
sp_mpg0:  .res 1                  ; MASKTAB page of the sprite's first column: >MASKTAB0 | phase
sp_mrp:   .res 2                  ; mask pointer for the current row's first column
sp_mbase: .res 2                  ; the sprite's mask plane
SWAPTAB:                          ; four-dot reversal for mirroring: dot i is bits 7-i and
  .repeat 256, sv                 ; 3-i, so 7<->4, 6<->5, 3<->0, 2<->1
        .byte ((sv & $88) >> 3) | ((sv & $44) >> 1) | ((sv & $22) << 1) | ((sv & $11) << 3)
  .endrepeat
SECTAB:    .res 2*48              ; per buffer: 6 sections x 8 bytes
music_tab:                        ; SN76489 periods for MIDI 24..95: the first 144 bytes of
        .incbin "build/MUSIC", 0, 144   ; the MUSIC file (tools/midi2snd.py)
        SPRFULL sprFC, 0, 1         ; box stars: pre-composited on their background, no mask
  .endif

; (There were half-res blitters here -- one source byte to two screen lines -- for the
; title's Cleo frames.  Every image is full-res now, so entries 0/1 of sprdisp_tab
; alias the full blitters and the flag bit is vestigial.)

; ============================================================================
; copy_partial: copy lines wfine..7 of ring row wcy into lines 0..(7-wfine) of the
; ring row above the window (the "A" section source), for the columns drawn since.
; ============================================================================
        PLACE "CODE", "TILCODE"     ; Model B: bank 5, with the ring work
copy_partial:                       ; the whole row, every frame the fine scroll is not 0
        lda wfine                   ; (it used to track the columns drawn since the last
        bne :+                      ;  copy: measured, that saved under 0.3% of a frame)
        rts
:
:
:       lda #ROWCHARS               ; (the three ':' keep the anonymous label count)
        sta cnt
        lda #0
        sta tmp4                    ; first column to copy
        clc
        adc wcx
        sta w16
        lda wcx+1
        adc #0
        sta w16+1
  .if MODELB
        lda barq                    ; the composed row is the ring row above the window,
        bne @nomir                  ; the last slot when the window starts at slot 0
        lda tmp4                    ; C = 0 from the w16+1 adc (wcx < $8000)
        adc cnt
        tax
        dex
        lda tmp4
        jsr mirdirty5
@nomir:
  .endif
        lda wcy
        jsr ringaddr                ; sp = source start (row wcy, first dirty column)
        ; source: sp is the char, and the copy starts wfine lines into it.  Offsetting
        ; sp by wfine (under 8, and a char is 8-aligned) keeps its page crossings on
        ; the real char boundaries, so spnext's fold still lands where it should
        lda sp
        clc
        adc wfine
        sta sp
        ; dest: the same column of the composed row, ring char (ringS + col + 2480)
        ; mod 2560 -- the row above the window -- as a real address from RINGBASE
        lda tmp4                    ; C = 0: sp was a char (8-aligned) + wfine (< 8)
        adc #<(-ROWCHARS)           ; ringS + tmp4 - 80: this low add cannot carry (tmp4 <= 79)
        adc ringS
        sta ptr
        lda ringS+1
        adc #$FF                    ; C = 1: >= 0, already in the ring
        bcs @pnf
  .if MODELB
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
  .if MODELB
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
  .if MODELB
        adc #0                      ; C = 1: the bcc fell through; ringup's cmp resets it
  .else
        inca
  .endif
        ringup ptr
        sta ptr+1
        bne @fjmp                   ; Z = 0: A is a ring high byte, never 0
@done:  rts

; ============================================================================
; blank_below: the 6845 always displays the first scanline of a frame, whatever R6
; says, so the blanking section's row 0 line 0 -- the ring slot below the playfield --
; is a 241st line under the picture.  Everywhere it is the next map line; parked on
; the map's bottom row it is whatever that never-drawn slot last held.  So when the
; window sits on the bottom row, blank the slot, once per buffer per arrival.
; ============================================================================
        PLACE "CODE", "TILCODE"     ; Model B: bank 5, with the ring work
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
        jsr ringaddr                ; sp = its ring address
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
; calc_ring: ringS = ((wcy & 31) * 80 + wcx) mod 2560 ; barq = ringS / 80
; ============================================================================
; copy_bar: if this buffer's bar rows are stale, write bar image into ring slots q-3, q-2
; The bar has a fixed home outside the ring, so it stays put however the window
; scrolls and is only written when its contents change.  It used to live in the two
; ring rows above the window, which move every frame the view scrolls vertically;
; re-copying 1280 bytes for that cost 13,310 cycles of an 80,000 cycle frame.
; bar_bg: lay the static bar template (icons, labels, blank digit slots) from the span
; list in bank 6 into the bar, once, at start-up (main.s).  Model B: the loader puts the
; BAR file in place with the title (ldprog.s), and this only resets the digit cache.
        PLACE "CODE", "LGCCODE"
bar_bg:                             ; and never redrawn: only the digit cache is reset
        ldx #8                      ; level).  The template buries the digits, so the
        lda #$FF                    ; cached "already drawn" values are no longer true.
@bci:   sta BARCACHE,x              ; (One bar, one cache: this used to index it by
        dex                         ; curbuf and, at a level start with curbuf = 1,
        bpl @bci                    ; reset the wrong 16 bytes and left the digits stale)
  .if MODELB
        rts
  .else
        lda #HUD_BANK               ; The bar is black with a few icon spans, so
                                    ; fill black and lay the spans (BARBUF is now the span
        sta ROMSEL_CPY              ; list: offset16, len, bytes... ending $FFFF).
        sta ROMSEL
        lda #0                      ; MODE 1 black is plain 0: no opaque-black tag
        tax                         ; five abs,x stores cover the 5 pages in one pass
@bf:    sta BARADDR+$000,x
        sta BARADDR+$100,x
        sta BARADDR+$200,x
        sta BARADDR+$300,x
        sta BARADDR+$400,x
        inx
        bne @bf
        lda #<BARBUF
        sta w16
        lda #>BARBUF
        sta w16+1
@bs:    ldy #1
        lda (w16),y                 ; offset high ($FF = end)
        cmp #$FF
        beq @bsdone
        tax                         ; X is free: the @bf counter ran down to 0
        ldaz w16                    ; offset low, (zp): Y stays 1
        clc
        adc #<(BARADDR-3)           ; dest - 3: the copy's Y runs 3..len+2, over the
        sta w16b                    ; header, so w16 needs no step past it
        txa
        adc #>(BARADDR-3)
        sta w16b+1
        iny                         ; Y = 2
        lda (w16),y
        adc #3                      ; C clear: no carry out of the high byte above
        sta tmp2                    ; len + 3
        iny                         ; Y = 3
@bc:    lda (w16),y
        sta (w16b),y
        iny
        cpy tmp2
        bne @bc
        tya                         ; step past the header and the data (Y = len + 3)
        clc
        adc w16
        sta w16
        bcc @bs
        inc w16+1
        bra @bs
@bsdone: rts
  .endif

; ============================================================================
  .if .not MODELB                   ; (Model B: its rupture chain is modelb/src/display.s)
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
BARLEAD = 10                        ; us the bar's T1 fires early, beyond the lead every
                                    ; step has, so ACCCON D can be switched in the
                                    ; blanking of the bar's last line
BARCRTC  = BARADDR / 8
        .code
        .segment "LOGIC"            ; back to the bank
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
        ; The run is never split any more: a row that straddles the ring end is
        ; folded by the CRTC, so the playfield is one section however the window sits.
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
        ; --- A = rows: advance w16 by that many rows, folding into 0..RINGCHARS
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

        PLACE "CODE", "TILCODE"

BARROWS = 2                        ; the status bar
QROWS  = 39 - VISROWS - BARROWS    ; blank rows after the display: 312 lines in all
  .if MODELB
QVSYNC = 8                         ; vsync at Q row 8 of 16: the picture starts 64 lines after
                                   ; it, 4 lines below where a MODE 1 screen sits
  .else
QVSYNC = 3                         ; vsync at Q row 3 of 7: four rows (32 lines) between the
                                   ; vsync and the bar, which is where the bar is drawn, and
                                   ; three below.  Measured against the Master MOS's own
                                   ; a standard frame (R7 = 35): the picture sits exactly where it does.
  .endif

; ============================================================================
; Frame control
; ============================================================================
; select CPU access to the current back buffer (ACCCON X bit)
        PLACE "CODE", "TILCODE"     ; Model B: bank 5 (the menus are there too)
select_backbuf:
  .if MODELB
        ldx curbuf                  ; the buffer's ring: its base and end, the two
        lda @bhi,x                  ; derived constants the blitters' wrap tests use,
        sta ringbhi                 ; and the row table from its base
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
  .if MODELB
        jmp build_ring              ; the row table from the base (recp untouched)
@bhi:   .byte >RING_A, >RING_B
@ehi:   .byte >RINGEND_A, >RINGEND_B
  .else
        rts
  .endif
@rlo:   .byte <SPRREC, <(SPRREC+MAXREC*10)
@rhi:   .byte >SPRREC, >(SPRREC+MAXREC*10)

; render everything queued for the current back buffer and request flip
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with the game loop; the ring work
render_frame:                       ; is render_core in bank 5
        jsr wait_flip               ; the previous frame's flip must land before we
  .if .not MODELB
        jsr select_backbuf          ; draw into the buffer it is leaving
  .endif
        ; ---- the bar first.  It is single buffered and drawn where it is displayed,
        ; so it has to be finished before the CRTC reaches it: T starts 40 lines after
        ; the vsync wait_flip just returned from, which is 2560 cycles.  Only digits:
        ; the template is laid once (Master: main.s; Model B: with the title) and
        ; nothing erases it -- the menus keep to the ring (menu_sections).
:       lda BARDIRTY
        beq :+
        jsr t_redraw_hud
  .if MODELB
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
        lda wy+1                    ; wcy = wy >> 2, a full 16-bit shift: shifting the
        lsr                         ; high byte once only was right below wy = 512 and
        sta wcy                     ; lost 128 rows above it, which put the tall maps
        lda wy                      ; 512 px out of place once the player got that deep
        ror
        lsr wcy
        ror
        sta wcy
  .if MODELB
        jsr render_core
  .else
        jsr calc_ring
  .ifdef PARALLAX
        jsr pl_erase                ; the buffer still holds the line drawn into it
  .endif                            ; two frames ago: take it out before anything else
        jsr match_sprites
        jsr erase_old
        jsr scroll_validate
        jsr draw_dirty
        jsr draw_sprites
        jsr copy_partial
        jsr blank_below
  .ifdef PARALLAX
        jsr pl_draw                 ; last, behind the sprites: sky pixels only
  .endif
  .endif
        stz NSPR                    ; A dead: build_sections starts ldx/lda
  .if MODELB
        jsr build_sections
  .else
        jsr t_build_sections
  .endif
        ; hand over to ISR
        lda curbuf
  .if .not MODELB
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
  .if MODELB
MENURING = RING_A
  .else
MENURING = RINGBASE
  .endif
MENUBAR  = (MENURING + VISROWS*ROWBYTES) / 8
        .assert VISROWS + BARROWS <= RINGROWS, error, "the menus' bar rows must be in the ring"
menu_sections:
        jsr build_sections
        lda #>MENUBAR
        sta BUF_SEC0
        lda #<MENUBAR
        sta BUF_SEC0+1
        rts

; ---------------------------------------------------------------- load mode
; A disc load stops the chain: the Model B's loader runs with interrupts off, the
; Master's pages banks under it.  Stopped mid-chain the CRTC repeats whatever section
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
; Both targets: the switch is the interrupt handler's bar step (engine.s @ldsw, the
; Model B's display.s @ldsw), so it happens at the frame boundary however long the
; handler's other work runs.  (The Model B's first version waited for a vsync, turned
; interrupts off and polled for the bar's T1: when the vsync's own work ran past that
; T1, the switch landed one section late and made a short frame.)
load_begin:
        lda #1
        sta LOADREQ
:       lda LOADREQ
        cmp #2
        bne :-
        rts
load_end:                           ; (with interrupts off on the Model B: disc.s)
        lda #3                      ; resume asked: the next real vsync arms T1, turns
        sta LOADREQ                 ; its interrupt on and clears this (curR7 holds
        lda #$42                    ; LDR7 from the switch); until then a T1 flag is
        sta VIA_IFR                 ; stale.  A vsync flag raised meanwhile is stale too
        rts

  .ifdef PARALLAX
; ============================================================================
; Parallax experiment (-D PARALLAX, Master): a 1:1 diagonal across the window, drawn
; into the sky.  Window line L carries dot L: a dot right per scanline is 45 degrees
; in game pixels (a game pixel is 2 dots by 2 lines).  Only a sky pixel takes the
; line: the cell's map tile must be the solid sky fill and the pixel itself cyan --
; the cyan holes in a sprite's box take it too, which puts the line behind the
; sprite, and a sprite's own pixels stop it.  The line is in screen space and the
; buffer in map space, so each buffer remembers the window the line was drawn at
; and pl_erase walks that path first, turning its yellow back to cyan.  The buffer
; is untouched between the two, so the old path is exact.
; ============================================================================
        .segment "TABLES"           ; the walker's cursor (zero page is full; only the
pl_cx = w16                         ;  pointer needs it, and ringaddr's own w16 serves
pl_cy:    .res 1                  ; map char row of the cell under the cursor
pl_ln:    .res 1                  ; scanline within the cell, 0..7
pl_dot:   .res 1                  ; dot within the byte, 0..3
pl_l:     .res 1                  ; window lines left
pl_mode:  .res 1                  ; bit 7: 1 = draw, 0 = erase
pl_tile:  .res 1                  ; the map tile under the cursor
        .code
pl_state:                           ; per buffer: valid, wcx lo, wcx hi, wcy, wfine
pl_valid: .byte 0, 0
pl_ocxl:  .byte 0, 0
pl_ocxh:  .byte 0, 0
pl_ocy:   .byte 0, 0
pl_ofine: .byte 0, 0
pl_hi:    .byte $80, $40, $20, $10 ; a dot's high bit (yellow = both, cyan = low only)
pl_lo:    .byte $08, $04, $02, $01
pl_both:  .byte $88, $44, $22, $11
pl_nothi: .byte $7F, $BF, $DF, $EF

pl_erase:
        ldx curbuf
        lda pl_valid,x
        beq @no
        lda pl_ocxl,x
        sta pl_cx
        lda pl_ocxh,x
        sta pl_cx+1
        lda pl_ocy,x
        sta pl_cy
        lda pl_ofine,x
        sta pl_ln
        stz pl_mode
        jmp pl_walk
@no:    rts

pl_draw:
        ldx curbuf
        lda wcx
        sta pl_cx
        sta pl_ocxl,x
        lda wcx+1
        sta pl_cx+1
        sta pl_ocxh,x
        lda wcy
        sta pl_cy
        sta pl_ocy,x
        lda wfine
        sta pl_ln
        sta pl_ofine,x
        lda #1
        sta pl_valid,x
        lda #$80
        sta pl_mode
        ; fall through
; walk the path from (pl_cx, pl_cy, line pl_ln) for VISLINES lines
pl_walk:
        lda ROMSEL_CPY              ; maprow/mapbyte leave bank 7 paged: put back
        pha                         ; whatever the render had
        lda #VISLINES
        sta pl_l
        stz pl_dot
        jsr @cell
@line:  lda pl_tile
        cmp #SOLID_CYAN
        bne @skip
        ldx pl_dot
        lda (sp)
        and pl_both,x
        bit pl_mode
        bmi @draw
        cmp pl_both,x               ; erase: yellow -> cyan
        bne @skip
        lda (sp)
        and pl_nothi,x
        sta (sp)
        bra @skip
@draw:  cmp pl_lo,x                 ; draw: cyan -> yellow
        bne @skip
        lda (sp)
        ora pl_hi,x
        sta (sp)
@skip:  dec pl_l
        beq @done
        inc pl_dot
        lda pl_dot
        cmp #4
        bne :+
        stz pl_dot
        inc pl_cx
        bne :+
        inc pl_cx+1
:       inc pl_ln
        lda pl_ln
        cmp #8
        beq @newrow
        inc sp                      ; the next line of the same cell: 8 bytes from
        bne :+                      ; a multiple of 8, so no fold inside a cell
        inc sp+1
:       lda pl_dot
        bne @line
        lda sp                      ; a new column: its cell is 8 bytes on
        clc
        adc #8
        sta sp
        lda sp+1
        adc #0
        ringup sp
        sta sp+1
        jsr @tile
        bra @line
@newrow:
        stz pl_ln
        inc pl_cy
        jsr @cell
        bra @line
@done:  pla
        sta ROMSEL_CPY
        sta ROMSEL
        rts
@cell:  lda pl_cy                   ; sp = screen address of (cx, cy) line ln (cx is
        jsr ringaddr                ; w16 already), and the map row of cy
        lda sp
        clc
        adc pl_ln
        sta sp
        bcc :+
        inc sp+1
:       lda pl_cy
        lsr
        jsr maprow
@tile:  lda pl_cx+1                 ; tile column = cx >> 2 (a tile is four chars)
        lsr
        lda pl_cx
        ror
        lsr
        tay
        jsr mapbyte
        sta pl_tile
        rts
  .endif
  .if MODELB
        .segment "LGCCODE"          ; the ring work: bank 7 drives it, and what reads the
render_core:                        ; records stays here; bank 5 (the tiles, the ring
        farjsr F_SELBB              ;   work) gets three far calls a frame
        jsr calc_ring
        jsr match_sprites
        jsr erase_old
        farjsr F_RENDER5            ; scroll_validate, draw_dirty, blank_below
        jsr draw_sprites
        farjsr F_COPYPART           ; copy_partial
        jmp mirror_copy             ; the straddling row's copy (display.s)
        .segment "TILCODE"
render5:
        jsr scroll_validate
        jsr draw_dirty
        jmp blank_below
  .endif


        PLACE "LOW", "TILCODE"     ; render-time helpers in the NMI page ($0D03..),
                                   ; copied there at init; Model B: bank 5
; ============================================================================
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
; drawrect_clip: like drawrect but clips the rect to the current window
; (rows wcy..wcy+BUFROWS-1, cols wcx..wcx+ROWCHARS-1).
        PLACE "LOW", "LGCCODE"      ; Model B: bank 7 (its tables are in main RAM)
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
  .if MODELB
        adc #ROWCHARS-1             ; C = 1 (the sec before dey): A + 80, the remainder,
        sta wcxm                    ; where the window starts in its slot
        lda #RINGROWS-1             ; the window row that lives in the last slot, and
        sbc barq                    ; the map row it shows.  C = 1: the adc carried
        sta rstar
        clc
        adc wcy
        sta mrow
  .endif
        rts

  .if .not MODELB                   ; (Model B: modelb/src/init.s -- its tables are static)
        .segment "LOW2"            ; MOS vector/VDU pages ($0206..$03FF), copied there after the MODE change:
                                   ; init-only table builders and the dirty-tile routines

; ============================================================================
; table init
; ============================================================================
        .segment "LOGIC"            ; cold, and main RAM under the screen is full
init_tables:                        ; (the tables themselves are the file TABLES)
        stz RECCNT
        stz RECCNT+1
        stz DIRTYCNT
        stz DIRTYCNT+1
        lda #$80                    ; both buffers invalid (scroll_validate: an unreachable
        sta BUF_CX+1                ; window x, so the first render of each is a full one)
        sta BUF_CX+3
        stz NSPR
        stz SFXREQ
        stz SFXPTR+1
        stz MUSON
        stz DISPSECT
        stz curbuf
        lda #BANK_SPR
        sta spbank
        lda #$FF
        sta tset                    ; no tile set resident yet
        stz BARDIRTY
        rts


; identity table for the sprite blitter (A | X without a temp store)
  .endif
        PLACE "LOW2", "TILCODE"     ; back to the render helpers


; ============================================================================
; dirty tiles: redraw changed map tiles (both buffers keep their own list)
; ============================================================================
        PLACE "LOW2", "TILCODE"     ; Model B: bank 5 (the logic reaches it through the
  .if MODELB                        ; far table, which takes X: m_mark_dirty parks it)
mark_dirty_x:                       ; (the only entry here: ty stays in farx)
  .endif
mark_dirty:                         ; A = tx, X = ty  (adds to both buffers' lists)
        sta tmp
  .if .not MODELB
        stx tmp2
  .endif
        ldx #1
@b:     lda DIRTYCNT,x
        cmp #16
        bcs @next
        asl                         ; cnt*2, C = 0 (cnt < 16)
        cpx #1
        bcc @b0                     ; buffer 0: its list is at 0
        adc #31                     ; buffer 1: C = 1, so this adds 32
@b0:    tay
        lda tmp
        sta DIRTYLIST,y
  .if MODELB
        lda farx                    ; ty, where m_mark_dirty parked it
  .else
        lda tmp2
  .endif
        sta DIRTYLIST+1,y
        inc DIRTYCNT,x
@next:  dex
        bpl @b
        rts

        PLACE "LOW2", "TILCODE"     ; Model B: bank 5, with drawrect
draw_dirty:
        ldx curbuf
        lda DIRTYCNT,x
        beq @done
        sta lcnt
        txa
        lsr                         ; C = curbuf (0 or 1), A = 0
        ror                         ; curbuf * $80, C = 0
        lsr
        lsr                         ; curbuf * 32
        sta lidx
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
        jsr drawrect_clip
        dec lcnt
        bne @l
        ldx curbuf
        stz DIRTYCNT,x              ; A is dead: both callers reload it at once
@done:  rts

  .if .not MODELB                   ; (Model B: modelb/src/display.s, in bank 6)
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
        bit irq_x                   ; 3-cycle pad for the jmp it replaces: off, so its flag
                                    ; is stale: was this the vsync?
@notT1:
        lda VIA_IFR
        and #$02
        bne :+
        beq @xit                    ; (Z = 1: the bne fell through)
:       ; ---- vsync: restart T1 first (constant latency), counter = vsync->T.  The
        ; latch (how long section 0 lasts) is programmed further down, after the
        ; flip, because with no status bar section 0's length depends on the fine
        ; scroll and so belongs to the buffer that is about to be displayed.
        lda #<VS2T                  ; (immediate: 4 cycles earlier than the old RAM copy,
        sta VIA_T1LL                ;  which VS2T allows for)
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
        ; re-phase: the vsync fired at row curR7, so end this frame at row curR7+5 with
        ; 8-line rows -> T starts exactly 40 lines after the vsync even if the CRTC row
        ; counter had run past its vertical total (which otherwise never recovers)
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
        ; displayed -- its start address, and (with no status bar) its length
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
@exit:
        ldy irq_y
        ldx irq_x
        lda $FC
        rti

; CA1 fires at the end of the 2-line vsync pulse.  -35 put every step ~5 us INTO its
; section; the further -36 puts it ~30 us before the restart, so that the shape
; registers land early in the first scanline -- see the chain step in irq_handler.
VS2T = (QROWS-QVSYNC)*8*LINE - 2*LINE - 35 - 36 - 8 + 2   ; -8: the step's load-flag test; +2 (ticks): the
                                    ; vsync handler loads it as an immediate, 4 cycles sooner
  .endif

; ---------------------------------------------------------------- keyboard
        PLACE "CODE", "LGCCODE"     ; Model B: bank 7, with the interrupt's own work
scan_keys:
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
  .if MODELB
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
  .if MODELB
        lda MUSON                   ; the tune is stepped by the interrupt stub (low.s):
        sta MUSTICK                 ; its player is in bank 5's menu overlay.  Only from
        rts                         ; here, the vsync: the chain's T1 steps share the stub
  .else
  .ifdef DBGSND                     ; diagnostic build (DBGSND=1 sh build.sh): while no
        lda MUSON                   ; music plays, re-silence one of the channels play
        bne :+                      ; never writes -- channel 0, channel 1, noise, in
        lda vsyncs                  ; turn, a frame each.  A tone that survives this on
        and #3                      ; hardware is not in the SN76489's registers.
        tax
        lda @dbgsil,x
        beq :+
        jsr sndwrite
:
  .endif
        jmp music_tick
  .endif
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
  .if .not MODELB
        nop                         ; = lda #0: the store lands on the same cycle
        stz VIA_ORB
  .else
        lda #0
        sta VIA_ORB
  .endif
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
  .if MODELB
.macro sndw                         ; the player's own copy, in its bank
        jsr sndwrite_m
.endmacro
  .else
.macro sndw
        jsr sndwrite
.endmacro
  .endif

; ---------------------------------------------------------------- music
; 144-byte period table then the sequence (4-byte records: frames, note0..2;
; frames = 0 -> loop).  It used to be hidden in bit 6 of the tile bytes, which only
; worked while the whole tile set was resident; a level now loads just the tiles it
; uses, so the music is its own file -- in bank 7 above the logic: bank 6 has no room
; ($B000 + 2208 bytes of box stars runs past $B800, which is where it used to sit, and
; the music load then took the tail off the last trampoline box).
  .if .not MODELB                   ; (Model B: a label in bank 6, with the player)
MUSIC_ADDR = $B000                  ; bank 7: LOGIC may reach $B000, LV_ALTTAB is at $BE00
  .endif
MUSIC_SEQ  = MUSIC_ADDR + 144
  .if MODELB
MUSIC_TAB  = MUSIC_ADDR             ; the player is in the data's bank: no copy needed
  .else
MUSIC_TAB  = music_tab              ; 72 x 2 byte periods (MIDI 24..95), assembled in CODE
  .endif
        PLACE "CODE", "MNUCODE"     ; Model B: the menu overlay, with the tune
  .if MODELB
sndwrite_m:
        SNDWRITE_BODY
  .endif
music_tick:
  .if MODELB                        ; the overlay comes off the disc, so the loader
        ldx PBOARD                  ; cannot patch a companion in: the write bank by hand
        beq @wr                     ; (A = this bank's socket, from the interrupt stub;
        cpx #BOARD_SOLIDISK         ;  MUSDUR, MUSNOTE and MUSPTR below are this bank's)
        beq @sol
        ldx PBANK+1                 ; Watford: a store to $FF30 + bank 5's socket
        sta WRSEL_WATFORD,x
        bcc @wr                     ; C = 0: PBOARD = 1 < BOARD_SOLIDISK
@sol:   sta WRSEL_SOLIDISK          ; Solidisk: the socket on port B
@wr:
  .endif
        lda MUSON
        beq @done
        dec MUSDUR
        bne @done
  .if .not MODELB
        lda ROMSEL_CPY
        pha
        lda #BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
  .endif
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
  .if .not MODELB
        pla
        sta ROMSEL_CPY
        sta ROMSEL
  .endif
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
  .if MODELB
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

        PLACE "CODE", "LGCCODE"     ; (bank 7 stops it: the overlay may be gone)
music_stop:
  .if MODELB
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
        PLACE "CODE", "TILLOW"      ; Model B: bank 5's low corner, with init5 (once only)
take_over:
        sei
  .if .not MODELB
        lda IRQ1V
        sta OLDIRQ
        lda IRQ1V+1
        sta OLDIRQ+1
  .endif
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
  .if .not MODELB                   ; (Model B: modelb/src/display.s)
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
.if (RINGROWS & (RINGROWS - 1)) <> 0
ringmodtab:                         ; only a non-power-of-two ring needs the table; at
.repeat 256, i                      ; RINGROWS = 32 ringmod is `and #31` and this is 256
        .byte i .mod RINGROWS       ; bytes of main RAM that the bar now uses instead
.endrepeat
.endif
  .endif

        PLACE "CODE", "LGCCODE"     ; Model B: bank 7 (the menus call it)
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
  .if .not MODELB
; LV_PAGE0: tile id -> tile data address, the file PAGE0 loaded into bank 6 at $8500.
; Ids 0..253 address 64 bytes each from $8000 in the tile bank; 254 and 255 are the two
; solid fills, which own no bytes there -- hi bit 6 says "fill from a constant" and lo
; bit 4 picks cyan over black.  The same for every level and both sets.
        .segment "PAGE0"
        .assert * = LV_PAGE0, error, "PAGE0 must be linked at LV_PAGE0"
  .repeat 256, i                    ; lo: (id & 3) << 6
    .if i = SOLID_CYAN
        .byte $10
    .elseif i = SOLID_BLACK
        .byte 0
    .else
        .byte (i & 3) << 6
    .endif
  .endrepeat
  .repeat 256, i                    ; hi: $80 | id >> 2
    .if i = SOLID_CYAN || i = SOLID_BLACK
        .byte $C0
    .else
        .byte $80 | (i >> 2)
    .endif
  .endrepeat
  .endif
  .if .not MODELB                   ; (Model B: static tables in main RAM (banks.s),
        .segment "TABLES"           ;  and no disc loader -- modelb/src/disc.s)
mulrowlo:                         ; ring row r -> r * 80 chars
  .repeat RINGROWS, r
        .byte <(r*ROWCHARS)
  .endrepeat
mulrowhi:
  .repeat RINGROWS, r
        .byte >(r*ROWCHARS)
  .endrepeat
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

        .segment "CODE"             ; (not TABLES: loading that file would overwrite these)
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
        inc ld_done                 ; 0 (stz before the command) -> non-zero
:       pla
        rti
nmi_nd: and #1
        bne :+
        inc ld_done
:       pla
        rti

; The 1770 answers at $FE24 (control) and $FE28 (registers).  Control selects the
; drive in bits 0-1 (one bit per drive), has reset in bit 2 (active low), the side
; in bit 4 and density in bit 5.
; The drive is whichever DFS has current when the game is *RUN, so a Gotek on drive
; 1 (*DRIVE 1, or *DIR :1, then *RUN CLEO) is read from where the game came: drive 0
; was hard-coded before.  DFS is asked (OSGBPB 6: current drive name and boot
; option) by disc_drive, which main.s calls first thing: the MOS vectors it goes
; through are overwritten by LOW2 once the mode is up, and the tables are cleared
; after that, so the answer lives in the code segment.  Drives 2 and 3 are the
; second sides of 0 and 1.
disc_drive:
        lda #6
        ldx #<ld_gbpb
        ldy #>ld_gbpb
        jsr OSGBPB
        ldx ld_drv                  ; the name's last character is the digit
        lda ld_drv,x
        and #3
        tax
        lda drvsel,x
        sta ld_ctl
        rts
ld_gbpb: .byte 0                    ; OSGBPB control block: the data address is all
        .word ld_drv, $FFFF         ;  call 6 reads (the I/O processor's memory, Tube
        .res 8                      ;  or no Tube)
ld_drv: .res 8                      ; its answer: <len> "<drive>" <len> <boot option>
ld_ctl: .byte $25                   ; the control byte for the drive (drive 0 unless asked)
drvsel: .byte $25, $26, $35, $36    ; drive 0, 1, 0 side 1, 1 side 1

; initialise: reset controller, restore head to track 0
disc_init:
        lda #$20
        sta FDC_CTRL                ; reset asserted (active low bit 2)
        lda ld_ctl
        sta FDC_CTRL                ; the drive, FM, reset released
        nop                         ; (keeps the reset-to-command gap)
        stz FDC_CMD                 ; restore, spin up, 6ms
        stz cur_trk
        jmp fdc_wait

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
        tax
        jsr music_stop
        lda ft_seclo,x
        sta ld_sec
        lda ft_sechi,x
        sta ld_sec+1
        lda ft_n,x
        sta ld_n
        lda ft_bank,x
        beq :+
        sta ROMSEL_CPY
        sta ROMSEL
:       lda ft_dest,x
        sta ptr+1
        stz ptr
        ; read ld_n sectors from linear sector ld_sec to ptr
ldread:
        ; track = ld_sec / 10, sector-on-track = ld_sec mod 10.  A 16-bit divide by
        ; repeated subtraction: the disc is 80 tracks, so the quotient is under 80 and
        ; this runs at most ~80 times, once per file.  (The old form accumulated the
        ; high byte as "25 tracks + 6 sectors" into the low byte, which overflowed a
        ; file whose start sector had a low byte of 250 or more -- L4B's header piece
        ; landed exactly there and read from the wrong track.)
        ldy #0                      ; Y = ld_sec / 10, A = ld_sec mod 10
        lda ld_sec
        ldx ld_sec+1
@d10:   cmp #10
        bcs @sub
        dex                         ; borrow from the high byte
        bmi @done                   ; none left: A is the sector
        sec
@sub:   sbc #10
        iny
        bne @d10                    ; (unconditional: Y stays under 80)
@done:  sta ld_sc
        sty ld_trk
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
        stz nmi_sta+1               ; ptr's low byte is always 0 here
        lda ptr+1
        sta nmi_sta+2
        clc                         ; ptr moves on now: the read does not use it
        adc tmp
        sta ptr+1
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
        lda ld_n
        sec
        sbc tmp
        sta ld_n
        beq ldr_end
        stza ld_sc
        inc ld_trk
        bra ldr_trk
ldr_end:  rts
  .endif

        PLACE "LOW2", "LOWCODE"     ; main RAM under the screen is full; the old MOS
; ============================================================================
; Map access for the logic, which lives in bank 7 and so cannot select bank 6
; itself.  Each of these leaves bank 7 selected, so the logic calls them directly.
; ============================================================================
; A = tile row -> mapptr = address of that map row
  .if MODELB
maprow:                             ; row * 2^lw = (row << 8) >> (8 - lw): mapshr is
        ldy #0                      ; the loader's (low.s); no table to page in.  X
        sty mapptr                  ; is kept (the logic calls this with it live);
        ldy mapshr                  ; Y comes back 0
        beq :++
:       lsr
        ror mapptr
        dey
        bne :-
:       clc
        adc #>LV_MAP
        sta mapptr+1
        rts
  .else
maprow: tay
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        lda LV_MAPROWLO,y
        sta mapptr
        lda LV_MAPROWHI,y
        sta mapptr+1
        jmp pagelogic
  .endif

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
  .if MODELB                        ; (LOWCODE: pagelogic follows directly)
        .assert * = pagelogic, error, "mapput falls into pagelogic"
  .else
        jmp pagelogic
  .endif

; the level's map row address table, from maplw (level_init's first job)
  .if MODELB
        .segment "LGCLO"
init_maprows:                       ; the row address is arithmetic here (maprow,
        rts                         ; maprow5): there is no table to build
  .else
init_maprows:
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        ldx maplw                   ; row stride = 1 << maplw bytes: lw = 8 shifts
        lda #1                      ; the 1 out into the carry, the high byte
:       asl
        dex
        bne :-
        sta t16b
        sta MAPSTRIDE
        txa                         ; (X = 0)
        rol
        sta t16b+1
        sta MAPSTRIDE+1
        ldy #<LV_MAP                ; Y = row address lo, A = hi, X = row
        lda #>LV_MAP
:       sta LV_MAPROWHI,x
        pha
        tya
        sta LV_MAPROWLO,x
        clc
        adc t16b
        tay
        pla
        adc t16b+1
        inx
        bne :-
        jmp pagelogic
  .endif


        PLACE "LOW2", "TILCODE"     ; Model B: bank 5, with select_backbuf
; the screen address of each ring row, from the base of the buffer being drawn (the
; Model B's: the Master's rows are the same for both buffers, assembled in TABLES)
  .if MODELB
build_ring:
        lda #<RING_A                ; both bases are xx80: the high byte is the buffer's
        sta RINGLO
        lda ringbhi
        sta RINGHI
        ldx #0                      ; C = 0 from both callers; then from the cpx
@r:     lda RINGLO,x                ; each row from the one before it
        adc #<ROWBYTES
        sta RINGLO+1,x
        lda RINGHI,x
        adc #>ROWBYTES
        sta RINGHI+1,x
        inx
        cpx #RINGROWS-1
        bne @r
        rts
  .endif
  .if .not MODELB
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
  .endif

; sign extend A -> tmp3 (0 or $FF).  In LOW2 (the old MOS vector page) because main
; RAM below the screen is full: there is room to spare there.
        PLACE "LOW2", "LGCCODE"     ; (its one caller is the sprite prologue: bank 7)
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
        PLACE "LOW2", "LOWCODE"
pagelogic:                          ; A, X, Y and the carry all come through intact:
        pha                         ; these sit in the middle of calls that return values
        bankimm lda, BANK_LVL, 0
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel BANK_LVL, 0           ; (the write bank too: bank 7's code stores)
        pla
        rts
  .if .not MODELB
.macro TOBANK n
.ident(.concat("t_", n)):
        jsr pagelogic
        jmp .ident(n)
.endmacro
; Only TOBANK pays for pagelogic being a subroutine: the jsr and its rts are 12 cycles
; of ceremony, where m_ and the six direct `jmp pagelogic` are tail jumps that waste
; nothing.  Of pagelogic's 54 executions a frame only 3.1 are t_ entries, so this is
; worth 36 cycles a frame, not the 646 the window-wide count suggested.  The inline form
; is 7 bytes dearer and the bridges live in LOW2, which has ten bytes to its name -- so
; the two that are worth it move to CODE, which gives LOW2 twelve bytes back.
.macro TOBANKI n
.ident(.concat("t_", n)):
        pha
        lda #BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        pla
        jmp .ident(n)
.endmacro
        .segment "CODE"             ; the two hot bridges, inlined, out of LOW2
        TOBANKI "game_frame"
        TOBANKI "build_sections"
        .segment "LOW2"

.macro TOMAIN n
.ident(.concat("m_", n)):
        jsr .ident(n)
        jmp pagelogic
.endmacro
        TOBANK "init_tables"
        TOBANK "draw_health"
        TOBANK "draw_lives"
        TOBANK "draw_score"
        TOBANK "redraw_hud"
        TOBANK "draw_stars"
        TOBANK "help_screen"
        TOBANK "level_init"
        TOBANK "level_select"
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
  .else
; Model B: the logic and the game loop share bank 7, so a bridge to it is only a
; name; what crosses a bank goes through the far table (modelb/src/defs.inc), and
; the menus, which the one-level disc does without, are stubs.
t_game_frame = game_frame
t_level_init = level_init
t_redraw_hud = redraw_hud
m_addsprite  = addsprite
m_clamp_window = clamp_window
m_rnd        = rnd
        .segment "LGCCODE"          ; two of bank 5's, reached from the logic and the
m_mark_dirty:                       ; sprite prologue: farcall takes X, so mark_dirty's
        stx farx                    ; X = ty crosses in farx
        ldx #F_MARKDIRTY
        jmp farcall
; bank 7's own ringaddr, for the sprite prologue: the ring modulus by subtraction (no
; table this side), the row multiple from the tables the chain keeps here, the
; buffer's base from select_backbuf (both bases are xx80: ringbhi is the page)
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
        adc #<RING_A
        sta sp
        pla
        adc ringbhi
        ringup sp
        sta sp+1
        rts
; The menus live in bank 5's overlay (menu.s under MNUCODE) and are called from bank
; 7; what they call back in bank 7 crosses the same way.  What they call in main RAM
; is a plain name.
.macro FARSUB name, idx
.ident(name):
        ldx #idx                    ; tail call: fcret returns to our caller
        jmp farcall
.endmacro
        .segment "LGCCODE"
        FARSUB "t_title_menu", F_TITLE
        FARSUB "t_help_screen", F_HELP
        FARSUB "t_level_select", F_LEVELSEL
        FARSUB "t_winlose", F_WINLOSE
        .segment "MNUCODE"
        FARSUB "m_blank_palette", F_BLANKPAL
        FARSUB "m_set_palette", F_SETPAL
m_wait_flip:                        ; (its own copy: the far table is full)
        lda flipreq
        bne m_wait_flip
        rts
        FARSUB "m_loadfile", F_LOADTITLE
        FARSUB "m_music_stop", F_MUSSTOP
        FARSUB "m_build_sections", F_BUILDSECT
        FARSUB "m_div10_16", F_DIV10
        FARSUB "m_calc_ring", F_CALCRING
        FARSUB "m_drawsprite", F_DRAWSPR
m_music_start = music_start
m_ringaddr = ringaddr
m_select_backbuf = select_backbuf
  .endif

; ============================================================================
; Random
; ============================================================================
        PLACE "CODE", "LGCLO"
rnd:    lsr seed+1
        ror seed
        bcc :+
        lda seed+1
        eor #$B4
        sta seed+1
:       lda seed
        rts
