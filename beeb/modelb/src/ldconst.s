; The constants the loaders need that the linker does not list (build.sh prints them
; into defs_ld.inc): assembled with the game's own flags, so defs.inc's hardware
; conditionals resolve as they do in the game.
        .include "cpu.inc"
        .include "assets.inc"
        .include "defs.inc"
.macro OUTC name
  .ifdef name
        .out .sprintf("%s = $%04X", .string(name), name)
  .endif
.endmacro
        OUTC MENU_BASE
        OUTC TILES
        OUTC NFLAT
        OUTC BOXID0
        OUTC NMIPAGE
        OUTC LDPROG
        OUTC STAGE
        OUTC STAGE_LVL
        OUTC TITLE_ADDR
        OUTC MAP6
        OUTC BANKCODE
        OUTC LV_OBJS
        OUTC LV_PAGE0
        OUTC BOARD_STD
        OUTC BOARD_WATFORD
        OUTC BOARD_SOLIDISK
        OUTC WRSEL_WATFORD
        OUTC WRSEL_SOLIDISK
; and defs.inc's zero-page equates as labels, for the tools (build.sh appends them to
; labels.txt: ld65 lists labels, not equates)
.macro OUTL name
  .ifdef name
        .out .sprintf("al %06X .%s", name, .string(name))
  .endif
.endmacro
        OUTL NSPR
        OUTL BARDIRTY
        OUTL SFXREQ
        OUTL BINI
        OUTL sp_mh
        OUTL curR7
        OUTL SECIDX

; what defs.inc and assets.inc borrow from the engine, which is not assembled here
.macro STUB name
  .ifndef name
name = 0
  .endif
.endmacro
        STUB QVSYNC
        STUB QROWS
        STUB RING_A
        STUB RING_B
        STUB BARADDR
        STUB font_art
        STUB digits_art
