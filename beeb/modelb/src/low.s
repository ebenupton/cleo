; ============================================================================
; Main RAM, $0140-$02FF: what has to be visible whatever bank is paged in.  The
; far-call thunk, the interrupt stub (the handler itself is in bank 7), the two
; map fetches the tile blitter makes from bank 5, and the sprite list.  The
; Master's own main-RAM map helpers (maprow, mapbyte, mapput, pagelogic) land here
; too, from engine.s: they page bank 6 in and bank 7 back exactly as they do there.
; ============================================================================
        .segment "LOWCODE"

; ---------------------------------------------------------------- far calls
; X = the index of a (bank, address-1) entry in FARTAB, which every bank carries at
; the same address.  A goes in and comes back, Y is untouched, X is destroyed.
; Everything is on the stack -- the caller's bank, the return into fcret, the target
; -- so it nests and a step of the interrupt handler can land anywhere in it: the
; handler reads the bank from $F4 and puts it back, which is the MOS's own rule.
;
;   caller's return
;   A on entry
;   caller's bank          <- fcret pulls this
;   fcret-1                <- the target's rts lands here
;   target-1               <- this rts goes there
farcall:
        pha
        lda ROMSEL_CPY
        pha
        lda #>(fcret-1)
        pha
        lda #<(fcret-1)
        pha
        lda FARTAB+2,x
        pha
        lda FARTAB+1,x
        pha
        lda FARTAB,x
        sta ROMSEL_CPY
        sta ROMSEL
        tsx
        lda $0106,x                 ; A as it came in
        rts
fcret:  tax                         ; the target's A
        pla
        sta ROMSEL_CPY              ; the caller's bank
        sta ROMSEL
        pla                         ; (the A that went in)
        txa
        rts

; ---------------------------------------------------------------- interrupts
; The chain step and the vsync work are in bank 7 with their tables: this pages it
; in around them.  The step's timing (VS2T_DEFAULT) allows for the ~30 cycles that
; takes, in place of the hold loop the Master's handler has.
irq_handler:
        stx irq_x
        sty irq_y
        lda ROMSEL_CPY
        pha
        lda #BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        jsr isr_body
        pla
        sta ROMSEL_CPY
        sta ROMSEL
        ldy irq_y
        ldx irq_x
        lda $FC
        rti

; the start-up's switch from bank 6 to bank 7 (init.s): a bank cannot page itself out
to7:    lda #BANK_LVL
        sta ROMSEL_CPY
        sta ROMSEL
        jmp start7

; ---------------------------------------------------------------- the tile blitter's map
; drawrect runs in bank 5 and reads the map in bank 6: the row pointer is arithmetic
; (MAPSTRIDE is a constant here, so there are no row tables) and the strip copy is
; the one bank switch a tile row costs.
maprow5:                            ; A = tile row -> ptr = LV_MAP + row*MAPSTRIDE + rc_tx0
        .assert MAPLW = 7, error, "maprow5 assumes 128-tile rows"
        lsr                         ; row * 128: the row's low bit is the low byte's top
        sta ptr+1
        lda #0
        ror
        clc
        adc rc_tx0                  ; < 128, so no carry out
        sta ptr
        lda ptr+1
        clc
        adc #>LV_MAP
        sta ptr+1
        rts

mapstrip:                           ; (ptr), 0..rc_nt -> MAPBUF
        lda #BANK_MAP
        sta ROMSEL_CPY
        sta ROMSEL
        ldy rc_nt
:       lda (ptr),y
        sta MAPBUF,y
        dey
        bpl :-
        lda #BANK_TILES
        sta ROMSEL_CPY
        sta ROMSEL
        rts

; the sprite directory is in bank 6 and the prologue in bank 5: an entry's eight
; bytes come across here, and ptr is left pointing at the copy
dirfetch:                           ; ptr -> the entry in SPR_TABLE
        lda #BANK_TIL1
        sta ROMSEL_CPY
        sta ROMSEL
        ldy #7
:       lda (ptr),y
        sta MAPBUF,y
        dey
        bpl :-
        lda #BANK_TILES
        sta ROMSEL_CPY
        sta ROMSEL
        lda #<MAPBUF
        sta ptr
        lda #>MAPBUF
        sta ptr+1
        rts

        .segment "LOWBSS"
MAPBUF:   .res 21                   ; a tile row of the rectangle: 21 tiles at most
; the mirror's bookkeeping (display.s): the blitters in bank 5 note what they wrote
; to the ring's last slot row, the copy in bank 7 reads it
mirdty:   .res 2                    ; per buffer: the row has been written since the copy
mirlo:    .res 2                    ; and which chars of it (in slot chars, 0..79)
mirhi:    .res 2
mirwcx:   .res 2                    ; the wcxm the copy was made for
