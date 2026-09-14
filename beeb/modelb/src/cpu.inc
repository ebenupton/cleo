; ============================================================================
; The Model B is a plain 6502: the 65C02 instructions the engine is written in
; become macros here.  Same spellings as the Master build so the sources stay
; comparable -- stza is the form that keeps A, stz the one that may clobber it.
; ============================================================================
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
.macro jmpx tab                     ; jmp (abs,x): through a zero page vector
        pha
        lda tab,x
        sta jv
        lda tab+1,x
        sta jv+1
        pla
        jmp (jv)
.endmacro
.macro ldaz zp                      ; (zp) with no index: Y is free at every site
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

; ---------------------------------------------------------------- banking
ROMSEL    = $FE30
ROMSEL_CPY = $F4                    ; the OS's copy: an interrupt that pages a ROM in
                                    ; restores from here, so both are always written
BANK_SPR  = 4                       ; sprite images + the sprite blitter
BANK_TIL  = 5                       ; this level's tiles + the tile blitter
BANK_MAP  = 6                       ; the map, objects, attributes
BANK_LGC  = 7                       ; the game logic and the frame loop

.macro setbank n                    ; A is clobbered
        lda #n
        sta ROMSEL_CPY
        sta ROMSEL
.endmacro

; A far call: X = the index of a (bank, address) entry in FARTAB.  farcall itself is
; in main RAM, which is why a bank may call one that replaces it.
.macro farjsr idx
        ldx #idx
        jsr farcall
.endmacro
