; discprobe -- boots on any BBC, detects the floppy controller, reads sectors
; through src/disc.s and leaves the result where a harness can see it:
;   $0400 = controller (1 = 1770, 2 = 8271)
;   $0401 = $A5 once the read has finished
;   $2000.. = the sectors read
        .setcpu "6502"
ptr     = $70
        .segment "PROBE"
        jmp probe_start
        .include "disc.s"
        .segment "PROBE"
probe_start:
        sei
        jsr d_detect
        lda d_type
        sta $0400
        lda #0
        sta $0401
        jsr d_init
        cli                         ; the NMI moves the data
        lda #2                      ; sector 2: the first file area
        sta d_sec
        lda #0
        sta d_sec+1
        lda #20                     ; two tracks' worth
        sta d_n
        lda #0
        sta ptr
        lda #$20
        sta ptr+1
        jsr d_read
        lda #$A5
        sta $0401
probe_stop:
        jmp probe_stop
