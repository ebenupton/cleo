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
        tax                         ; (X is reloaded below)
        wrselx 0
        tsx
        lda $0106,x                 ; A as it came in
        rts
fcret:  sta fcA                     ; the target's A (Y must survive, X carries the bank)
        pla                         ; the caller's bank
        tax
        stx ROMSEL_CPY
        stx ROMSEL
        wrselx 0
        pla                         ; (the A that went in)
        lda fcA
        rts

; ---------------------------------------------------------------- interrupts
; The chain step and the vsync work are in bank 7 with their tables: this pages it
; in around them.  The step's timing (VS2T_DEFAULT) allows for the ~30 cycles that
; takes, in place of the hold loop the Master's handler has.  The title tune's
; player is in the menu overlay (bank 5): the vsync work leaves MUSON set only
; while the overlay is there, and it is stepped from here, between the banks, once
; a frame -- the vsync's sound_tick raises MUSTICK; the T1 steps are this same stub.
irq_handler:
        stx irq_x
        sty irq_y
        lda ROMSEL_CPY
        pha
        jsr pagelogic               ; bank 7, write bank too (VS2T_DEFAULT allows for it)
        jsr isr_body
        lda MUSTICK                 ; the vsync's sound_tick, while the tune plays; the
        beq @nomus                  ; T1 steps come through here too and must not count
        lda #0
        sta MUSTICK
        bankimm lda, BANK_TILES, 0
        sta ROMSEL_CPY
        sta ROMSEL
        jsr music_tick              ; (sets its own write bank: it is disc-loaded code)
@nomus: pla
        sta ROMSEL_CPY
        sta ROMSEL
        tax                         ; the interrupted code may store next
        wrselx 0
        ldy irq_y
        ldx irq_x
        lda $FC
        rti

; ---------------------------------------------------------------- the tile blitter's map
; drawrect's row loop runs in bank 5 and reads the map in bank 6: the row pointer is arithmetic
; (a map is 32, 64, 128 or 256 tiles wide: row * 2^lw is row * 256 shifted right by
; mapshr = 8 - lw, which the loader sets from the header) and the strip copy is the
; one bank switch a tile row costs.
maprow5:                            ; A = tile row -> ptr = LV_MAP + row * (1 << lw) + rc_tx0
        jsr maprow                  ; (X kept; the logic's mapptr is its scratch)
        lda mapptr
        clc
        adc rc_tx0
        sta ptr
        lda mapptr+1
        adc #0
        sta ptr+1
        rts

mapstrip:                           ; (ptr), 0..rc_nt -> MAPBUF; bank 5 back (the row
        bankimm lda, BANK_MAP, 0    ; loop's: dirfetch, the other caller, restores its own)
        sta ROMSEL_CPY
        sta ROMSEL
        ldy rc_nt
:       lda (ptr),y
        sta MAPBUF,y
        dey
        bpl :-
        bankimm lda, BANK_TILES, 0  ; (the write bank: drawrect sets it after the call;
        sta ROMSEL_CPY              ;  dirfetch goes on to pagelogic)
        sta ROMSEL
        rts

; the sprite directory (and the title pack's) is in bank 6 and the prologue in bank
; 7: an entry's eight bytes come across here, and ptr is left pointing at the copy.
; (mapstrip's loop, with its count: rc_nt is drawrect's, which is not running.)
dirfetch:                           ; ptr -> the entry in bank 6
        lda #7
        sta rc_nt
        jsr mapstrip
        lda #<MAPBUF
        sta ptr
        lda #>MAPBUF
        sta ptr+1
        jmp pagelogic               ; bank 7 back (mapstrip left bank 5)

; ---------------------------------------------------------------- the direct switch
; The two crossings that happen once a sprite and once an erased rect skip the far
; table: page the bank, call its entry vector -- BANKENTRY, the same address in
; banks 4, 5 and 6: the sprite row loop in 4 and 6, drawrect_clip in 5 -- and page
; bank 7 back (pagelogic).  ~30 cycles against the thunk's ~90.
callbank:                           ; A = the bank (the write bank is set by the
        sta ROMSEL_CPY              ; entry itself: ds_entry, drawrect_clip -- A still
        sta ROMSEL                  ; holds the bank there)
        jsr BANKENTRY
        jmp pagelogic

        .segment "LOWBSS"
MAPBUF:   .res 21                   ; a tile row of the rectangle: 21 tiles at most
; the mirror's bookkeeping (display.s): the blitters in bank 5 note what they wrote
; to the ring's last slot row, the copy in bank 7 reads it
mirdty:   .res 2                    ; per buffer: the row has been written since the copy
mirlo:    .res 2                    ; and which chars of it (in slot chars, 0..79)
mirhi:    .res 2
mirwcx:   .res 2                    ; the wcxm the copy was made for
; the level's shape, set by the loader: read from banks 5 and 7
sprtab:   .res 2                    ; the sprite directory: bank 6, just above the map
mapshr:   .res 1                    ; 8 - lw (maprow, maprow5)
MAPSTRIDE: .res 2                   ; bytes per map row (1 << lw): drawrect's row step
MUSON:    .res 1                    ; the tune plays: the interrupt stub steps it
MUSTICK:  .res 1                    ; a frame's step is due: the vsync's sound_tick says so
title_res: .res 1                   ; the menu overlay and the title pack are in banks 5
                                    ; and 6 (a level load replaces both; menu.s reads it)
