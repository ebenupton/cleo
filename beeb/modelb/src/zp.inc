        .zeropage
jv:       .res 2                    ; jmpx vector (6502 has no jmp (abs,x))
ptr:      .res 2
tp:       .res 2
sp:       .res 2
tmp:      .res 1
tmp2:     .res 1
tmp3:     .res 1
tmp4:     .res 1
cnt:      .res 1
w16:      .res 2
w16b:     .res 2

wx:       .res 2                    ; window origin in map pixels
wy:       .res 2
wcx:      .res 2                    ; window origin in chars
wcy:      .res 1
wfine:    .res 1                    ; 0,2,4,6: scanlines into the top char row
curbuf:   .res 1                    ; the buffer being drawn
ringS:    .res 2                    ; window start, in ring chars
barq:     .res 1                    ; its slot
crtcb:    .res 2                    ; CRTC base of the buffer being drawn
ringehi:  .res 1                    ; its ring end, high byte (the fold test)
ringbase: .res 2                    ; and its base

irq_x:    .res 1
irq_y:    .res 1
vsyncs:   .res 1
flipreq:  .res 1
flipvs:   .res 1
curR7:    .res 1
SECIDX:   .res 1
DISPSECT: .res 1
NEXTSECT: .res 1
keys:     .res 1
frame:    .res 1
fc_a:     .res 1                    ; A across a far call

crtcbm:   .res 2                    ; crtcb - RINGCHARS: the mirror redirect
RINGLO:   .res RINGROWS             ; slot -> address, for the buffer being drawn
RINGHI:   .res RINGROWS
VS2T:     .res 2                    ; vsync -> the bar's restart, in T1 ticks
BUF_SEC0: .res 4                    ; per buffer: the CRTC start of section 0
BUF_SEC0T1: .res 4                  ;   and how long it lasts
MAPBUF:   .res 48                   ; a strip of map, fetched from bank 6 in one call
dt_tx:    .res 1                    ; draw_maprect: the tile rectangle
dt_ty:    .res 1
dt_nx:    .res 1
dt_ny:    .res 1
dt_i:     .res 1
dst0:     .res 2                    ; where its two char rows go in the ring
dst1:     .res 2

; the sprite blitter's state: all of it is per sprite and none of it is shared
spx:      .res 2
spy:      .res 2
sp_ptr:   .res 2
sp_w:     .res 1
sp_lines: .res 1
sp_ext:   .res 1
sp_flags: .res 1
sp_c0:    .res 1
sp_c1:    .res 1
sp_lb0:   .res 2
sp_r0:    .res 1
sp_r1:    .res 1
sp_ra0:   .res 1
sp_ra1:   .res 1
sp_col:   .res 2
sp_rb:    .res 2
sp_rp:    .res 2
sp_rinc:  .res 1
sp_ncol:  .res 1
sp_row:   .res 1
sp_c:     .res 1
sp_lim:   .res 1
sp_cnt:   .res 1
spclip:   .res 1
sp_id:    .res 1
sp_msk:   .res 1
sp_mpg0:  .res 1
sp_mh:    .res 1
sp_mrp:   .res 2
sp_mbase: .res 2
mptr:     .res 2
mtab:     .res 2
rp:       .res 2
spi:      .res 1
PART_LO:  .res 2
PART_HI:  .res 2
