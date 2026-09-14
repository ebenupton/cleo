; Cleo, Model B target.  One assembly, four bank images: see DESIGN.md.
        .include "defs.inc"
        .include "cpu.inc"
        .include "zp.inc"
        .import __LOWCODE_LOAD__: absolute, __LOWCODE_RUN__: absolute
        .import __LOWCODE_SIZE__: absolute
        .include "low.s"
        .include "bank7.s"

        .segment "SPRCODE"
        .byte 0
        .segment "TILCODE"
        .byte 0
        .segment "MAPCODE"
        .byte 0
