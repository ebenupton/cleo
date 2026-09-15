        .zeropage
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
isr_t1:   .res 1                    ; scratch for what runs in the interrupt: the key
isr_t2:   .res 1                    ; scan and the sound player must not touch tmp*,
isr_t3:   .res 1                    ; which the blitter they interrupted is using
vsyncs:   .res 1
flipreq:  .res 1
flipvs:   .res 1
curR7:    .res 1
SECIDX:   .res 1
DISPSECT: .res 1
NEXTSECT: .res 1
keys:     .res 1
SFXREQ:   .res 1                    ; the logic asks for an effect; the vsync plays it
SFXPTR:   .res 2                    ; where it has got to, and how long this step lasts
SFXDUR:   .res 1
MUSPTR:   .res 2                    ; the music's place in the stream
fc_a:     .res 1                    ; A across a far call

crtcbm:   .res 2                    ; crtcb - RINGCHARS: the mirror redirect
RINGLO:   .res RINGROWS             ; slot -> address, for the buffer being drawn
RINGHI:   .res RINGROWS
VS2T:     .res 2                    ; vsync -> the bar's restart, in T1 ticks
BUF_SEC0: .res 4                    ; per buffer: the CRTC start of section 0
BUF_SEC0T1: .res 4                  ;   and how long it lasts
MAPBUF:   .res 40                   ; a strip of map, fetched from bank 6 in one call:
                                    ; 21 tiles is the widest strip, 40 the object fetch
tp2:      .res 2                    ; the tile's second char row, when both are drawn
jv:       .res 2                    ; jmpx vector (6502 has no jmp (abs,x))
mrow:     .res 1                    ; the map char row in the ring's last slot row
; ---- the renderer's scratch, and the logic's temps on top of it ----------------
; None of this is live between frames: the tile blitter's rectangle, the sprite
; blitter's state and the two destination pointers are all set up and consumed
; inside one call.  The logic runs before any of it, so its transient temps (the
; $A8..$DE block in the Master) are laid over the same bytes.
LTMP0:
dt_cx:    .res 1                    ; draw_maprect: chars across, char rows down
dt_ncx:   .res 1
dt_cy:    .res 1
dt_ncy:   .res 1
dt_half:  .res 1                    ; 0 = the tile's top char row, 32 = its bottom
dt_lastty:.res 1                    ; tile row MAPBUF holds ($FE = the whole rectangle)
dt_mbase: .res 1                    ; where this tile row's strip starts in MAPBUF
dt_ilim:  .res 1
dt_t0:    .res 1                    ; the tiles that char range spans
dt_nt:    .res 1
dt_ls:    .res 1                    ; chars skipped at the left of the first tile
dt_rem:   .res 1                    ; chars of the range still to draw
dt_s:     .res 1                    ; draw_tile: first char of the tile, and how many
dt_n:     .res 1
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
lidx:     .res 1                    ; erase_old's place in the record list
LTMP1:
        .assert LTMP1 - LTMP0 >= 56, error, "the logic's temps do not fit over the renderer's scratch"

; ---- the logic's transient temps, over the scratch above (see logicm.s) --------
ox      = LTMP0+0  
oy      = LTMP0+2  
fa      = LTMP0+4  
fb      = LTMP0+6  
fc      = LTMP0+8  
fd      = LTMP0+10 
fe      = LTMP0+12 
rx      = LTMP0+14 
ry      = LTMP0+16 
sx      = LTMP0+18 
sy      = LTMP0+20 
qx      = LTMP0+22 
qy      = LTMP0+24 
alt     = LTMP0+26 
q1      = LTMP0+27 
q2      = LTMP0+28 
q3      = LTMP0+29 
q4      = LTMP0+30 
q5      = LTMP0+31 
q6      = LTMP0+32 
obj     = LTMP0+33 
gx      = LTMP0+34 
gy      = LTMP0+35 
grow    = LTMP0+54                    ; bucket walk: gy << gridsh
gx0     = LTMP0+36 
gx1     = LTMP0+37 
gy1     = LTMP0+38 
bent    = LTMP0+39 
otype   = LTMP0+40 
t16     = LTMP0+41                      ; 2 bytes
t16b    = LTMP0+43                      ; 2 bytes
dpx     = LTMP0+45                      ; 2 bytes: player step count etc
hx      = LTMP0+47                      ; 2 bytes: rx used for hit direction
mapptr  = LTMP0+49                      ; 2 bytes
q1x     = LTMP0+51 
rise    = LTMP0+52                      ; 2 bytes

