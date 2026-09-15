; ============================================================================
; Bank 4: the sprite images, their mask planes, the four MASKTABs and the
; blitter.  Everything the inner loop touches is here, so a sprite is drawn
; without a single bank switch; what crosses is one far call per erased
; rectangle, into the tile blitter.
; ============================================================================
        .segment "SPRCODE"

.macro ringmod                      ; A = a map char row -> its ring slot
        tax
        lda RINGMODTAB,x
.endmacro
.macro ringup                       ; A = sp+1 just advanced: fold sp:A at the ring end
        .local done
        cmp ringehi
        bcc done
        pha                         ; the ring is 23 rows of 640, which is not a whole
        lda sp                      ; number of pages, so the low byte moves too
        sec
        sbc #<RINGBYTES
        sta sp
        pla
        sbc #>RINGBYTES
done:
.endmacro
.macro spnext                       ; the next char to the right, with the ring fold
        .local done
        lda sp
        clc
        adc #8
        sta sp
        bcc done
        lda sp+1
        inca
        ringup
        sta sp+1
done:
.endmacro

; sp = the address of char (w16, A) of the window's ring
ringaddr:
        ringmod
        tax
        lda w16+1
        sta sp+1
        lda w16
        asl
        rol sp+1
        asl
        rol sp+1
        asl
        rol sp+1                    ; sp+1:A = cx*8
        clc
        adc RINGLO,x
        sta sp
        lda sp+1
        adc RINGHI,x
        ringup
        sta sp+1
        rts

sext:   and #$80
        beq :+
        lda #$FF
:       sta tmp3
        rts

; ---------------------------------------------------------------- the pass
; draw every sprite on the list, keeping a record of where each landed so the
; next frame can erase it.
draw_sprites:
        lda curbuf
        beq :+
        lda #>(SPRREC + 10*MAXREC)
        bra :++
:       lda #>SPRREC
:       sta rp+1
        lda curbuf
        beq :+
        lda #<(SPRREC + 10*MAXREC)
        bra :++
:       lda #<SPRREC
:       sta rp
        lda #0
        sta spi
@l:     lda spi
        cmp NSPR
        bcs @done
        cmp #MAXREC
        bcs @done
        asl                         ; entry = SPRLIST + i*5
        asl
        clc
        adc spi
        tay
        lda SPRLIST+1,y
        sta spx
        lda SPRLIST+2,y
        sta spx+1
        lda SPRLIST+3,y
        sta spy
        lda SPRLIST+4,y
        sta spy+1
        lda SPRLIST,y
        ldy #0
        sta (rp),y                  ; the record is id, map position, then the
        lda spx                     ; rectangle drawsprite works out
        iny
        sta (rp),y
        lda spx+1
        iny
        sta (rp),y
        lda spy
        iny
        sta (rp),y
        lda spy+1
        iny
        sta (rp),y
        ldy #0
        lda (rp),y
        jsr drawsprite
        lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       inc spi
        bra @l
@done:  ldx curbuf
        lda spi
        sta RECCNT,x
        lda #0
        sta NSPR                    ; the logic fills the list again next frame
        rts

; ---------------------------------------------------------------- erase
; put the tiles back where this buffer's sprites were two frames ago.  The
; record is in chars; the tile blitter wants tiles, so round outwards.
erase_old:
        ldx curbuf
        lda RECCNT,x
        beq @done
        sta tmp4
        lda curbuf
        beq :+
        lda #>(SPRREC + 10*MAXREC)
        bra :++
:       lda #>SPRREC
:       sta rp+1
        lda curbuf
        beq :+
        lda #<(SPRREC + 10*MAXREC)
        bra :++
:       lda #<SPRREC
:       sta rp
@l:     ldy #5
        lda (rp),y                  ; cx low (the high byte only matters past 255
        lsr                         ; chars, which no window reaches)
        lsr
        sta dt_tx
        ldy #7
        lda (rp),y                  ; cy
        lsr
        sta dt_ty
        ldy #5
        lda (rp),y
        and #3                      ; the columns the rounding down left out
        sta tmp2
        ldy #8
        lda (rp),y                  ; w in chars
        clc
        adc tmp2
        adc #3
        lsr
        lsr
        sta dt_nx
        ldy #7
        lda (rp),y
        and #1
        sta tmp2
        ldy #9
        lda (rp),y                  ; h in rows, bit 7 = it was clipped
        and #$7F
        clc
        adc tmp2
        adc #1
        lsr
        sta dt_ny
        lda dt_nx
        beq @next
        lda dt_ny
        beq @next
        farjsr F_DRAWRECT
@next:  lda rp
        clc
        adc #10
        sta rp
        bcc :+
        inc rp+1
:       dec tmp4
        bne @l
@done:  rts

; ---------------------------------------------------------------- tables
; MASKTABk[x] is the AND mask for the column of phase k in mask byte x: the
; blitter indexes by the whole byte and never shifts.
init_masks:
        lda #0                      ; the bank's variables come up undefined
        sta NSPR
        sta RECCNT
        sta RECCNT+1
        ldx #0
@mt:    txa
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        tay
        lda mask4,y
        sta MASKTAB0,x
        txa
        lsr
        lsr
        lsr
        lsr
        and #3
        tay
        lda mask4,y
        sta MASKTAB1,x
        txa
        lsr
        lsr
        and #3
        tay
        lda mask4,y
        sta MASKTAB2,x
        txa
        and #3
        tay
        lda mask4,y
        sta MASKTAB3,x
        txa                         ; and the four-dot reversal for mirroring:
        and #$88                    ; dot i is bit 7-i and bit 3-i, so 7<->4,
        lsr                         ; 6<->5, 3<->0, 2<->1
        lsr
        lsr
        sta tmp
        txa
        and #$44
        lsr
        ora tmp
        sta tmp
        txa
        and #$22
        asl
        ora tmp
        sta tmp
        txa
        and #$11
        asl
        asl
        asl
        ora tmp
        sta SWAPTAB,x
        inx
        bne @mt
        ; the directory carries offsets from the start of the sprite data
        lda #<SPRTAB
        sta ptr
        lda #>SPRTAB
        sta ptr+1
        ldx #103
@fx:    ldy #0
        lda (ptr),y
        clc
        adc #<SPRDATA
        sta (ptr),y
        iny
        lda (ptr),y
        adc #>SPRDATA
        sta (ptr),y
        lda ptr
        clc
        adc #8
        sta ptr
        bcc :+
        inc ptr+1
:       dex
        bne @fx
        lda #<SPRMSKTAB
        sta ptr
        lda #>SPRMSKTAB
        sta ptr+1
        ldx #103
@fm:    ldy #0
        lda (ptr),y
        clc
        adc #<SPRDATA
        sta (ptr),y
        iny
        lda (ptr),y
        adc #>SPRDATA
        sta (ptr),y
        lda ptr
        clc
        adc #2
        sta ptr
        bcc :+
        inc ptr+1
:       dex
        bne @fm
        rts

; the logic is in another bank, so it hands sprites over one at a time
addsprite:                          ; A = id, spx/spy = map px of the reference point
        ldx NSPR
        cpx #MAXSPR
        bcs @full
        sta tmp2                    ; the id, while X is turned into the list offset
        stx tmp
        txa
        asl
        asl
        clc
        adc tmp
        tay
        lda tmp2
        sta SPRLIST,y
        lda spx
        sta SPRLIST+1,y
        lda spx+1
        sta SPRLIST+2,y
        lda spy
        sta SPRLIST+3,y
        lda spy+1
        sta SPRLIST+4,y
        inc NSPR
@full:  rts

drawsprite:
        stza spclip                 ; set at every window edge the sprite is cut against
        sta sp_id
        stza ptr+1
        asl                         ; id*8 -> the directory offset
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        clc
        adc #<SPRTAB
        sta ptr
        lda ptr+1
        adc #>SPRTAB
        sta ptr+1
        ldy #6
        lda (ptr),y
        sta sp_flags
        lda sp_id                   ; the mask plane, from the table beside it
        asl
        tax
        lda SPRMSKTAB,x
        sta sp_mbase
        lda SPRMSKTAB+1,x
        sta sp_mbase+1
@entry2:
        ldaz ptr
        sta sp_ptr
        ldy #1
        lda (ptr),y
        sta sp_ptr+1
        iny
        lda (ptr),y
        sta sp_w
        beq @out0
:                                   ; keep the bare label: it preserves the anonymous-label count
        ldy #7
        lda (ptr),y
        sta sp_lines
        sta sp_ext
  .if MODE1
        lsr
        sta sp_mh                   ; mask bytes per column group = pixel rows
  .endif
        lda sp_flags
        and #2
        bne :+
        asl sp_ext                  ; half-res: two scanlines per stored row
:       ; ---- horizontal: sx = spx - refx - wx ; c0 = sx >> 1
        ldy #4
        lda (ptr),y
        and #$80                    ; sext inlined: the jsr/rts was 12 cycles of the 39
        beq @sxp
        lda #$FF
@sxp:   sta tmp3
        lda spx
        sec
        sbc (ptr),y
        tax
        lda spx+1
        sbc tmp3
        tay
        txa
        sec
        sbc wx
        sta w16
        tya
        sbc wx+1
        cmp #$80
        ror a                       ; sign into bit 7, old bit 0 out to C
        ror w16                     ; arithmetic shift right 1 -> c0 (16 bit)
        cmp #0                      ; A still holds w16+1: just restore N,Z
        beq @cpos
        cmp #$FF
        bne @out0
        ; c0 negative (-128..-1): cstart = 0 ; visible if c0 + W > 0
        lda w16
        clc
        adc sp_w
        deca
        bmi @out0
        inc spclip
        sta sp_c1
        stz sp_c0
        ; first visible column index = -c0
        lda w16
        eor #$FF
        inca
        sta sp_c                    ; starting image column
        bra @vert
@cpos:  lda w16
        cmp #ROWCHARS
        bcs @out0                   ; not taken: C = 0 for the adc below
        sta sp_c0
        adc sp_w
        deca
        cmp #ROWCHARS
        bcc :+
        inc spclip                  ; and at the right
        lda #(ROWCHARS-1)
:       sta sp_c1
        stza sp_c
        bra @vert
@out0:  rts
@vert:
        ; ---- vertical: sy = spy - refy - wy ; lb0 = 2*sy + wfine
        ldy #5
        lda (ptr),y
        jsr sext
        lda spy
        sec
        sbc (ptr),y
        tax
        lda spy+1
        sbc tmp3
        tay
        txa
        sec
        sbc wy
        tax
        tya
        sbc wy+1
        sta sp_lb0+1
        txa
        asl                         ; C = old bit 7, exactly what 'asl w16' left
        rol sp_lb0+1
        clc
        adc wfine
        sta sp_lb0
        bcc @nc
        inc sp_lb0+1                ; lb0 (16 bit signed)
        clc                         ; only this arm arrives with C set
@nc:
        ; lend = lb0 + ext - 1
        lda sp_ext
        deca
        adc sp_lb0
        sta w16
        lda sp_lb0+1
        adc #0
        sta w16+1                   ; w16 = lb1
        ; clip lstart = max(lb0,0) ; lend = min(lb1, 247)
        lda sp_lb0+1
        bmi @top
        bne @out0                   ; lb0 >= 256 -> below
        lda sp_lb0
        cmp #BUFROWS*8
        bcs @out0
        sta tmp                     ; lstart
        bra @ck
@top:   lda w16+1
        bmi @out0                   ; lb1 < 0
        inc spclip                  ; cut off at the top
        stz tmp
@ck:    lda w16+1
        bne @clampend
        lda w16
        cmp #BUFROWS*8
        bcc :+
@clampend:
        inc spclip                  ; and at the bottom
        lda #BUFROWS*8-1
:       sta tmp2                    ; lend
        cmp tmp
        bcc @out0
        and #7                      ; cmp/bcc leave A = tmp2: no reload needed
        sta sp_ra1
        lda tmp2
        lsr
        lsr
        lsr
        sta sp_r1
        lda tmp
        and #7
        sta sp_ra0
        lda tmp
        lsr
        lsr
        lsr
        sta sp_r0                   ; sta sets no flags: Z still from the third lsr
        bne @nopart
        ldx curbuf                  ; touches the window's top row (see drawrect)
        lda sp_c0
        cmp PART_LO,x
        bcs :+
        sta PART_LO,x
:       lda sp_c1
        cmp PART_HI,x
        bcc @nopart
        sta PART_HI,x
@nopart:
        ; ---- record rect in current sprite record
        ldy #5
        lda wcx
        clc
        adc sp_c0
        sta w16                     ; @rows needs this same sum: keep it, don't rebuild it
        sta (rp),y
        iny
        lda wcx+1
        adc #0
        sta w16+1
        sta (rp),y
        iny
        lda wcy
        clc
        adc sp_r0
        sta (rp),y
        iny
        lda sp_c1
        sec
        sbc sp_c0
        inca
        sta (rp),y
        iny
        lda sp_r1
        sbc sp_r0                   ; C still set by the width sbc above (sp_c1 >= sp_c0)
        inca
        ldx spclip
        beq :+                      ; may be visible next time and it has to be redrawn
        ora #$80
:       sta (rp),y
        ; ---- column base pointer & step
        lda sp_flags
        and #1                      ; no bit #imm on a 6502: A is reloaded below
        beq @nomirror
        ; mirror: image column = W-1-c (the column loop then steps backwards)
        clc
        lda sp_w
        sbc sp_c                    ; C=0 subtracts the extra 1: sp_w - sp_c - 1
        sta sp_c
        lda sp_flags                ; only the mirror arm clobbers A
@nomirror:
        ; ---- select the inner blitter once per sprite (patched jmp in the column loop)
        lda sp_flags
        and #8                      ; bit3: copy blitter
        beq :+
        ldx #8
        bne :++
:       lda sp_flags
        and #3
        asl
        tax
:       lda sprdisp_tab,x
        sta ds_dispatch+1
        lda sprdisp_tab+1,x
        sta ds_dispatch+2
        ; sp_col = sp_ptr + sp_c * lines
        lda sp_ptr+1
        sta sp_col+1
        lda sp_ptr
        ldx sp_c
        beq @mdone
        clc
@mul:   adc sp_lines
        bcc :+
        inc sp_col+1
        clc
:       dex
        bne @mul
@mdone: sta sp_col
  .if MODE1
        stz mtab                    ; the MASKTAB pages are indexed by the mask byte
        lda sp_c
        and #3                      ; phase of the first column drawn, and its page
        clc
        adc #>MASKTAB0
        sta sp_mpg0
        ; mask column base = mask plane + (first image column / 4) * pixel rows
        lda sp_mbase
        sta sp_mrp
        lda sp_mbase+1
        sta sp_mrp+1
        lda sp_c
        lsr
        lsr
        beq @mgdone
        tax
@mgrp:  lda sp_mrp
        clc
        adc sp_mh
        sta sp_mrp
        bcc @mgnc
        inc sp_mrp+1
@mgnc:  dex
        bne @mgrp
@mgdone:
  .endif
@rows:
        lda sp_r0
        sta sp_row
        ; screen base for (wcx + c0, wcy + r0): one ringaddr, then +80 chars per row
        ; (w16 = wcx + sp_c0 was already built when the record rect was written)
        lda wcy
        clc
        adc sp_r0
        jsr ringaddr
        lda sp
        sta sp_rb
        lda sp+1
        sta sp_rb+1
        ; source row pointer = column base + r0*8 - lb0 (>>1 for half res); +8 (+4) per row
        ; source row pointer = column base + r0*8 - lb0 (>>1 for half res); +8 (+4) per row
        lda tmp                     ; tmp is still lstart, and sp_r0 = lstart >> 3,
        and #$F8                    ; so r0*8 is lstart & $F8: no reload and no shifts
        sec
        sbc sp_lb0
        sta w16
        lda #0
        sbc sp_lb0+1
        sta w16+1
        ldx #8
        lda sp_flags
        and #2
        bne :+
        lda w16+1
        cmp #$80
        ror w16+1
        ror w16
        ldx #4
:       stx sp_rinc
        lda sp_col
        clc
        adc w16
        sta sp_rp
        lda sp_col+1
        adc w16+1
        sta sp_rp+1
  .if MODE1
        lda w16+1                   ; the same offset in pixel rows (signed >> 1)
        cmp #$80
        ror w16+1
        ror w16
        lda sp_mrp
        clc
        adc w16
        sta sp_mrp
        lda sp_mrp+1
        adc w16+1
        sta sp_mrp+1
  .endif
        lda sp_c1
        sec
        sbc sp_c0
        sta sp_ncol                 ; columns-1
ds_rowloop:
        lda sp_rb
        sta sp
        lda sp_rb+1
        sta sp+1
        lda sp_rp
        sta ptr
        lda sp_rp+1
        sta ptr+1
  .if MODE1
        lda sp_mrp
        sta mptr
        lda sp_mrp+1
        sta mptr+1
        lda sp_mpg0
        sta mtab+1
  .endif
        ; ra range for this row
        stz tmp                     ; ra0' = 0 unless this is the first row
        lda sp_row
        cmp sp_r0
        bne :+
        ldx sp_ra0
        stx tmp
:       ldx #7
        cmp sp_r1
        bne :+
        ldx sp_ra1
:       stx tmp2                    ; ra1'
        lda sp_ncol
        sta sp_cnt                  ; columns-1 (countdown)
ds_colloop:
ds_dispatch:
        jmp sprFN                   ; operand patched per sprite
sprdisp_tab: .word sprFN, sprFM, sprFN, sprFM, sprFN
  .if MODE1
sprretMk:                           ; mask blitter, mirrored: the image column descends,
        dec mtab+1                  ; so the phase does too; below phase 0 it is the
        lda mtab+1                  ; previous group's phase 3
        cmp #(>MASKTAB0)-1
        bne @mk
        lda #(>MASKTAB0)+3
        sta mtab+1
        lda mptr
        sec
        sbc sp_mh
        sta mptr
        bcs @mk
        dec mptr+1
@mk:
  .endif
sprretM:                            ; next column, mirrored: source pointer - lines
        lda ptr
        sec
        sbc sp_lines
        sta ptr
        bcs sprnext
        dec ptr+1
        bra sprnext
  .if MODE1
sprretPk:                           ; mask blitter: next phase is the next page; past
        inc mtab+1                  ; phase 3 it is the next group's phase 0
        lda mtab+1
        cmp #(>MASKTAB0)+4
        bne @pk
        lda #>MASKTAB0
        sta mtab+1
        lda mptr
        clc
        adc sp_mh
        sta mptr
        bcc @pk
        inc mptr+1
@pk:
  .endif
sprretP:                            ; next column: source pointer + lines
        lda ptr
        clc
        adc sp_lines
        sta ptr
        bcc sprnext
        inc ptr+1
sprnext:
        spnext
        dec sp_cnt
        bpl ds_colloop
ds_rowdone:
        lda sp_row
        cmp sp_r1
        beq ds_done
        inc sp_row
        lda sp_rp
        clc
        adc sp_rinc
        sta sp_rp
        bcc :+
        inc sp_rp+1
        clc
:
  .if MODE1
        lda sp_mrp
        adc #4                      ; C is clear
        sta sp_mrp
        bcc @mrnc
        inc sp_mrp+1
        clc
@mrnc:
  .endif
        lda sp_rb
        adc #<ROWBYTES
        sta sp_rb
        lda sp_rb+1
        adc #>ROWBYTES
        ringup
        sta sp_rb+1
        jmp ds_rowloop
ds_done: rts
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

        .segment "SPRDATA"
SPRTAB:     .incbin "build/sprtab.bin"
SPRMSKTAB:  .incbin "build/sprmask.bin"
SPRDATA:    .incbin "build/spr.bin"

        .segment "SPRBSS"
        .align 256                  ; four consecutive pages, one per column phase
MASKTAB0:   .res 256
MASKTAB1:   .res 256
MASKTAB2:   .res 256
MASKTAB3:   .res 256
SWAPTAB:    .res 256
SPRLIST:    .res 5*MAXSPR
SPRREC:     .res 2*10*MAXREC
RECCNT:     .res 2
NSPR:       .res 1
