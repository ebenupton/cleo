# Free space (bytes) before the grind

## Model B (modelb/build/map.txt: segment, start, end, size)
```
BANKFIX               000000  00010A  00010B  00001
WRFIX                 000000  000033  000034  00001
ZEROPAGE              000000  0000A2  0000A3  00001
LOWBSS                000140  000201  0000C2  00001
LOWCODE               000206  0002FF  0000FA  00001
NMISTUB               000D00  000D5E  00005F  00001
COMMON4               008000  00803F  000040  00001
COMMON5               008000  00803F  000040  00001
COMMON6               008000  00803F  000040  00001
COMMON7               008000  00803F  000040  00001
LGCENT                008040  008057  000018  00001
MAPLO                 008040  00807D  00003E  00001
TILLOW                008040  0080C7  000088  00001
LGCLO                 008058  0080F1  00009A  00001
LGCLOBSS              0080F2  0082ED  0001FC  00001
MNUCODE               008100  008890  000791  00001
LGCLVL                008300  00851F  000220  00001
SPR4SWAP              008300  0083FF  000100  00001
SPR4MASK              008400  0087FF  000400  00001
SPR6MASK              008400  0087FF  000400  00001
LGCDATA               008520  00882D  00030E  00001
LGCCODE               00882E  00B237  002A0A  00001
MNUDATA               008891  0091BC  00092C  00001
MNUBSS                0091BD  0091DB  00001F  00001
LGCBSS                00B297  00BFE1  000D4B  00001
TILCODE               00B620  00BF1F  000900  00001
SPR4CODE              00BBE0  00BFE9  00040A  00001
SPR6CODE              00BD60  00BFF2  000293  00001
TILBSS                00BF20  00BFF9  0000DA  00001
SPR4END               00BFFD  00BFFF  000003  00001
SPR6END               00BFFD  00BFFF  000003  00001
TIL5END               00BFFD  00BFFF  000003  00001
```

Model B memory areas (modelb/cleo_b.cfg):
```
MEMORY {
    ZP:      start = $0000, size = $00F0, type = rw, define = yes;
    LOWBS:   start = $0140, size = $00C4, type = rw, define = yes;   # $0140-$0203
    LOWRAM:  start = $0206, size = $00FA, type = rw, define = yes;   # $0206-$02FF, clear of IRQ1V
    B4C:     start = $8000, size = $0040, type = ro, file = "build/b4c.bin", fill = yes;
    B4T:     start = $8300, size = $0500, type = ro, file = "build/b4t.bin", fill = yes;
    B4X:     start = $BBE0, size = $0420, type = ro, file = "build/b4x.bin", fill = yes;  # to $C000: SPRENTRY at the top
    B5C:     start = $8000, size = $0100, type = ro, file = "build/b5c.bin", fill = yes;  # + the low corner: once-only code
    B5M:     start = $8100, size = $3500, type = rw, file = "build/MENU",    fill = no;   # the menu overlay
    B5X:     start = $B620, size = $09E0, type = rw, file = "build/b5x.bin", fill = yes;  # the tile blitter and the ring work, above the tiles; BANKENTRY at the top
    B6C:     start = $8000, size = $0040, type = ro, file = "build/b6c.bin", fill = yes;
    B6L:     start = $8040, size = $0140, type = rw, file = "build/b6l.bin", fill = yes;  # start-up + the low-RAM image
    B6T:     start = $8400, size = $0400, type = ro, file = "build/b6t.bin", fill = yes;
    B6X:     start = $BD60, size = $02A0, type = ro, file = "build/b6x.bin", fill = yes;
    B7A:     start = $8000, size = $0300, type = rw, file = "build/b7a.bin", fill = yes;
    B7D:     start = $8300, size = $0220, type = rw, file = "",              fill = no;   # the level's tables (loaded)
    B7:      start = $8520, size = $3AE0, type = rw, file = "build/b7.bin",  fill = no;
    NMI:     start = $0D00, size = $0100, type = rw, file = "",              fill = no;   # the NMI stubs run here (disc.s)
    BFX:     start = $0000, size = $0400, type = ro, file = "build/bankfix.bin", fill = no; # the bank-number patch list (cpu.inc BANKREF): appended to BANKS
    WFX:     start = $0000, size = $0400, type = ro, file = "build/wrfix.bin",   fill = no; # the write-bank store list (cpu.inc wrsel): appended after it
}
SEGMENTS {
    ZEROPAGE: load = ZP,     type = zp;
    LOWBSS:   load = LOWBS,  type = bss,   define = yes;
    COMMON4:  load = B4C,    type = ro;
    COMMON5:  load = B5C,    type = ro;
    TILLOW:   load = B5C,    type = ro;                               # init5 + take_over
    COMMON6:  load = B6C,    type = ro;
    COMMON7:  load = B7A,    type = ro;
    SPR4SWAP: load = B4T,    type = ro;
    SPR4MASK: load = B4T,    type = ro;
    SPR4CODE: load = B4X,    type = ro,    define = yes;
    SPR4END:  load = B4X,    type = ro,    start = $BFFD;             # jmp ds_entry (SPRENTRY)
    TILCODE:  load = B5X,    type = ro,    define = yes;
    TILBSS:   load = B5X,    type = bss,   define = yes;
    TIL5END:  load = B5X,    type = ro,    start = $BFFD;             # jmp drawrect_clip (BANKENTRY)
    MNUCODE:  load = B5M,    type = ro,    define = yes;
    MNUDATA:  load = B5M,    type = ro,    define = yes;
    MNUBSS:   load = B5M,    type = bss,   define = yes;
    MAPLO:    load = B6L,    type = ro;
    LOWCODE:  load = B6L,    run = LOWRAM, type = rw, define = yes;   # copied down by init.s
    SPR6MASK: load = B6T,    type = ro;
    SPR6CODE: load = B6X,    type = ro,    define = yes;
    SPR6END:  load = B6X,    type = ro,    start = $BFFD;
    LGCENT:   load = B7A,    type = ro;
    LGCLO:    load = B7A,    type = ro;
    LGCLOBSS: load = B7A,    type = bss,   define = yes;              # the sprite records
    LGCLVL:   load = B7D,    type = bss,   define = yes, align = $100;  # attr, altcls, hdr
    LGCDATA:  load = B7,     type = ro,    define = yes;
    LGCCODE:  load = B7,     type = ro,    define = yes;
    NMISTUB:  load = B7,     run = NMI,   type = ro,  define = yes;   # copied to NMIPAGE for a load
    LGCBSS:   load = B7,     type = bss,   define = yes;
    BANKFIX:  load = BFX,    type = ro;
    WRFIX:    load = WFX,    type = ro;
}
```

## Master (build/map.txt)
```
ZEROPAGE              000000  0000A5  0000A6  00001
LOW2                  000206  0003E6  0001E1  00001
TABLES                000400  000CE2  0008E3  00001
LOW                   000D03  000DB8  0000B6  00001
CODE                  000E00  0028CC  001ACD  00001
LOGIC                 008900  00AE63  002564  00001
MEMORY {
    ZP:    start = $0000, size = $00A8, type = rw;
    TAB:   start = $0400, size = $0900, type = rw;
    MAIN:  start = $0E00, size = $1D00, type = rw, file = %O, fill = no, define = yes;   # ends at BARADDR: $2B00..$2FFF is the status bar, which the CRTC scans with ACCCON D = 0
    LOGIC: start = $8900, size = $2700, type = rw, file = "build/LOGIC", fill = no, define = yes;   # bank 7, above the level's tables (a placement inherited from the Model B)
    LOW:   start = $0D03, size = $00ED, type = rw, file = %O, fill = no, define = yes;   # NMI page after the JMP; $DF0.. left to the MOS
    LOW2:  start = $0206, size = $01FA, type = rw, file = %O, fill = no, define = yes;   # MOS vectors (bar IRQ1V) + VDU page: free once the mode is set and the MOS is abandoned
}
```
