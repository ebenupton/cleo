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
OSFIND  = $FFCE
OSGBPB  = $FFD1
OSBYTE  = $FFF4
OSWRCH  = $FFEE
ROMSEL  = $FE30
ROMSELC = $F4
BUF     = $2000
zsrc    = $70
zdst    = $72

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
        ; ---- the bank pieces: BANKS is a count, then (bank, address, length) x count,
        ; then the pieces in that order
        lda #$40                    ; open for input
        ldx #<fname
        ldy #>fname
        jsr OSFIND
        sta gbpb2                   ; the handle
        lda #1
        sta gbpb2+5                 ; one byte: the count
        lda #<BUF
        sta gbpb2+1
        lda #>BUF
        sta gbpb2+2
        jsr rd
        lda BUF
        sta npieces
        asl                         ; * 5
        asl
        adc npieces
        sta gbpb2+5
        lda #<ptab
        sta gbpb2+1
        lda #>ptab
        sta gbpb2+2
        jsr rd
        ldx #0
@piece: stx idx
        txa
        asl
        asl
        adc idx                     ; * 5
        tay
        lda ptab+3,y
        sta gbpb2+5
        lda ptab+4,y
        sta gbpb2+6
        lda #<BUF
        sta gbpb2+1
        lda #>BUF
        sta gbpb2+2
        lda ptab,y
        sta pbank
        lda ptab+1,y
        sta zdst
        lda ptab+2,y
        sta zdst+1
        jsr rd
        lda #<BUF
        sta zsrc
        lda #>BUF
        sta zsrc+1
        ldy idx                     ; the length again, for the copy
        lda idx
        asl
        asl
        adc idx
        tay
        lda ptab+3,y
        sta plen
        lda ptab+4,y
        sta plen+1
        sei                         ; the copy: an interrupt that pages a ROM in
        lda pbank                   ; restores from $F4, and would otherwise take ours out
        sta ROMSELC
        sta ROMSEL
        ldy #0
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
        ldx idx
        inx
        cpx npieces
        beq :+
        jmp @piece
:
        lda #0                      ; close it
        ldy gbpb2
        jsr OSFIND
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
        lda #22                     ; MODE 1: the OS sets the ULA and the screen size
        jsr OSWRCH                  ; latch; the game reprograms only the CRTC
        lda #1
        jsr OSWRCH
        sei
        lda #7
        sta ROMSELC
        sta ROMSEL
        jmp BANKCODE                ; bank 7's entry vector

rd:     lda #4                      ; OSGBPB 4: read bytes from the file's pointer
        ldx #<gbpb2
        ldy #>gbpb2
        jmp OSGBPB

idx:      .byte 0
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
gbpb2:    .byte 0                   ; handle
          .word 0, $FFFF            ; data address
          .word 0, 0                ; bytes
          .word 0, 0                ; pointer (unused for call 4)
ptab:     .res 5*16                 ; the piece table
