; ============================================================================
; The Master is a 65C02; the Model B is a 6502.  Every 65C02 spelling the engine
; and the logic use goes through a macro here, so one source assembles for both.
; The 6502 expansions have side effects the 65C02 forms do not, and every site has
; been audited for them -- the contracts:
;
;   stz m        A is DEAD at the site (the 6502 form is lda #0 / sta).  A site
;                where A must survive spells stza.  Both leave N,Z set from the
;                zero on the 6502; no site branches on the flags across either.
;   stza m       A survives (pha / lda #0 / sta / pla).
;   inca, deca   A +/- 1 with the CARRY PRESERVED (through mtmp), because the
;                sprite prologue relies on that where the 65C02 inc a does.
;   ldaz/staz/andz/cmpz  (zp) with no index: Y is DESTROYED (ldy #0).  The one
;                site with Y live spells ldazy, which keeps it.
;   bitimm v     bit #imm: Z from A & v, A and X preserved, through mtmp.
;   jmpx t       jmp (t,x) through the zero page vector jv.
;   phx/plx/phy/ply, bra: the obvious expansions (plx/ply set N,Z as the 65C02 do).
;
; mtmp is zero page scratch the expansions own; nothing that runs in the interrupt
; may use inca/deca/bitimm/ldazy (the interrupt paths are audited free of them).
; ============================================================================
; One structure, two machines: code in the sideways banks with the data it reads,
; the level gathered into the banks at load.  BHW is the Model B's HARDWARE: a 6502,
; one screen of main RAM (two software rings with mirror rows), the 8271 or Acorn
; 1770, the write-select boards.  BHW=0 is the Master's: 65C02, the hardware-wrapped
; ring in main and shadow RAM, its interrupt handler in main RAM, its 1770.
; build.sh builds both.
        .ifndef BHW
BHW = 1
        .endif
; TILEMIRROR: the tile blitter can draw a tile mirrored from another's bytes, and the
; packer (tools/convert.py) mirrors the least-used tiles while a level is short of room
; in the tile bank.  Off: no level needs it once the tiles start at $8600, and the code
; and tables it takes are that room (TILEMIRROR=1 sh build.sh to build it).
        .ifndef TILEMIRROR
TILEMIRROR = 0
        .endif

.macro PLACEH mseg, bseg              ; the segment by HARDWARE: the interrupt handler's own
  .if ::BHW                             ; work, which is in bank 7 with the Model B's
        .segment bseg                   ; handler and in main RAM with the Master's
  .else
        .segment mseg
  .endif
.endmacro

; ---------------------------------------------------------------- bank numbers
; The four banks are whichever sockets the boot loader finds RAM in (loader.s), on
; either machine.  The code is assembled for banks 4..7 (BANK_SPR, BANK_TILES,
; BANK_MAP, BANK_LVL) and every byte of it that holds a bank number is recorded here,
; with the bank whose image holds the byte, for the loader to patch before the game
; starts (the BANKFIX table, appended to BANKS).  Bank 7's game image comes off the
; disc later and is patched as it comes in (ldprog.s image_load, from its own lists);
; other code that comes off the disc -- the level loader, the menus' image -- is not
; patched: it reads the physical bank from PBANK (low BSS, four bytes indexed by bank
; - 4).
;   bankimm op, n, b   op #n, the operand a bank number: in bank b's image (0 = the
;                      low-RAM image, in the BOOT piece); a fourth argument tells two
;                      alike sites in one routine apart
;   setbank n, b       page bank n in, from code in bank b (A destroyed); likewise
;   ldpbank op, n      op #n from code the loader cannot patch: PBANK's byte instead
;   BANKREF name, b    the byte just emitted is a bank number
; The site is marked with a cheap label, @bf_<name>, because any other kind of symbol
; would end the enclosing routine's @ scope; so two sites in one routine need
; different names (bankimm's is the operation and the bank -- a clash is a duplicate
; symbol at assembly, not a silent miss).
        .import __LOWCODE_LOAD__: absolute, __LOWCODE_RUN__: absolute
.macro BANKREF name, b
        .ident(.concat("@bf_", name)):
        .pushseg
        .segment "BANKFIX"
    .if b = 0                       ; low RAM: its image, in the BOOT piece (main RAM,
        .byte BANK_LVL              ; filed under bank 7 in BANKS)
        .word .ident(.concat("@bf_", name)) - 1 - __LOWCODE_RUN__ + __LOWCODE_LOAD__
    .else
        .byte b
        .word .ident(.concat("@bf_", name)) - 1
    .endif
        .popseg
.endmacro
.macro bankimm op, n, b, tag
    .if .blank(b)
        .error "bankimm: the Model B needs the bank the code is in"
    .endif
        op #n
  .if .blank(tag)
        BANKREF .sprintf("%s_%d", .string(op), n), b
  .else
        BANKREF .sprintf("%s_%d_%d", .string(op), n, tag), b
  .endif
.endmacro
.macro setbank n, b, tag            ; ROMSEL_CPY first: the MOS's own shadow of ROMSEL,
        bankimm lda, n, b, tag      ; which the interrupt restores from
        sta ROMSEL_CPY
        sta ROMSEL
        wrsel n, b, tag             ; (the write bank too, on a board)
.endmacro

; ---------------------------------------------------------------- the write bank
; Solidisk and Watford boards choose the bank a STORE goes to with a register of their
; own -- Solidisk: user VIA port B bits 0-3 ($FE62 = $0F, then $FE60 = bank); Watford:
; a store to $FF30 + bank -- and read through ROMSEL like everyone else.  So every
; switch that a store into sideways RAM may follow carries a companion store, assembled
; as a second `sta ROMSEL` (harmless: A holds the bank) and listed in the WRFIX segment
; for the boot loader to rewrite by board: Watford `sta $FF3n` (n the socket) or, where
; the bank is in X as well, `sta $FF30,x`; Solidisk `sta $FE60`.  A switch that only
; READS the bank it pages (mapbyte, mapstrip's way in) needs none.  On the Master the
; macros are empty.
;   wrsel n, b [, tag]   after a switch to the constant bank n (A = n), in bank b's
;                        image (0 = the low-RAM image, as BANKREF)
;   wrselx b             after a switch to the bank in A AND X
.macro WRREC kind, b, name          ; (the record: the image's bank, the store's address,
  .if ::BHW                        ;  the kind: 4..7 a constant bank, $FE "in X")
        .ident(.concat("@wr_", name)):
        .pushseg
        .segment "WRFIX"
    .if b = 0
        .byte BANK_LVL
        .word .ident(.concat("@wr_", name)) - 3 - __LOWCODE_RUN__ + __LOWCODE_LOAD__
    .else
        .byte b
        .word .ident(.concat("@wr_", name)) - 3
    .endif
        .byte kind
        .popseg
  .endif
.endmacro
.macro wrsel n, b, tag
  .if ::BHW
        sta ROMSEL
    .if .blank(tag)
        WRREC n, b, .sprintf("s_%d", n)
    .else
        WRREC n, b, .sprintf("s_%d_%d", n, tag)
    .endif
  .endif
.endmacro
.macro wrselx b
  .if ::BHW
        sta ROMSEL
        WRREC $FE, b, "x"
  .endif
.endmacro
.macro SAMEPAGE from, to            ; after a hot branch: it and its target in one page
        .assert >(from) = >(to), warning, "a hot branch crosses a page (+1 cycle when taken)"
.endmacro                           ; (checked at link time; a PAD before it fixes it)
.macro PAD b, m                     ; bytes of padding, the Model B's and the Master's, to
  .if ::BHW                        ; move the code after it off a page boundary (the code
        .res b                      ; differs in length, so the pads do; the data after
  .else                             ; lies alike whatever they are: pinned)
        .res m
  .endif
.endmacro
.macro ldpbank op, n
        op PBANK + (n - 4)
.endmacro

  .if .not ::BHW
        .setcpu "65C02"
.macro jmpx tab
        jmp (tab,x)
.endmacro
.macro ldaz zp
        lda (zp)
.endmacro
.macro ldazy zp
        lda (zp)
.endmacro
.macro staz zp
        sta (zp)
.endmacro
.macro andz zp
        and (zp)
.endmacro
.macro cmpz zp
        cmp (zp)
.endmacro
.macro stza arg, ix                 ; on a 65C02 stz never touches A
.if .paramcount = 2
        stz arg,ix
.else
        stz arg
.endif
.endmacro
.macro inca
        inc a
.endmacro
.macro deca
        dec a
.endmacro
.macro bitimm v
        bit #v
.endmacro

  .else                             ; ---------------------------------- 6502
        .setcpu "6502"
.macro stz arg, ix                  ; A dead at the site (audited)
        lda #0
.if .paramcount = 2
        sta arg,ix
.else
        sta arg
.endif
.endmacro
.macro stza arg, ix                 ; A live across the store
        pha
        lda #0
.if .paramcount = 2
        sta arg,ix
.else
        sta arg
.endif
        pla
.endmacro
.macro inca                         ; the carry survives, as inc a's does
        sta mtmp
        inc mtmp
        lda mtmp
.endmacro
.macro deca
        sta mtmp
        dec mtmp
        lda mtmp
.endmacro
.macro phx
        txa
        pha
.endmacro
.macro plx
        pla
        tax
.endmacro
.macro phy
        tya
        pha
.endmacro
.macro ply
        pla
        tay
.endmacro
.macro jmpx tab                     ; jmp (abs,x): through a zero page vector
        pha
        lda tab,x
        sta jv
        lda tab+1,x
        sta jv+1
        pla
        jmp (jv)
.endmacro
.macro ldaz zp                      ; (zp) with no index: Y is free at the site
        ldy #0
        lda (zp),y
.endmacro
.macro ldazy zp                     ; and the form for the site where it is not
        sty mtmp
        ldy #0
        lda (zp),y
        ldy mtmp
        ora #0                      ; N,Z from A, as the load left them
.endmacro
.macro staz zp
        ldy #0
        sta (zp),y
.endmacro
.macro andz zp
        ldy #0
        and (zp),y
.endmacro
.macro cmpz zp
        ldy #0
        cmp (zp),y
.endmacro
.macro bitimm v                     ; Z = (A & v) = 0, A kept
        sta mtmp
        and #v
        php
        lda mtmp
        plp
.endmacro
  .endif

