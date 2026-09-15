; ============================================================================
; The Master is a 65C02; the Model B (MODELB) is a 6502.  Every 65C02 spelling the
; engine and the logic use goes through a macro here, so one source assembles for
; both.  The 6502 expansions have side effects the 65C02 forms do not, and every
; site has been audited for them with tools/flagscan.py -- the contracts:
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
        .ifndef MODELB
MODELB = 0
        .endif

; XJSR name, idx: a call that stays in main RAM on the Master and crosses a bank on
; the Model B (idx names the far-table entry).
.macro XJSR name, idx
  .if MODELB
        farjsr idx
  .else
        jsr name
  .endif
.endmacro

; PLACE a, b: the segment a routine goes in -- a on the Master, b on the Model B,
; whose code is split across four sideways banks by the data it reads.
.macro PLACE mseg, bseg
  .if MODELB
        .segment bseg
  .else
        .segment mseg
  .endif
.endmacro

  .if .not MODELB
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
.macro stz arg, ix                  ; A dead at the site (flagscan)
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
.macro bra arg
        jmp arg
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

; A far call: X = the index of a (bank, address-1) entry in FARTAB, which every
; bank carries a copy of at the same address.  A goes in and comes back; Y is
; untouched; X is destroyed.  farcall itself is in main RAM (modelb/src/low.s).
.macro farjsr idx
        ldx #idx
        jsr farcall
.endmacro
  .endif
