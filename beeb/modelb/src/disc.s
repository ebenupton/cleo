; ============================================================================
; The disc, from the game's side: bank 7.  The MOS is gone, so this is its own
; driver -- for the 8271 the Model B was born with and for the Acorn 1770 board --
; and the loader that gathers a level into the banks runs in main RAM, where it can
; page banks freely (ldprog.s).  Both controllers raise NMI for every byte, so the
; transfer routine sits at NMIPAGE, which is display RAM during a level and free
; while the palette is black.  The boot loader (loader.s) says which controller and
; which drive (dsk_type, dsk_drv) before the game starts.
; ============================================================================
        .include "files.inc"        ; F_LDPROG_SEC/N: where the loader is
        .segment "LGCBSS"
dsk_type: .res 1                    ; 0 = 8271, 1 = 1770 (loader.s decides at boot)
dsk_drv:  .res 1                    ; 0 or 1: the drive DFS had current
dsk_banks: .res 4                   ; the physical bank of each of banks 4..7 (loader.s;
dsk_board: .res 1                   ; start7 copies them to PBANK) and the board (PBOARD)
ld_sec:   .res 2                    ; read_sectors: first sector, count, destination
ld_n:     .res 1
ld_dst:   .res 2
ld_trk:   .res 1
ld_sc:    .res 1
ld_cnt:   .res 1
ld_level: .res 1

; ---------------------------------------------------------------- the NMI page
; Copied to NMIPAGE for a load.  Each stub writes through a self-modified address
; (xxx_sta+1) and keeps its state in the page too, so it is right whatever bank is
; paged in when the NMI lands.
        .segment "NMISTUB"
nmi_page:
        jmp nmi_i                   ; disc_boot points this at the controller's stub
nmi_i:                              ; ---- the 8271: status bit 2 = a byte is ready,
        pha                         ;      otherwise the command has ended
        lda FDC8271_CMD
        and #$04
        beq nmi_i_end
        lda FDC8271_DAT
nmi_i_sta:
        sta $FFFF
        inc nmi_i_sta+1
        bne :+
        inc nmi_i_sta+2
:       pla
        rti
nmi_i_end:
        lda FDC8271_PAR             ; the result (reading it clears the interrupt)
        sta ld_res
        lda #1
        sta ld_done
        pla
        rti
nmi_w:                              ; ---- the 1770: DRQ with busy = a byte, else
        pha                         ;      the command has ended (busy dropped)
        lda FDC1770_CMD
        and #3
        cmp #3
        bne nmi_w_nd
        lda FDC1770_DAT
nmi_w_sta:
        sta $FFFF
        inc nmi_w_sta+1
        bne :+
        inc nmi_w_sta+2
        dec ld_secs                 ; a whole sector done
        bne :+
        lda #$D0                    ; force interrupt: stop the multi-sector read
        sta FDC1770_CMD
        lda #1
        sta ld_done
:       pla
        rti
nmi_w_nd:
        and #1
        bne :+
        lda #1
        sta ld_done
:       pla
        rti
ld_res:   .res 1
ld_done:  .res 1
ld_secs:  .res 1
nmi_end:
        .assert nmi_end - nmi_page <= $100, error, "the NMI stubs do not fit their page"
NMI_W     = NMIPAGE + (nmi_w - nmi_page)       ; the stubs' addresses once copied
NMI_I_STA = NMIPAGE + (nmi_i_sta - nmi_page)
NMI_W_STA = NMIPAGE + (nmi_w_sta - nmi_page)
LD_RES    = NMIPAGE + (ld_res - nmi_page)
LD_DONE   = NMIPAGE + (ld_done - nmi_page)
LD_SECS   = NMIPAGE + (ld_secs - nmi_page)

        .segment "LGCCODE"
; ---------------------------------------------------------------- reading
; ld_sec (16 bit), ld_n sectors -> ld_dst in main RAM.  The disc is 80 tracks of 10
; 256-byte sectors: the division is by repeated subtraction, as the Master's.
read_sectors:
        lda #0
        sta ld_trk
@d10:   lda ld_sec
        sec
        sbc #10
        tay
        lda ld_sec+1
        sbc #0
        bcc @drem
        sty ld_sec
        sta ld_sec+1
        inc ld_trk
        bne @d10
@drem:  lda ld_sec
        sta ld_sc
@track: lda #10                     ; sectors to read on this track: min(n, 10 - s)
        sec
        sbc ld_sc
        cmp ld_n
        bcc :+
        lda ld_n
:       sta ld_cnt
        lda ld_dst                  ; the transfer address, into the stub
        sta NMI_I_STA+1
        sta NMI_W_STA+1
        lda ld_dst+1
        sta NMI_I_STA+2
        sta NMI_W_STA+2
        lda #0
        sta LD_DONE
        lda dsk_type
        bne @wd
        ; ---- 8271: read data, multi-record, 256-byte sectors -- after two commands
        ; DFS also sends.  The drive control output (special register $23): select +
        ; load head is the motor, which the 8271 stops after a few idle index pulses
        ; (DFS's specify), and a read on a stopped drive is "not ready" ($10) at once,
        ; without starting it.  And the 8271 LATCHES not ready: only a read drive
        ; status clears it, so the retry below would fail for ever without one
        ; (it did: the title's idle stops the motor, and the level never loaded).
        jsr i_idle
        lda #$40                    ; bits 7,6 select the drive: $40 = 0, $80 = 1
        ldx dsk_drv
        beq :+
        asl
:       tax                         ; (the helpers keep X)
        ora #$3A                    ; write special register
        sta FDC8271_CMD
        lda #$23
        jsr i_param
        txa
        ora #$08                    ; select + load head
        jsr i_param
        jsr i_idle
        txa
        ora #$2C                    ; read drive status: an immediate command, no
        sta FDC8271_CMD             ; interrupt -- its result (the status) is read to
        jsr i_idle                  ; clear it
        lda FDC8271_PAR
        lda #0                      ; (and the stub's flag, should a controller
        sta LD_DONE                 ; interrupt after all)
        txa
        ora #$13                    ; read data
        sta FDC8271_CMD
        lda ld_trk
        jsr i_param
        lda ld_sc
        jsr i_param
        lda ld_cnt
        ora #$20
        jsr i_param
        jsr wait_done
        lda LD_RES
        and #$1E
        beq @next
        jmp @track                  ; try the run again: not ready, or a soft error
        ; ---- 1770: seek if the head is elsewhere, then read multiple
@wd:    lda ld_trk
        cmp w_trk
        beq @wrd
        sta w_trk
        sta FDC1770_DAT
        lda #$10                    ; seek, no verify
        sta FDC1770_CMD
        jsr w_wait
@wrd:   lda ld_sc
        sta FDC1770_SEC
        lda ld_cnt
        sta LD_SECS
        lda #$94                    ; read multiple with head settle: the stub stops it
        sta FDC1770_CMD
        ldx #20
:       dex
        bne :-
:       lda LD_DONE
        bne :+
        lda FDC1770_CMD             ; fallback: the command ended without a completion NMI
        and #1
        bne :-
:       jsr w_wait                  ; the abort takes a moment to clear busy
@next:  lda ld_dst+1
        clc
        adc ld_cnt
        sta ld_dst+1
        lda ld_n
        sec
        sbc ld_cnt
        sta ld_n
        beq @done
        lda #0
        sta ld_sc
        inc ld_trk
        jmp @track
@done:  rts

        .segment "LGCLO"            ; (the helpers: below the records, where there is room)
i_idle: lda FDC8271_CMD             ; the 8271 takes a command when not busy
        bmi i_idle
        rts
i_param:                            ; and a parameter when the register is free
        pha
:       lda FDC8271_CMD
        and #$20
        bne :-
        pla
        sta FDC8271_PAR
        rts
wait_done:                          ; the stub's completion flag, taken
        lda LD_DONE
        beq wait_done
        lda #0
        sta LD_DONE
        rts
w_wait: ldx #20
:       dex
        bne :-
:       lda FDC1770_CMD
        and #1
        bne :-
        rts
        .segment "LGCBSS"
w_trk:    .res 1                    ; the 1770's head, as far as this driver knows
        .segment "LGCCODE"

; the 1770 board is reset and its head found once, at start-up (start7): the 8271
; keeps DFS's state and needs nothing
disc_init:
        lda dsk_type
        beq @done
        lda #$08                    ; reset held (bit 5 low), FM
        sta FDC1770_CTL
        lda #$28                    ; reset released, FM, the drive
        ldx dsk_drv
        beq :+
        ora #$02
        bne :++
:       ora #$01
:       sta FDC1770_CTL
        lda #$00                    ; restore: track 0
        sta FDC1770_CMD
        jsr w_wait
        lda #0
        sta w_trk
@done:  rts

; ---------------------------------------------------------------- the loader
; The NMI stubs go to their page and the load-time program to LDPROG, then it runs:
; it comes back with bank 7 paged and the display RAM it used as scratch.
        .import __NMISTUB_LOAD__: absolute
disc_boot:
        ldx #(nmi_end - nmi_page - 1)
:       lda __NMISTUB_LOAD__,x      ; the stubs' bytes are in this bank; their labels
        sta NMIPAGE,x               ; are their run addresses (cleo_b.cfg)
        dex
        bpl :-
        lda dsk_type
        beq :+
        lda #<NMI_W                 ; a 1770: the page's jump goes to its stub
        sta NMIPAGE+1
        lda #>NMI_W
        sta NMIPAGE+2
:       lda #<F_LDPROG_SEC
        sta ld_sec
        lda #>F_LDPROG_SEC
        sta ld_sec+1
        lda #F_LDPROG_N
        sta ld_n
        lda #<LDPROG
        sta ld_dst
        lda #>LDPROG
        sta ld_dst+1
        jmp read_sectors

; X = level index 0..15: everything the level needs into the banks (the palette is
; black; the game's load_level goes on from the header afterwards)
load_level_b:
        stx ld_level
        jsr music_stop
        jsr ld_begin
        ldx ld_level
        jsr LDPROG                  ; lv_load
        jmp ld_resume

; the menu overlay into bank 5 and the title pack into bank 6
load_title_b:
        jsr ld_begin
        jsr LDPROG+3                ; title_load
ld_resume:                          ; (interrupts still off)
        lda #LDR7                   ; the frame is the standard one: the vsync re-phase
        sta curR7                   ; keeps it so until the bar step (display.s)
        lda #$42
        sta VIA_IFR                 ; a vsync flag raised meanwhile is stale
        cli
        rts

; the display to a standard frame, then the loader in: wait for a vsync (the handler
; restarts T1 for the bar step), interrupts off, and bank 5's ldstop5 (display.s has
; the story) takes that T1 and makes the bar's frame the standard one
ld_begin:
        lda vsyncs
:       cmp vsyncs
        beq :-
        sei
        farjsr F_LDSTOP
        jmp disc_boot
