drawsprite:
        stza spclip                 ; set at every window edge the sprite is cut against
        cmp #BOXID0+BOXN            ; the "nothing can disturb it" aliases draw the same
        bcc :+                      ; picture as the ids BOXN below them
        sbc #BOXN
:
  .if MODE1
        sta sp_id
  .endif
        stza ptr+1
        asl                         ; id*8 -> offset
        rol ptr+1
        asl
        rol ptr+1
        asl
        rol ptr+1
        ldx spbank
        cpx #BANK_SPR
        bne @titledir
        ldx #BANK_LVL           ; SPR_TABLE is in bank 7; the whole prologue reads
        stx ROMSEL_CPY          ; the directory and none of it reads sprite data
        stx ROMSEL
        clc
        adc #<SPR_TABLE
        sta ptr
        lda ptr+1
        adc #>SPR_TABLE
        sta ptr+1
        ldy #6
        lda (ptr),y
        sta sp_flags
        ldx #BANK_SPR
        bit #4
        beq :+
        ldx #(BANK_SPR|$80)
:       bit #$10                ; A still holds the flags byte
        beq :+
        ldx #BANK_TIL1
:       stx sp_dbank            ; wanted later: the directory is still being read
  .if MODE1
        lda sp_id
        asl
        tax
        lda SPRMASK,x
        sta sp_mbase
        lda SPRMASK+1,x
        sta sp_mbase+1
  .endif
        bra @entry2
@titledir:
        ; ---- title piece: directory + data at TITLE_ADDR of bank(spbank)
        sta ptr                     ; only this path uses id*8 as the low byte unadjusted
        lda ptr+1
        clc
        adc #>TITLE_ADDR
        sta ptr+1
        lda spbank              ; title pieces keep directory and data in one bank
        sta sp_dbank
        sta ROMSEL_CPY
        sta ROMSEL
        ldy #6
        lda (ptr),y
        sta sp_flags
  .if MODE1
        lda sp_id                   ; the mask address table behind the directory
        asl
        tax
        lda TITLE_ADDR+$80,x
        sta sp_mbase
        lda TITLE_ADDR+$81,x
        sta sp_mbase+1
  .endif
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
        lda sp_dbank            ; done with the directory: the blitter wants the data
        sta ROMSEL_CPY
        sta ROMSEL
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
        bit #1
        beq @nomirror
        ; mirror: image column = W-1-c (the column loop then steps backwards)
        clc
        lda sp_w
        sbc sp_c                    ; C=0 subtracts the extra 1: sp_w - sp_c - 1
        sta sp_c
        lda sp_flags                ; only the mirror arm clobbers A
@nomirror:
        ; ---- select the inner blitter once per sprite (patched jmp in the column loop)
        bit #8                      ; bit3: copy blitter
        beq :+
        ldx #8
        bne :++
:       and #3                      ; A is still sp_flags: bit #imm does not alter A
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
        and #3                      ; phase of the first column drawn, and its page:
        ora #>MASKTAB0              ; MASKTAB0 is 1K aligned, so phase = page & 3
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
sprdisp_tab: .word sprFN, sprFM, sprFN, sprFM, sprFC
  .if MODE1
sprretMk:                           ; mask blitter, mirrored: the image column descends,
        dec mtab+1                  ; so the phase (= page & 3) does too; below phase 0
        lda mtab+1                  ; it is the previous group's phase 3
        and #3
        cmp #3
        bne @mk
        lda mtab+1
        clc
        adc #4
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
        and #3
        bne @pk
        lda mtab+1
        sec
        sbc #4
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