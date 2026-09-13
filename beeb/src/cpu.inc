; ============================================================================
; The target is a 65C02.  stza stays as a distinct spelling of stz for the sites
; where A must survive the store -- it costs nothing here and keeps the intent
; visible.
; ============================================================================
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
