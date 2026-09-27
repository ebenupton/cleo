; ============================================================================
; Low RAM, $0140-$02FF, both machines: what has to be visible whatever bank is paged
; in.  The crossings between the banks, the Model B's interrupt stub (its body is in
; bank 7: engine.s isr_body) and the tile blitter's map row; engine.s's maprow, mapbyte,
; mapput and pagelogic land here too, and its LOWBSS (the buffers' state, the sprite
; list).  boot copies the code down from the BOOT piece.
; ============================================================================
        .segment "LOWCODE"

; ---------------------------------------------------------------- the crossings
; A bank cannot page another over itself, so every crossing is here: fixed thunks for
; what bank 7 calls in the others (callbank, selbb, validate, dirfetch), for the tile
; blitter's gather (mapstrip), and one routine for the menus (xcall).  No table, no
; dispatch in any bank.  ROMSEL_CPY is written before ROMSEL every time, so
; an interrupt in between puts back the bank being entered: the handler restores from
; $F4, which is the MOS's own rule.

; xcall: the menus' crossing -- their overlay (bank 6) calls a few routines in bank 7,
; and the game loop its four entries.  X = the bank, ctgt = the address; A goes in
; and comes back, Y is untouched, X is destroyed.  The caller's bank waits on the stack,
; so it nests (the game loop calls a menu, which calls bank 7's div10_16).  Not hot: a
; handful a menu frame.  (A crosses in fcA: nothing runs between its store and its load
; but this.)
xcall:  sta fcA
        lda ROMSEL_CPY
        pha
        txa                         ; (A = the bank: wrselx's store, on a board, is A)
        sta ROMSEL_CPY
        sta ROMSEL
        wrselx 0
        lda fcA
        jsr xcgo
xcback: sta fcA                     ; (a label of its own: the write-bank record's marker
        pla                         ;  is a cheap label, one per scope)
        tax
        stx ROMSEL_CPY
        stx ROMSEL
        wrselx 0
        lda fcA
        rts
xcgo:   jmp (ctgt)

; ---------------------------------------------------------------- interrupts
; The Model B's: the chain step and the vsync work are in bank 7 with their tables,
; and this pages it in around them.  The step's timing (VS2T) allows for the ~30 cycles that
; takes, in place of the hold loop the Master's handler has.  The title tune's
; player is in the menu overlay (bank 6): the vsync work leaves MUSON set only
; while the overlay is there, and it is stepped from here, between the banks, once
; a frame -- the vsync's sound_tick raises MUSTICK; the T1 steps are this same stub.
  .if BHW                           ; (the Master's handler is in main RAM with its
irq_handler:                        ;  chain: engine.s)
        stx irq_x
        sty irq_y
        lda ROMSEL_CPY
        pha
        jsr pagelogic               ; bank 7, write bank too (VS2T allows for it)
        jsr isr_body
        lda MUSTICK                 ; the vsync's sound_tick, while the tune plays; the
        beq @nomus                  ; T1 steps come through here too and must not count
        dec MUSTICK                 ; (1 -> 0: MUSON's value, which is 0 or 1)
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
  .endif

; ---------------------------------------------------------------- the tile blitter's map
; drawrect's row loop runs in bank 6 and reads the map in bank 5: the row pointer is arithmetic
; (a map is 32, 64, 128 or 256 tiles wide: row * 2^lw is row * 256 shifted right by
; mapshr = 8 - lw, which the loader sets from the header) and the strip copy is the
; one bank switch a tile row costs.
maprow6:                            ; A = tile row -> ptr = LV_MAP + row * (1 << lw) + rc_tx0
        jsr maprow                  ; (X kept; the logic's mapptr is its scratch) A = mapptr+1, C = 0
        sta ptr+1                   ; tx0 < the map's width: no carry out of the low byte
        lda mapptr
        adc rc_tx0
        sta ptr
        rts

mapstrip:                           ; (ptr) = the row's first tile: its gather, run in
        bankimm lda, BANK_MAP, 0    ; bank 5 beside the map (engine.s gather5), into
        sta ROMSEL_CPY              ; GATHERL/GATHERH here; bank 6 back (the write bank:
        sta ROMSEL                  ; drawrect sets it after the call)
        jsr gather5
page6:  bankimm lda, BANK_TILES, 0  ; (selbb and validate: page6 first, then the write
        sta ROMSEL_CPY              ; bank for what they store in bank 6)
        sta ROMSEL
        rts

; bank 7's two calls a frame into bank 6 that are not the blitter's entry:
; select_backbuf (it patches ringaddr's operand) and scroll_validate (it draws the
; new strips with drawrect itself)
selbb:  jsr page6
        wrsel BANK_TILES, 0
        jsr select_backbuf
        jmp pagelogic
validate:
        jsr page6
        wrsel BANK_TILES, 0
        jsr scroll_validate
        jmp pagelogic

; the title pack's directory is in bank 5 and the prologue in bank 7: an entry's
; eight bytes come across here (bank 5's fetch8), and ptr is left pointing at the copy
dirfetch:                           ; ptr -> the entry in bank 5
        bankimm lda, BANK_MAP, 0
        sta ROMSEL_CPY
        sta ROMSEL
        jsr fetch8
        jmp pagelogic               ; bank 7 back

; ---------------------------------------------------------------- the direct switch
; Once a sprite and once a rect: page the bank, call its entry -- BANKENTRY, the start
; of banks 4, 5 and 6: the sprite row loop in 4 and 5, bank6_entry + drawrect_clip in 6
; (each sets its own write bank) -- and page bank 7 back (pagelogic).
callbank:                           ; A = the bank (the write bank is set by the
        sta ROMSEL_CPY              ; entry itself: ds_entry, drawrect_clip -- A still
        sta ROMSEL                  ; holds the bank there)
        jsr BANKENTRY
        jmp pagelogic

        .segment "LOWBSS"
ctgt:     .res 2                    ; xcall's target
GATHERH:  .res 21                   ; a tile row's gather (gather5): 21 tiles at most --
MAPBUF = GATHERH                    ; and dirfetch's eight bytes, drawsprite's, when no
                                    ; rect is being drawn
        .segment "LOWBSS2"          ; the rest of low RAM, above the code
GATHERL:  .res 21
        .segment "LOWBSS"
; the Model B's mirror bookkeeping (mirror.s): the tile blitter (bank 6), the sprite
; prologue and copy_partial (bank 7) note what they wrote to the ring's last slot row,
; mirror_copy (bank 7) reads it
  .if BHW
        .segment "LOWHW"            ; (after the shared)
mirdty:   .res 2                    ; per buffer: the row has been written since the copy
mirlo:    .res 2                    ; and which chars of it (in slot chars, 0..79)
mirhi:    .res 2
mirwcx:   .res 2                    ; the wcxm the copy was made for
        .segment "LOWBSS"
  .endif
; (the level's shape, mapshr and MAPSTRIDE, and the tune's MUSON and MUSTICK are
; zero page's: engine.s)
sprc_ok:  .res 1                    ; the resident sprites (SPRC) are in bank 4, and (the
sprx_ok:  .res 1                    ;  Master) SPRX in HAZEL/ANDY: ldprog.s
title_res: .res 1                   ; the menu overlay (bank 6) and the title pack (bank 5)
                                    ; are in (a level load replaces both; menu.s reads it)
