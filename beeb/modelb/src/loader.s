; ============================================================================
; LOADER -- runs at $1900 from !BOOT under the MOS.  First the sideways RAM: the
; game wants four 16K banks it can write through ROMSEL and takes them from whatever
; sockets they are in (findram), then patches every bank number in the code it is
; about to put there -- the code is assembled for banks 4..7, and the BANKFIX table
; at the end of BANKS lists every byte that holds one (cpu.inc BANKREF).  Then the
; fixed pieces of the four banks from BANKS (DFS will not load into a sideways bank,
; so the file is read to $2000 and the pieces copied), which drive and which disc
; controller the game's own driver is to use, and the game.  Everything else -- the
; menu overlay, the title pack, every level -- the game loads itself (disc.s,
; ldprog.s), reading the physical banks from PBANK, which start7 fills from the
; four bytes this leaves in bank 7 (dsk_banks).
; ============================================================================
        .setcpu "6502"
        .include "defs_ld.inc"      ; BANKCODE, dsk_type, dsk_drv, dsk_banks (build.sh)
OSFILE  = $FFDD
OSGBPB  = $FFD1
OSBYTE  = $FFF4
OSWRCH  = $FFEE
ROMSEL  = $FE30
ROMSELC = $F4
ROMTYPE = $02A1                     ; the MOS's ROM table: the type byte of every ROM
                                    ; it recognised at BREAK, 0 for the other sockets
BUF     = $2000
zsrc    = $70
zdst    = $72
ztab    = $74
ztmp    = $76

        .segment "CODE"
start:
        lda ROMSELC
        sta oldbank
        jsr findram                 ; the four banks, into map -- or fewer, and C set
        bcc :+
        jmp noram                   ; say so and go back to the MOS
:
        ; ---- the drive: whichever DFS has current (OSGBPB 6: its name is the digit)
        lda #6
        ldx #<gbpb
        ldy #>gbpb
        jsr OSGBPB
        ldx drvname
        lda drvname,x
        and #1
        sta drive
        ; ---- the controller: the DFS ROM's version string.  Acorn's 8271 DFSs are
        ; 0.90 and 1.20 (whose title is "DFS,NET" with no version at all); the 1770
        ; DFSs are 2.xx.  Hold W or I at boot to say so instead.
        lda #0
        sta fdc
        lda #$81
        ldx #$DE                    ; W (negative INKEY code)
        ldy #$FF
        jsr OSBYTE
        cpx #$FF
        bne :+
        lda #1
        sta fdc
        bne @fdcdone
:       lda #$81
        ldx #$DA                    ; I
        ldy #$FF
        jsr OSBYTE
        cpx #$FF
        beq @fdcdone                ; 8271, as set
        ldx #15
@rom:   lda ROMTYPE,x               ; the MOS's ROM type table: service ROMs only
        and #$80
        beq @nextrom
        stx ROMSELC
        stx ROMSEL
        ldy #0
:       lda $8009,y                 ; the title
        beq :+
        iny
        bne :-
:       lda $8009,y                 ; the version follows its terminator
        lda $800A,y
        cmp #'2'
        bne @nextrom
        lda $8009                   ; only a DFS: the title starts "DFS" (Acorn's)
        cmp #'D'
        bne @nextrom
        lda $800A
        cmp #'F'
        bne @nextrom
        lda #1
        sta fdc
        ldx #0
@nextrom:
        dex
        bpl @rom
        lda oldbank
        sta ROMSELC
        sta ROMSEL
@fdcdone:
        lda #22                     ; MODE 1 first: the OS sets the ULA and the screen size
        jsr OSWRCH                  ; latch, the game reprograms only the CRTC -- and the
        lda #1                      ; main-RAM pieces below land in what is now screen
        jsr OSWRCH                  ; memory, so the palette goes black before they do
        ldx #15
:       txa
        asl
        asl
        asl
        asl
        ora #7
        sta $FE21
        dex
        bpl :-
        ; ---- the pieces: BANKS is a count, then (bank, address, length) x count, then
        ; the pieces in that order, then the bank patches; bank 0 means main RAM (no
        ; paging).  The whole file is loaded at once (OSFILE: a byte at a time through
        ; OSGBPB took the 1770 DFS twenty seconds) into what is now screen memory, and
        ; the pieces copied out.  From here on nothing calls the MOS again and the banks
        ; may hold ROMs it knows (findram's last resort), so interrupts stay off: a
        ; stray one would have it offer service calls to a ROM half overwritten.
        lda #$FF                    ; OSFILE 255: load, address from the block
        ldx #<block
        ldy #>block
        jsr OSFILE
        sei
        lda BUF
        sta npieces
        lda #<(BUF+1)               ; the table
        sta ztab
        lda #>(BUF+1)
        sta ztab+1
        lda npieces                 ; the first piece follows the table: BUF + 1 + 5n
        asl
        asl
        adc npieces
        sec                         ; (+1)
        adc #<BUF
        sta zsrc
        lda #>BUF
        adc #0
        sta zsrc+1
@piece: ldy #0
        lda (ztab),y
        sta pbank
        iny
        lda (ztab),y
        sta zdst
        iny
        lda (ztab),y
        sta zdst+1
        iny
        lda (ztab),y
        sta plen
        iny
        lda (ztab),y
        sta plen+1
        lda pbank                   ; the piece's bank is the code's number (4..7):
        beq :+                      ; the socket it goes to is map's (main RAM: no paging)
        tax
        lda map-4,x
        sta ROMSELC
        sta ROMSEL
:       ldy #0
@cp:    lda plen
        ora plen+1
        beq @cpdone
        lda (zsrc),y
        sta (zdst),y
        inc zsrc
        bne :+
        inc zsrc+1
:       inc zdst
        bne :+
        inc zdst+1
:       lda plen
        bne :+
        dec plen+1
:       dec plen
        jmp @cp
@cpdone:
        lda ztab
        clc
        adc #5
        sta ztab
        bcc :+
        inc ztab+1
:       dec npieces
        beq :+
        jmp @piece
:
        ; ---- the bank patches: (bank, address) x n, $FF -- zsrc is on them, the pieces
        ; being done.  The byte is a bank number in its low nibble (bit 7 on one of them
        ; is the Master's ANDY flag, which the Model B never takes: kept as it is).
@fix:   ldy #0
        lda (zsrc),y
        cmp #$FF
        beq @fixdone
        tax
        lda map-4,x
        sta ROMSELC
        sta ROMSEL
        iny
        lda (zsrc),y
        sta zdst
        iny
        lda (zsrc),y
        sta zdst+1
        ldy #0
        lda (zdst),y
        pha
        and #$0F
        tax
        lda map-4,x
        sta ztmp
        pla
        and #$F0
        ora ztmp
        sta (zdst),y
        lda zsrc
        clc
        adc #3
        sta zsrc
        bcc @fix
        inc zsrc+1
        jmp @fix
@fixdone:
        ; ---- the driver's configuration and the banks themselves, into bank 7
        lda map+3
        sta ROMSELC
        sta ROMSEL
        lda fdc
        sta dsk_type
        lda drive
        sta dsk_drv
        ldx #3
:       lda map,x
        sta dsk_banks,x
        dex
        bpl :-
        jmp BANKCODE                ; bank 7's entry vector (bank 7 is paged)

; ---------------------------------------------------------------- the sideways RAM
; Which sockets hold RAM, and which four the game gets.  The test is the one Stuart
; McConnachie's sideways RAM Elite loader used (1988; Mark Moxon's commentary): page
; the bank through $F4 and ROMSEL, flip bit 0 of the ROM type byte at $8006 and see
; whether it stuck, put it back.  A floating bus fails it (both reads see the same
; value), a write-protected board fails it too -- it looks like ROM, and the message
; says so.  Every bank then gets a class: 0, RAM with no ROM image in it; 1, RAM with
; an image the MOS is not running (no entry in its table at $02A1: left there by an
; earlier load); 2, RAM holding a ROM the MOS recognised -- taken only when nothing
; else is left, which is safe here because nothing calls the MOS once the pieces go
; down.  Two socket numbers that reach the same RAM (a board answering two numbers)
; are found by a signature written to each and read back -- not Elite's byte-for-byte
; comparison of the banks, which would call four blank banks one -- and the extra
; numbers dropped.  The four are the lowest-numbered of the best class.
findram:
        sei
        ldx #15
@b:     stx ROMSELC
        stx ROMSEL
        lda #$FF                    ; not RAM until proven
        sta score,x
        lda $8006
        tay
        eor #1
        sta $8006
        cmp $8006
        php
        sty $8006
        plp
        bne @bnext
        lda ROMTYPE,x               ; a ROM the MOS is using
        beq :+
        lda #2
        bne @bsc
:       ldy $8007                   ; a ROM image: 0 "(C)" at the copyright offset
        lda $8000,y
        bne @bfree
        iny
        lda $8000,y
        cmp #'('
        bne @bfree
        iny
        lda $8000,y
        cmp #'C'
        bne @bfree
        iny
        lda $8000,y
        cmp #')'
        bne @bfree
        lda #1
        bne @bsc
@bfree: lda #0
@bsc:   sta score,x
@bnext: dex
        bpl @b
        ; the signatures: 15 down, each RAM bank's $8007 saved and its number written
        ldx #15
@sig:   lda score,x
        bmi @snext
        stx ROMSELC
        stx ROMSEL
        lda $8007
        sta saved,x
        txa
        ora #$C0
        sta $8007
@snext: dex
        bpl @sig
        ldx #15
@chk:   lda score,x
        bmi @cnext
        stx ROMSELC
        stx ROMSEL
        txa
        ora #$C0
        cmp $8007
        beq @cnext
        lda #$FE                    ; another number reached this RAM after us and
        sta score,x                 ; keeps it (still to be restored: not $FF)
@cnext: dex
        bpl @chk
        ldx #0                      ; restored in the reverse order of the saving, so
@res:   lda score,x                 ; a chain of aliases unwinds to its first byte
        cmp #$FF
        beq @rnext
        stx ROMSELC
        stx ROMSEL
        lda saved,x
        sta $8007
@rnext: inx
        cpx #16
        bne @res
        lda oldbank
        sta ROMSELC
        sta ROMSEL
        cli
        ; the choice: the lowest sockets of class 0, then of class 1, then of class 2
        ldy #0
        lda #0
        sta want
@cls:   ldx #0
@pick:  lda score,x
        cmp want
        bne @pnext
        txa
        sta map,y
        iny
        cpy #4
        beq @found
@pnext: inx
        cpx #16
        bne @pick
        inc want
        lda want
        cmp #3
        bne @cls
        sec                         ; fewer than four
        rts
@found: clc
        rts

; not enough: say what was found and return to the MOS (MODE 7 still: this runs
; before the mode change)
noram:  ldx #0
:       lda msg1,x
        beq :+
        jsr OSWRCH
        inx
        bne :-
:       ldx #0
@d:     lda score,x                 ; the writable banks, as hex digits
        bmi @dnext
        txa
        cmp #10
        bcc :+
        adc #6                      ; (the carry is set: 10 -> 'A')
:       adc #'0'
        jsr OSWRCH
        lda #' '
        jsr OSWRCH
@dnext: inx
        cpx #16
        bne @d
        ldx #0
:       lda msg2,x
        beq :+
        jsr OSWRCH
        inx
        bne :-
:       rts

oldbank:  .byte 0
npieces:  .byte 0
pbank:    .byte 0
plen:     .word 0
fdc:      .byte 0
drive:    .byte 0
want:     .byte 0
map:      .res 4                    ; the socket of each of banks 4..7
score:    .res 16                   ; per socket: 0..2 as above, $FE an alias, $FF not RAM
saved:    .res 16
fname:    .byte "BANKS", 13
gbpb:     .byte 0                   ; OSGBPB 6: the data address is all it reads
          .word drvname, $FFFF
          .res 8
drvname:  .res 8                    ; <len> "<drive>" <len> <boot option>
block:    .word fname
          .dword $FFFF0000 | BUF    ; load address: the $FFFF names the I/O
                                    ; processor, and DFS wants it even with no tube
          .dword $00000000          ; exec address: 0 here means "use the one above"
          .dword $00000000
          .dword $00000000
msg1:     .byte 13, 10
          .byte "Cleo needs 64K of sideways RAM: four", 13, 10
          .byte "16K banks it can write through &FE30,", 13, 10
          .byte "in any sockets.  Writable banks found:", 13, 10, 0
msg2:     .byte 13, 10, 13, 10
          .byte "Write-protected RAM reads as ROM: turn", 13, 10
          .byte "it off and press SHIFT-BREAK.", 13, 10
          .byte "Boards that choose the bank to write", 13, 10
          .byte "through another register (Solidisk,", 13, 10
          .byte "Watford) are not supported.", 13, 10, 0
