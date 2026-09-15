; ============================================================================
; Cleo, Model B target: the memory map is the design.
;
;   $0000-$00FF  zero page, shared by all four banks
;   $0100-$013F  stack
;   $0140-$02FF  ISR, section table, thunks, the map strip buffer
;   $0300-$07FF  status bar, 2 rows, single buffered, scanned where it is drawn
;   $0800-$0A7F  mirror A     a copy of ring A's last row
;   $0A80-$43FF  ring A       23 slots of 640 bytes
;   $4400-$467F  mirror B
;   $4680-$7FFF  ring B
; ============================================================================
ROWCHARS  = 80
ROWBYTES  = ROWCHARS*8
RINGROWS  = 23                      ; slots in a ring
VISROWS   = 21                      ; visible char rows: 168 lines = 84 game px
BUFROWS   = VISROWS + 1             ; held: the visible rows plus the bottom partial's source
RINGCHARS = ROWCHARS*RINGROWS
RINGBYTES = ROWBYTES*RINGROWS       ; 14720: NOT a whole number of pages, so the fold
                                    ; body is 16 bit -- but both ring ENDS are page
                                    ; aligned, so the fold test stays 8 bit
MAXDWY    = 8

BARADDR   = $0300
BARROWS   = 2
BARCRTC   = BARADDR / 8

RING_A    = $0A80
RING_B    = $4680
MIRR_A    = RING_A - ROWBYTES       ; $0800
MIRR_B    = RING_B - ROWBYTES       ; $4400
RINGEND_A = RING_A + RINGBYTES      ; $4400
RINGEND_B = RING_B + RINGBYTES      ; $8000
CRTCB_A   = RING_A / 8
CRTCB_B   = RING_B / 8

; 39 rows of 8 lines = 312.  2 bar + 21 playfield + 16 blanking, vsync at Q row 8, so
; the picture starts 64 lines after the vsync: 4 lines below where a MODE 1 screen sits.
VSPEG     = 4                       ; vsyncs a rendered frame: the logic steps once a
                                    ; frame, so a frame that sometimes takes two and
                                    ; sometimes three moves the world at two speeds
QROWS     = 39 - VISROWS - BARROWS
QVSYNC    = 8
LINE      = 64                      ; T1 ticks in one scanline
; CA1 fires at the end of the 2-line vsync pulse.  -35 would put each step ~5 us INTO
; its section; the further -36 puts it ~30 us BEFORE the restart instead, so the shape
; registers land early in the section's first scanline.
VS2T_DEFAULT = (QROWS-QVSYNC)*8*LINE - 2*LINE - 35 - 36

; ---------------------------------------------------------------- hardware
CRTC_IDX  = $FE00
CRTC_DAT  = $FE01
ULA_CTRL  = $FE20
ULA_PAL   = $FE21
VIA_T1CL  = $FE44
VIA_T1CH  = $FE45
VIA_T1LL  = $FE46
VIA_T1LH  = $FE47
VIA_ACR   = $FE4B
VIA_IFR   = $FE4D
VIA_IER   = $FE4E
UVIA_IER  = $FE6E
IRQ1V     = $0204
OSWRCH    = $FFEE

RINGMODTAB = $8000                  ; 256 bytes at the foot of every bank
BANKCODE   = $8100                  ; where each bank's code starts

MODE1     = 1                       ; the MODE 1 paths of the ported blitter
HUD_BANK  = BANK_LGC                ; the digits live with the logic that draws them
BOXN      = 15                      ; box stars and trampoline boxes, as convert.py packs them
LEVEL     = 3                       ; the one level this target carries (L3A)
BANK_LVL  = BANK_LGC                ; the logic's own bank, in the Master's name
VISLINES  = VISROWS*8               ; the window's height in scanlines
BINMAX    = 40                      ; cached object list: the most a frame needs
OBJN      = 32                      ; objects a level may hold (the Master allows 149)
K_LEFT    = 1
K_RIGHT   = 2
K_UP      = 4
K_DOWN    = 8
K_FIRE    = 16
K_MENU    = 32
WINTX     = 21                      ; tiles across the window, and down
WINTY     = 12
MAXSPR    = 24
MAXREC    = 16

; ---------------------------------------------------------------- far calls
; The index of a (bank, address) entry in FARTAB.  Everything that crosses a bank
; boundary goes through one of these, and the list is meant to stay short: the traffic
; is per frame or per rectangle, never per tile.
F_VSYNC    = 0*3
F_SCANKEYS = 1*3
F_SNDTICK  = 2*3
F_MAPSTRIP = 3*3
F_DRAWRECT = 4*3
F_TILCOPY  = 5*3                    ; bank 5's memcpy into MAPBUF
F_SPRCOPY  = 6*3                    ; bank 4's
F_DRAWSPR  = 7*3
F_ERASE    = 8*3
F_PARTIAL  = 9*3                    ; copy_partial
F_BARFLUSH = 10*3                   ; bar_draw
F_ADDSPR   = 11*3
F_SPRINIT  = 12*3
F_SPARE13  = 13*3                   ; (was the altitude row: the logic reads the
                                    ;  altitude tables in its own bank now)
F_MAPCOPY  = 14*3                   ; bank 6's
F_TILINIT  = 15*3
F_MAPRECT  = 16*3                   ; a whole tile rectangle in one call
NFAR       = 17
