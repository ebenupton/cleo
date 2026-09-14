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
crtcbm:   .res 2                    ; crtcb - RINGCHARS: the mirror redirect
RINGLO:   .res RINGROWS             ; slot -> address, for the buffer being drawn
RINGHI:   .res RINGROWS
VS2T:     .res 2                    ; vsync -> the bar's restart, in T1 ticks
BUF_SEC0: .res 4                    ; per buffer: the CRTC start of section 0
BUF_SEC0T1: .res 4                  ;   and how long it lasts
MAPBUF:   .res 48                   ; a strip of map, fetched from bank 6 in one call
