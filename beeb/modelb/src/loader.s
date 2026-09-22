; ============================================================================
; LOADER -- runs at $1900 from !BOOT under the MOS: the fixed pieces of the four
; sideways banks from BANKS (DFS will not load into a sideways bank, so each piece
; is read to $2000 and copied), which drive and which disc controller the game's
; own driver is to use, then the game.  Everything else -- the menu overlay, the
; title pack, every level -- the game loads itself (disc.s, ldprog.s).
; ============================================================================
        .setcpu "6502"
        .include "defs_ld.inc"      ; BANKCODE, dsk_type, dsk_drv (build.sh)
OSFILE  = $FFDD
OSGBPB  = $FFD1
OSBYTE  = $FFF4
OSWRCH  = $FFEE
ROMSEL  = $FE30
ROMSELC = $F4
BUF     = $2000
zsrc    = $70
zdst    = $72
ztab    = $74

        .segment "CODE"
start:
        lda ROMSELC
        sta oldbank
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
@rom:   lda $02A1,x                 ; the MOS's ROM type table: service ROMs only
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
        jsr OSWRCH
        ; ---- the pieces: BANKS is a count, then (bank, address, length) x count, then
        ; the pieces in that order; bank 0 means main RAM (no paging).  The whole file
        ; is loaded at once (OSFILE: a byte at a time through OSGBPB took the 1770 DFS
        ; twenty seconds) into what is now screen memory, and the pieces copied out.
        lda #$FF                    ; OSFILE 255: load, address from the block
        ldx #<block
        ldy #>block
        jsr OSFILE
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
        sei                         ; the copy: an interrupt that pages a ROM in
        lda pbank                   ; restores from $F4, and would otherwise take ours out
        beq :+                      ; (main RAM: no paging)
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
        lda oldbank
        sta ROMSELC
        sta ROMSEL
        cli
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
        ; ---- the driver's configuration, into bank 7
        sei
        lda #7
        sta ROMSELC
        sta ROMSEL
        lda fdc
        sta dsk_type
        lda drive
        sta dsk_drv
        lda oldbank
        sta ROMSELC
        sta ROMSEL
        cli
        sei
        lda #7
        sta ROMSELC
        sta ROMSEL
        jmp BANKCODE                ; bank 7's entry vector

oldbank:  .byte 0
npieces:  .byte 0
pbank:    .byte 0
plen:     .word 0
fdc:      .byte 0
drive:    .byte 0
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
