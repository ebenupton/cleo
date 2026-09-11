; ============================================================================
; reloc.s -- Model B only.
;
; The game wants main RAM from $0E00 up to the screen at $3000, but on a Model B
; that is the filing system's own workspace: PAGE is $1F00 with DFS and ADFS
; fitted, $1900 with DFS alone.  Loading the file straight to $0E00 pulls the
; workspace out from under the DFS while it is still reading, and it hangs.
;
; So the file loads at $2000 instead and moves itself down.  This stub is the
; head of it; the block it writes covers its own address, so the mover goes to
; the cassette buffer at $0A00 -- below $0E00, and so out of the way -- first.
; ============================================================================
MOVER   = $0A00
RELOAD  = $2000                     ; must match the load address mkdfs is given
mv_s    = $70                       ; the MOS's zero page is ours from here on
mv_d    = $72

        .import __MAIN_START__, __MAIN_LAST__
        .import __LOW_START__, __LOW_LAST__
        .import __LOW2_START__, __LOW2_LAST__

        .segment "RELOC"
IMGLEN  = (__MAIN_LAST__ - __MAIN_START__) + (__LOW_LAST__ - __LOW_START__) + (__LOW2_LAST__ - __LOW2_START__)

reloc:  sei                         ; nothing of the MOS's may run once its filing
        ldx #(mover_end - mover)    ; system workspace has gone
:       lda mover_img-1,x
        sta MOVER-1,x
        dex
        bne :-
        jmp MOVER
mover_img:
        .org MOVER
mover:  lda #<(RELOAD + RELOCSZ)    ; forward, because the destination is below the
        sta mv_s                    ; source and so is always read before it is written
        lda #>(RELOAD + RELOCSZ)
        sta mv_s+1
        lda #<__MAIN_START__
        sta mv_d
        lda #>__MAIN_START__
        sta mv_d+1
        ldy #0
        ldx #>IMGLEN
        inx                         ; whole pages, and one more for the tail
@pg:    lda (mv_s),y
        sta (mv_d),y
        iny
        bne @pg
        inc mv_s+1
        inc mv_d+1
        dex
        bne @pg
        jmp __MAIN_START__          ; the first thing there is the jmp to start
mover_end:
        .reloc
RELOCSZ = (mover_img - reloc) + (mover_end - mover)
