.macro MLINE mirror                 ; masked store of line Y
  .if mirror
        lda (ptr),y
        tax
        lda SWAPTAB,x
        sta sp_ext                  ; dead during the blit
        lda (sp),y
        and sp_msk
        ora sp_ext
  .else
        lda (sp),y
        and sp_msk
        ora (ptr),y
  .endif
        sta (sp),y
.endmacro
.macro CLINE mirror                 ; plain store of line Y
        lda (ptr),y
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta (sp),y
.endmacro
.macro MPAIR k, mirror              ; lines k, k+1 of the cell
        .local opq, done
        ldy #k/2
        lda (mptr),y
        tay
        lda (mtab),y
        beq opq                     ; $00: both pixels opaque, plain stores
        cmp #$FF
        beq done                    ; both transparent
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta sp_msk
        ldy #k
        MLINE mirror
        iny
        MLINE mirror
        bra done
opq:    ldy #k
        CLINE mirror
        iny
        CLINE mirror
done:
.endmacro
.macro SPRMSK name, mirror
        .local partial, np, et, p0, p1, p2, p3, pl, pop, pnext
name:
        lda tmp2
        cmp #7
        bne np
        lda tmp                     ; even: 0,2,4,6 -> entry p0..p3
        beq p0
        tax
        jmpx et
np:     jmp partial
et:     .word p0, p1, p2, p3
p0:     MPAIR 0, mirror
p1:     MPAIR 2, mirror
p2:     MPAIR 4, mirror
p3:     MPAIR 6, mirror
  .if mirror
        jmp sprretMk
  .else
        jmp sprretPk
  .endif
partial:                            ; lines tmp..tmp2: tmp even, tmp2 odd
        lda tmp
        sta sp_lim
pl:     lda sp_lim
        lsr
        tay
        lda (mptr),y
        tay
        lda (mtab),y
        beq pop
        cmp #$FF
        beq pnext
  .if mirror
        tax
        lda SWAPTAB,x
  .endif
        sta sp_msk
        ldy sp_lim
        MLINE mirror
        iny
        MLINE mirror
        bra pnext
pop:    ldy sp_lim
        CLINE mirror
        iny
        CLINE mirror
pnext:  lda sp_lim
        inca
        inca
        sta sp_lim
        cmp tmp2
        bcc pl
  .if mirror
        jmp sprretMk
  .else
        jmp sprretPk
  .endif
.endmacro
        SPRMSK sprFN, 0
        SPRMSK sprFM, 1
mask4:  .byte $FF, $CC, $33, $00    ; AND mask by pair (bit 1 = left opaque, bit 0 = right):
                                    ; keep what is NOT opaque -- right only opaque keeps the left dots
