; ============================================================================
; The Model B build is plain 6502, so the handful of 65C02 instructions the code
; uses become macros.  Define MODELB on the ca65 command line to get them.
;
;   stz   two bytes longer and it clobbers A.  Most uses are in initialisation
;         where A is dead; the ones where it is not say stza instead, which is
;         the safe form.  tools/dfscan.py finds them.
;   bra   one byte longer, same three cycles when taken.
;   inca  / deca, and the stack pushes, are written out per site.
; ============================================================================
.ifdef MODELB
        .setcpu "6502"
.macro stz arg, ix                  ; A dead: the caller has said so by using stz
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
.macro inca
        clc
        adc #1
.endmacro
.macro deca
        sec
        sbc #1
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
; jmp (abs,x), and the non-indexed zero page indirects, have no 6502 equivalent:
; the first goes through a zero-page vector and the others burn Y, which is free
; at every site that uses them.
.macro jmpx tab                     ; A survives: drawrow dispatches with the fill
        pha                         ; value in it
        lda tab,x
        sta jv
        lda tab+1,x
        sta jv+1
        pla
        jmp (jv)
.endmacro
.macro ldaz zp
        ldy #0
        lda (zp),y
.endmacro
.macro staz zp
        ldy #0
        sta (zp),y
.endmacro
.macro andz zp
        ldy #0
        and (zp),y
.endmacro
.else
        .setcpu "65C02"
.macro jmpx tab
        jmp (tab,x)
.endmacro
.macro ldaz zp
        lda (zp)
.endmacro
.macro staz zp
        sta (zp)
.endmacro
.macro andz zp
        and (zp)
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
.endif
