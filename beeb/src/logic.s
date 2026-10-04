; ============================================================================
; CLEO - game logic (port of CleoApp.run() from the J2ME original)
; ============================================================================

; ---------------------------------------------------------------- 16-bit macros
.macro mov16 dst, src
        lda src
        sta dst
        lda src+1
        sta dst+1
.endmacro
.macro add16 dst, src
        clc
        lda dst
        adc src
        sta dst
        lda dst+1
        adc src+1
        sta dst+1
.endmacro
.macro add16i dst, imm
        clc
        lda dst
        adc #<(imm)
        sta dst
  .if (>(imm) = 0) .and (.not .xmatch({dst}, {dpx}))  ; vy_step reads the high byte from A
        .assert (dst) < $100, error, "add16i: bcc *+4 skips a zero-page inc"
        bcc *+4                    ; no carry: the high byte stands
        inc dst+1
  .else
        lda dst+1
        adc #>(imm)
        sta dst+1
  .endif
.endmacro
.macro sub16i dst, imm
        sec
        lda dst
        sbc #<(imm)
        sta dst
  .if >(imm) = 0
        .assert (dst) < $100, error, "sub16i: bcs *+4 skips a zero-page dec"
        bcs *+4                    ; no borrow: the high byte stands
        dec dst+1
  .else
        lda dst+1
        sbc #>(imm)
        sta dst+1
  .endif
.endmacro
; dst = a - b
.macro dif16 dst, aa, bb
        sec
        lda aa
        sbc bb
        sta dst
        lda aa+1
        sbc bb+1
        sta dst+1
.endmacro
; branch if a > b (both 16-bit vars)
.macro bgt16 aa, bb, label
        lda bb
        cmp aa
        lda bb+1
        sbc aa+1
:      bmi label                   ; no V fixup: every caller compares x positions (a map
                                    ; x < 2048, or one plus C>>1), never 2^15 apart
.endmacro
.macro bge16 aa, bb, label
        lda aa
        cmp bb
        lda aa+1
        sbc bb+1
:      bpl label                   ; no V fixup: every caller compares x positions (a map
                                    ; x < 2048, or one plus C>>1), never 2^15 apart
.endmacro
.macro bmi16 var, label
        bit var+1
        bmi label
.endmacro
.macro bpl16 var, label
        bit var+1
        bpl label
.endmacro
; A = max(A - n, 0)  (unsigned)
.macro submin0 n
        sec
        sbc #n
        bcs :+                     ; no borrow: A >= n, the difference stands
        lda #0
:
.endmacro
; branch if var (16) == 0
.macro beq16 var, label
        lda var
        ora var+1
        beq label
.endmacro

; ---------------------------------------------------------------- the game's constants
; Every rate is two of the original's steps a frame (game_frame); the sprite ids
; (SPR_*), the object types (OT_*) and in_range's quads (RQ_*) are the packer's,
; assets.inc.  Positions and speeds in game pixels and 1/256ths of one a frame.
MAXFALL = 12                       ; Cleo's fall a frame at most (the camera follows it):
                                   ;  three char rows (the original's 8 a step was 16)
MAXDWY0 = 8                        ; the original's fall a step at most
GRAV      = 80                     ; gravity's step: vy = (vy + GRAV) * 31 >> 5
JUMP_VY   = -1280                  ; a jump's (and a knock-up's, a stomp bounce's) vy
TRAMP_VY  = -2048                  ; a trampoline's
KNOCK_VX  = 768                    ; a hit's knockback, and Cleo's top speed
BOOM_VX   = 3584                   ; the boomerang's throw
ACC_GROUND = 72                    ; running: the ground's acceleration, and the air's
ACC_AIR   = 480
JUMP_VYT  = 384                    ; |vy| from which the jump shows its rising / falling frame
CLEO_FEET = 16                     ; her feet: py + 16 (the altitude is read there)
CLEO_KILLY = 12                    ; where a kill tile is felt: py + 12
CLEO_H    = 24                     ; her height: off the map's bottom past maph - 24
EXIT_W    = 16                     ; the exit's box, from (exitx, exity)
EXIT_H    = 24
CAM_Y     = 46                     ; Cleo's y in the window, one for one
CAM_AHEAD_R = WINPX/4              ; the camera's lookahead bias: facing right, Cleo a
CAM_AHEAD_L = 3*WINPX/4            ;  quarter in from the left; left, three quarters
PUSH_MASK = 7                      ; a tile attribute's bits 0-2: push + PUSH_BIAS (bit 7:
PUSH_BIAS = 3                      ;  a kill tile)
PUSH_NONE = 3                      ;  a push of 3 is the original's "none": the air's
                                   ;  friction and acceleration apply
ALT_OUTSIDE = 8                    ; the altitude byte of a pixel off the map (the original's)
RESPAWN_F = 30                     ; dead: frames before the respawn
HURT_F    = 32                     ; hurt: frames of invulnerability,
CTRL_F    = 13                     ;  the control back after this many
THROW_T1  = 4                      ; a throw's anim: the launch, and its frame changes
THROW_T2  = 6
THROW_T3  = 10
THROW_END = 12                     ;  (the anim ends)
RUN_ANIM  = 16                     ; the run anim wraps here (4 frames of 4)
IDLE_ANIM = 128                    ; the stand's wraps here: the blink's first frame from
BLINK0    = 93                     ;  BLINK0, its second for the BLINK_LEN from BLINK1
BLINK1    = 109
BLINK_LEN = 4
STARCLK   = 12                     ; the stars' spin: 12 steps (6 frames, two steps each)
SPARKLE0  = 12                     ; a collected star's count: SPARKLE0 up to SPARKLE_END
SPARKLE_END = 18                   ;  (3 frames, then gone)
BCNT_HIT  = 8                      ; the boomerang's count: in flight 0..6 (its spin);
BCNT_GONE = 14                     ;  hit or stopped, BCNT_HIT to BCNT_GONE, then inactive
BOOM_STEP = 8                      ; its move, 8 px at a time (the altitude read between)
BOOM_REF_DY = 8                    ; brel's ry = py - by + 8: Cleo's reference point is 8 px
                                   ;  below the boomerang's (its pull and its catch)
TRAMP_TOP = 10                     ; a trampoline's spring count: 2, 4, 6, 8, then back to 0
                                   ;  in place of TRAMP_TOP
TRAMP_SINK = 6                     ; Cleo set 6 px into its band on a bounce
DORM_MASK = 63                     ; the red snake's and the spike's rest: -(rnd & 63) - 64
DORM_BASE = 64
RSNAKE_UP = 17                     ; the red snake's counter top (then it rests)
RSNAKE_SHOW = -15                  ;  the snake is out from this count
RSNAKE_KNOCK = 32                  ;  knocked: its flight's step a frame (two of 16)
RISE_N    = 32                     ;  rise_tab's entries (the counter & 31)
SNAKE_PAUSE = 3                    ; the green snake's counter: no step at a multiple of 3,
SNAKE_E_WRAP = 12                  ;  back to 0 from 12; dying (SNK_DEAD), 0 to 64,
SNAKE_DEAD_E = 64                  ;  flying SNAKE_FLY a step up to SNAKE_FLYMAX
SNK_DEAD  = 4                      ;  (its states: 0 right, 1 left, 2-3 still, 4-5 dying)
SNAKE_FLY = 16
SNAKE_FLYMAX = 128
BAT_DEAD_E = 8                     ; the bat's counter: flapping 0..7 (BAT_FLAP_N frames,
BAT_FLAP_N = 8                     ;  wide from BAT_FLAP_WIDE), BAT_DEAD_E dead
BAT_FLAP_WIDE = 6
BAT_GRAV  = 120                    ; a dead bat's fall: its step of gravity
BATFALL_A0 = -640                  ;  and its first vy
BAT_STOMP_Y = 4                    ; a stomp: Cleo above it by more than this where her move began
BATOFF_N  = 16                     ; bat_off's entries (the wobble)
WALK_STEP = 3                      ; the mask's and mummy's step a frame
WALK_E_WRAP = 12                   ;  their counter: 0, 2 .. 10, then 0
WALK_FRAME_E = 3                   ;  a frame every 3 of it
WALK_STAND_F = 8                   ;  the standing frame, at either end of the walk
SPIKE_UP  = 24                     ; the spike's counter top; it is out below SPIKE_OUT
SPIKE_OUT = 8
PICKUP_END = 6                     ; the powerup's pickup: 2 a frame to 6
VANISH_EVERY = 4                   ; the vanishing block: a step every 4th count,
VANISH_GONE = 12                   ;  frames fe/2 to 12 (gone), VANISH_SOLID_F held
VANISH_SOLID_F = 6                 ;  to VANISH_BACK, then back from VANISH_END - fe,
VANISH_BACK = 37                   ;  wrapping at VANISH_END
VANISH_END = 48
SCORE_STAR  = 1                    ; the scores (BCD)
SCORE_SNAKE = 5
SCORE_RSNAKE = 4
SCORE_BAT   = 6
SCORE_SWITCH = $20
HEALTH_MAX = 3                     ; health, and the lives a game starts with
LIVES     = 3
NLEVELS   = 16                     ; the levels (8 main, each with a bonus)
RND_SEED  = $1234                  ; rnd's: the seed, and the LFSR's taps
RND_TAPS  = $B4
GRID_NONE = $FF                    ; LV_GRID: an empty cell; LV_BNEXT: a chain's end
GRIDN     = 128                    ; the collision grid's cells
MAPROWS   = 128                    ; the map's rows at most (MROWL/H)
BINLINKS  = 256                    ; LV_BOBJ/LV_BNEXT: an entry per object per cell
OBJCLR_PAGES = 10                  ; level_init's clear: 10 pages from O_STAMP
BIN_TILESHIFT = 3                  ; a grid cell is 8 tiles (BINPX px)
        .assert (TILEPX << BIN_TILESHIFT) = BINPX, error, "the collision grid's cell is BINPX"
; the HUD's digit slots (BARCACHE): lives, health, the stars' two, the score's five
HUD_SLOT_LIVES  = 0
HUD_SLOT_HEALTH = 1
HUD_SLOT_STARS  = 2
HUD_SLOT_SCORE0 = 4
HUD_NSLOTS      = 9
DIGIT_ROWBYTES = TILECHARS*CHARBYTES   ; a digit's char row: 4 chars

; ---------------------------------------------------------------- object arrays (bank 7)
; OBJ_MAX (levelfmt.inc) objects at most (L7B has them all), a byte a field each
O_STAMP = LV_OBJST
O_TYPE  = O_STAMP + OBJ_MAX
O_XL    = O_TYPE + OBJ_MAX
O_XH    = O_XL + OBJ_MAX
O_YL    = O_XH + OBJ_MAX
O_YH    = O_YL + OBJ_MAX
O_AL    = O_YH + OBJ_MAX
O_AH    = O_AL + OBJ_MAX
O_BL    = O_AH + OBJ_MAX
O_BH    = O_BL + OBJ_MAX
O_CL    = O_BH + OBJ_MAX
O_CH    = O_CL + OBJ_MAX
O_DL    = O_CH + OBJ_MAX
O_DH    = O_DL + OBJ_MAX
O_EL    = O_DH + OBJ_MAX
O_EH    = O_EL + OBJ_MAX

; ---------------------------------------------------------------- game state (zero page, persistent)
        .segment "ZPGAME": zeropage  ; (after the engine's: defs.inc)
BINMAX = BINMAXDEF                 ; the bin walk's lists (assets.py: the objects' grid
                                  ; cells under the worst window)
bin_i:     .res 1                  ; the bin walk's index (44-64 accesses a frame)
bin_nstar:   .res 1                ; the cached bin walk's lengths: stars,
bin_noth:    .res 1                ;   everything else
frame:    .res 2
px:       .res 2                   ; player x, y (px)
py:       .res 2
vx:       .res 2                   ; 1/256 px per frame
vy:       .res 2
anim:     .res 1
ev_frame:  .res 2
facing:   .res 1                   ; 1 = left
running:  .res 1
firing:   .res 1
hurt:     .res 1                   ; invulnerable after hit
control:  .res 1
bx:       .res 2                   ; boomerang
by:       .res 2
bvx:      .res 2
bvy:      .res 2
bcnt:     .res 1
bactive:  .res 1
bounce:   .res 1
startx:   .res 2
starty:   .res 2
exitx:    .res 2
exity:    .res 2
level:    .res 1
lives:    .res 1
health:   .res 1
max_level: .res 1
last_keys: .res 1
logicvs:  .res 1
cam_off:   .res 1                  ; window bias: px - cam_off = window left (eased 40..120)

seed:     .res 2                   ; rnd's
; transient temps
ox:       .res 2
oy:       .res 2
fa:       .res 2
fb:       .res 2
fc:       .res 2
fd:       .res 2
fe:       .res 2
rx:       .res 2
ry:       .res 2
qx:       .res 2
qy:       .res 2
alt:      .res 1
q1:       .res 1
q2:       .res 1
q3:       .res 1
q4:       .res 1
q5:       .res 1
q6:       .res 1
obj:      .res 1
star_clk:  .res 1                  ; the stars' clock, 0..11: a star's spin step is it plus its phase
bin_r:     .res 4                  ; the bin walk's rectangle (its list's validity, bin_ok,
                                    ;  is GAMEBSS's: read once a frame)
gx:       .res 1
gy:       .res 1
gx0:      .res 1
gx1:      .res 1
gy1:      .res 1
bent:     .res 1
otype:    .res 1
t16:      .res 2
t16b:     .res 2
dpx:      .res 2                   ; player step count etc
hx:       .res 2                   ; rx used for hit direction
grow:     .res 1                   ; bucket walk: gy << gridsh
; The frame's hottest scalars (profiled: test/hotvars.mjs, 5-11 accesses a frame each
; on both machines), in the room zero page had and the room seven cold ones left it
; (stars, gridsh, rise, nobj, exiting, bin_ok: in GAMEBSS now, an access a frame or
; fewer each).  What the menus' image sets for the game -- level, lives, seed, max_level
; -- must stay in zero page or GAMEHI: the game's image zeroes GAMEBSS as it comes in.
mok:      .res 1                   ; the map memo (get_altitude): 0 for none; where it is
mkxlo:    .res 1                   ;  (the tile's qx & $F8, qx+1, qy & $F8, qy+1) and the
mkxhi:    .res 1                   ;  tile (the tiles above and below it, ma and mb, are
mkylo:    .res 1                   ;  GAMEBSS's)
mkyhi:    .res 1
mt:       .res 1
dxl:      .res 1                   ; Cleo's move that frame, across and down: the stretch
dyl:      .res 1                   ;  csweep tests (its start, pxs and pys, is GAMEBSS's)
swd:      .res 1                   ; span's: the stretch, its low end, r, and Y kept
swa:      .res 1
swlo:     .res 1
swhi:     .res 1
swy:      .res 1
        .zeropage

        .segment "GAMECODE"      

; ============================================================================
; Map queries.  The map is in bank 5 and this code in bank 7, so every touch goes
; through low RAM's map_row/map_byte/map_put (engine.s), which put bank 7 back.
; ============================================================================
; get map byte (the tile id) at tile (X = tx, A = ty) -> A; map_ptr = the row, Y = tx,
; X kept.  The row's address from the level's table (MROWL/MROWH, level_init).
map_tile:
        tay
        lda MROWL,y
        sta map_ptr
        lda MROWH,y
        sta map_ptr+1
        txa
        tay
        jmp map_byte

; altof: A = a tile id -> A = its alt byte at column qx & 7 (ALTTAB[cls*8 + (qx&7)],
; cls = LV_ALTCLS[id]).  Y clobbered.
.macro altof
        tay
        lda LV_ALTCLS,y
        asl
        asl
        asl
        eor qx                     ; (A & $F8) | (qx & 7): A's low 3 bits are 0
        and #$F8
        eor qx
        tay
        lda alt_tab,y
.endmacro

; tilexy: X = qx >> 3, A = qy >> 3, carry set if (qx,qy) is inside the map.
; Map sizes are multiples of 256 px, so "0 <= q < size" is just a compare of the high
; byte, and with that byte < 8 the tile coordinate is (hi << 5) | (lo >> 3) in one byte.
tilexy: lda qx+1
        cmp mapw+1
        bcs @out
        lsr                        ; hi <= 7: A = hi >> 1, C = hi & 1
        sta q2
        lda qx
        and #$F8
        ora q2                     ; lo7..lo3, 0, hi2, hi1 (C = hi0)
        ror
        ror
        ror                        ; hi2..hi0, lo7..lo3 (C = 0)
        tax
        lda qy+1
        cmp maph+1
        bcs @out
        lsr                        ; as for x: (hi << 5) | (lo >> 3) by rotation
        sta q2
        lda qy
        and #$F8
        ora q2
        ror
        ror
        ror
@out:   rts                        ; C = 0 inside (the rors), 1 outside (the bcs)

; get_info: A = alt byte for pixel (qx, qy), ALT_OUTSIDE if outside the map
get_info:
        jsr tilexy                 ; X = qx>>3, A = qy>>3
        bcs @out8                  ; (outside: out of line, after the rts)
        jsr map_tile
        altof
        rts
@out8:  lda #ALT_OUTSIDE           ; outside the map
        rts

; The map memo: the last tile get_altitude read (map_col: it and the tiles above and
; below it in its column) and where.  Cleo's queries -- the altitude under her, at
; each pixel of her move across, through her fall, the tile attributes -- land in the
; tile the one before them did more than half the time (test: 57%), and then skip the
; tile arithmetic and the visit to bank 5.  It holds across frames: mok = 0 (none) at a
; level's start and wherever the map is written (mark_pair: the vanishing block's and
; the switch's tiles).
; get_altitude: A = altitude (signed) at pixel (qx, qy)  [qy modified; tp clobbered]
; It reads the tile at (qx, qy) and at most one of the tiles above and below it, so
; the three come from one visit to the map (map_col) and the rest is arithmetic.  A
; pixel off the map takes the general way (@off), a read at a time through get_info.
get_altitude:
        lda qy+1                   ; tilexy's, in line, the row into X and the column
        cmp maph+1                 ; into Y
        bcs @offjj
        ldx mok                    ; the same tile as the last read (mapmemo)?
        beq @read
        cmp mkyhi
        bne @read
        lda qx+1
        cmp mkxhi
        bne @read
        lda qy
        and #<-TILEPX
        cmp mkylo
        bne @read
        lda qx
        and #<-TILEPX
        cmp mkxlo
        bne @read
        lda ma                     ; then its column's three tiles, as map_col gave them
        sta tp
        lda mb
        sta tp+1
        lda mt
        jmp @have
@offjj: jmp @offj                  ; (off the map: out of reach of a branch)
@read:  lda qy+1
        lsr
        sta q2
        lda qy
        and #$F8
        ora q2
        ror
        ror
        ror
        tax                        ; X = ty
        lda qx+1
        cmp mapw+1
        bcs @offjj
        lsr
        sta q2
        lda qx
        and #$F8
        ora q2
        ror
        ror
        ror
        tay                        ; Y = tx
        lda MROWL,x
        sta map_ptr
        lda MROWH,x
        sta map_ptr+1
        jsr map_col                ; A = the tile, tp = the one above, tp+1 the one below
        sta mt                     ; the memo: this tile, its column's two others, and
        tay                        ;  where it is
        lda tp
        sta ma
        lda tp+1
        sta mb
        lda qx
        and #<-TILEPX
        sta mkxlo
        lda qx+1
        sta mkxhi
        lda qy
        and #<-TILEPX
        sta mkylo
        lda qy+1
        sta mkyhi
        sta mok                    ; (qy+1 + 1 > 0: inside the map; any nonzero will do)
        inc mok
        tya
@have:  altof
        tax                        ; X = n3 (the alt byte)
        lda qy
        and #TILEPX-1
        sta q5                     ; n5
        txa
        and #15                    ; C = 0 from altof (a class < 32: its third asl)
        sbc q5                     ; (n3 & 15) - n5 - 1: C = 1 iff n5 < (n3 & 15)
        bcs @fnb                   ; n5 < (n3 & 15)
        lda qy                     ; C = 0 from the sbc: +8
        adc #TILEPX
        sta qy
        bcc @fbt                   ; no carry: qy+1 as tested at entry, inside the map
        inc qy+1
        lda qy+1                   ; the pixel 8 below: the tile below, or get_info's
        cmp maph+1                 ; ALT_OUTSIDE past the map's bottom (tilexy's test)
        lda #ALT_OUTSIDE
        bcs @fb2
@fbt:   lda tp+1
        altof
@fb2:   lsr
        lsr
        lsr
        lsr
        clc
        adc #9                     ; as @b1's
        sbc q5
        rts
@offj:  lda qy                     ; a pixel off the map: its alt byte is get_info's
        and #TILEPX-1              ; ALT_OUTSIDE, so n5 < (n3 & 15) and n4 = 0 always:
        sta q5                     ; n5 -- the tile above
        lda qy                     ; C = 1 from the bcs that came here
        sbc #TILEPX
        sta qy
        bcs :+
        dec qy+1
:       jsr get_info
        jmp @nb2
@fnb:   txa
        lsr
        lsr
        lsr
        lsr                        ; n4
        bne @d2
        lda qy
        sec
        sbc #TILEPX
        sta qy
        bcs @fnt                   ; no borrow: qy+1 as tested at entry, inside the map
        dec qy+1
        lda qy+1                   ; the pixel 8 above: the tile above, or get_info's
        cmp maph+1                 ; ALT_OUTSIDE above the map's top (qy+1 = $FF) or past it
        lda #ALT_OUTSIDE
        bcs @nb2
@fnt:   lda tp
        altof                      ; (on into @nb2)
@nb2:   tax
        and #15
        cmp #8
        beq @eq
        lda #0                     ; n4, which was 0: @d2's tail in line
        sec
        sbc q5
        rts
@eq:    txa
        lsr
        lsr
        lsr
        lsr                        ; C = 1: the low nibble is 8
        sbc #8
@d2:    sec
        sbc q5
        rts

; get_tile_attr: A = attribute byte for the tile at (qx,qy): bits0-2 push+3, bit7 kill ; 3 if outside
get_tile_attr:
        lda qy+1                   ; tilexy's, in line (as get_altitude's): row into X,
        cmp maph+1                 ; column into Y (get_tile_attr+2: A = qy+1 already,
        bcs @out                   ;  which that caller has not stored: store it, the
        sta qy+1                   ;  read below loads it again)
        ldx mok                    ; the same tile as get_altitude's last read?
        beq @read
        cmp mkyhi
        bne @read
        lda qx+1
        cmp mkxhi
        bne @read
        lda qy
        and #<-TILEPX
        cmp mkylo
        bne @read
        lda qx
        and #<-TILEPX
        cmp mkxlo
        bne @read
        lda mt
        jmp @attr
@read:  lda qy+1
        lsr
        sta q2
        lda qy
        and #$F8
        ora q2
        ror
        ror
        ror
        tax                        ; X = ty
        lda qx+1
        cmp mapw+1
        bcs @out
        lsr
        sta q2
        lda qx
        and #$F8
        ora q2
        ror
        ror
        ror
        tay                        ; Y = tx
        lda MROWL,x
        sta map_ptr
        lda MROWH,x
        sta map_ptr+1
        jsr map_byte
@attr:  tay
        lda LV_ATTR0,y
        rts
@out:   lda #PUSH_BIAS             ; off the map: no push, no kill
        rts

; ============================================================================
; Level initialisation (the loader has gathered the level into the banks)
; ============================================================================
; Cleo's fields in the level header (tools/assets.py writes them, and assets.inc
; names them: HDR_STARTX..HDR_EXITY the start and the exit in tiles, HDR_SPECIAL the
; special tiles' ids)
level_init:
        ; header
  .assert starty = startx+2 && exitx = startx+4 && exity = startx+6, error, "level_init: the start and exit words in a row"
  .assert HDR_STARTY = HDR_STARTX+1 && HDR_EXITX = HDR_STARTX+2 && HDR_EXITY = HDR_STARTX+3, error, "level_init: the header's four in a row"
        ldy #2*(HDR_EXITY-HDR_STARTX)   ; exity..startx, last to first: Y = 2 * the field
@hdr:   sty gridsh                 ; (gridsh is set below: a free counter till then)
        tya
        lsr
        tay
        lda LV_HDR+HDR_STARTX,y
        jsr @x8                    ; A/X = px lo/hi (Y clobbered)
        ldy gridsh
        sta startx,y
        stx startx+1,y
        dey
        dey
        bpl @hdr
        lda LV_HDR+HDR_NOBJ
        sta nobj
        lda maplw
        sec
        sbc #BIN_TILESHIFT         ; the grid's width: a cell is 8 tiles
        sta gridsh
        ldx #MAPROWS-1             ; the map's row addresses, for the map queries
@mrow:  txa                        ; (rows past the map's are never read)
        jsr map_row                ; X kept
        lda map_ptr
        sta MROWL,x
        lda map_ptr+1
        sta MROWH,x
        dex
        bpl @mrow
        lda #WINPX/2               ; the camera starts centred; the lookahead eases in
        sta cam_off
        ; clear object state, then grid
        tya                        ; A = 0: map_row left Y = 0 (the last @mrow pass)
        sta bin_ok                 ; the cached object list belongs to the old level
        sta mok                    ; and the map memo to its map
        sta dxl                    ; (and a level's start is no move to sweep)
        sta dyl
        sta star_clk               ; the stars' clock: every phase from the level's start
        sta stars
        sta bent
  .assert <O_STAMP = 0, error, "level_init's clear: O_STAMP must be page aligned"
        sta t16                    ; t16 = O_STAMP: ten pages through (t16),y
        ldx #>O_STAMP              ; (t16 is free: @ol sets it before any read)
        stx t16+1
        ldx #OBJCLR_PAGES
:       sta (t16),y
        iny
        bne :-
        inc t16+1
        dex
        bne :-
        dex                        ; X = $FF: the stamp loop left X = 0
        txa                        ; A = $FF = GRID_NONE: every cell empty
  .assert GRID_NONE = $FF, error, "level_init fills the grid with X's $FF"
:       sta LV_GRID-GRIDN,x        ; X = $FF..$80: LV_GRID+127 down to +0
        dex
        bmi :-
        ; objects, last to first
        ldy nobj
        jmp @nextobj+2             ; to the loop's beq @objdone (ldy obj is 2 bytes: obj is zero page); Z is ldy nobj's
:
@ol:    dey
        sty obj
        ; entry pointer = LV_OBJS + obj*OBJ_BYTES (6: 2obj + obj, doubled)
  .assert OBJ_BYTES = 6, error, "level_init: the entry's address is obj * 6 by shifts and an add"
        lda #(>LV_OBJS) >> 2       ; t16+1 seed: the two rols make it (>LV_OBJS) & $FC
        sta t16+1
        tya
        asl                        ; A = lo(2obj), C = obj.7
        rol t16+1                  ; C = 0: the seed is < $40
        adc obj                    ; A = lo(3obj), C = its carry (obj = Y, sty above)
        bcc @o3
        inc t16+1                  ; t16+1 = 2*seed + hi(3obj)
@o3:    asl                        ; A = lo(6obj), C = bit 8
        sta t16
        rol t16+1                  ; = 4*seed + hi(6obj); C = 0
  .assert ((>LV_OBJS) & 3) < 2, error, "LV_OBJS: the seed needs a second inc"
  .if (>LV_OBJS) & 1
        inc t16+1                  ; an odd page: the bit the seed's >> 2 dropped
  .endif
        ldazx t16                  ; lda (t16), Y kept: it is still obj (X is free
                                    ;  until jsr @x8: the Model B's (t16,x))
        sta otype
        sta O_TYPE,y               ; Y is still obj (sty obj at @ol; nothing since has touched Y)
        ldy #OBJ_BYTES-1           ; the record's bytes 5..1 into q5..q1 (adjacent in zero
@rd:    lda (t16),y                ;  page): q1 x tiles, q2 y tiles, q3..q5 e0..e2
        sta q1-1,y
        dey
        bne @rd                    ; A = byte 1: q1
        jsr @x8
        ldy obj
        sta O_XL,y
        txa
        sta O_XH,y
        lda q2
        jsr @x8
        ldy obj
        sta O_YL,y
        txa
        sta O_YH,y
        ; the state words O_AL..O_EH start at zero: the clear above covers every O_* array
  .assert 16*OBJ_MAX <= OBJCLR_PAGES*256, error, "level_init's clear must cover O_AL..O_EH"
        ; bounding box defaults: x0 = (x-1)>>3, y0 = y>>3, x1 = x>>3, y1 = (y+1)>>3
  .if BHW
        ldx q1                     ; max(q1-1, 0) through X (dead here: @box sets it)
        beq @g0
        dex
@g0:    txa
  .else
        lda q1
        beq :+                     ; submin0 1 open-coded: A=0 stays 0, else A-1
        dec a
  .endif
:       lsr
        lsr
        lsr
        sta gx0
        lda q1
        lsr
        lsr
        lsr
        sta gx1
        ldx q2                     ; X is dead here (@box sets it before use)
        txa
        lsr
        lsr
        lsr
        sta gy
        inx                        ; y+1, 8-bit as before
        txa
        lsr
        lsr
        lsr
        sta gy1
        ldy obj
        lda otype                  ; A = otype for the cmps below; X counts it down
        tax                        ;  (X is dead: the handlers and @box set it first)
  .assert OT_STAR = 0 && OT_TRAMP = 1 && OT_SNAKE = 2 && OT_MASK = 5 && OT_MUMMY = 6, error, "level_init's type ladder counts X down from otype"
        beq @t0                    ; OT_STAR
        dex
        beq @t1                    ; OT_TRAMP
        dex
        beq @t256a                 ; OT_SNAKE
        dex
        dex
        dex
        cpx #OT_MUMMY-OT_MASK+1    ; OT_MASK, OT_MUMMY: X = 0, 1 (3, 4 wrap to $FE, $FF)
        bcs :+
@t256a: jmp @t256
:       cmp #OT_RSNAKE
        bne :+
        jmp @t3
:       cmp #OT_BAT
        bne :+
        jmp @t4
:
        cmp #OT_FLAME
        bne :+
        jmp @t9
:
        cmp #OT_VANISH
        bne :+
        jmp @t11
:
        cmp #OT_SWITCH
        bne :+
        jmp @t12
:
        jmp @t10                   ; OT_SPIKE, OT_POWERUP: defaults, and e0 into E
@t0:    jsr rnd                    ; (drawn as ever, so the enemies' draws follow as they were)
        lda q5                     ; e2: its phase in the spin, the packer's (balanced
        sta O_AL,y                 ;  over the stars a screen shows at once)
        inc stars
        lda gy                     ; the prologue already left q2>>3 in gy
        sta gy1
        lda q2
        beq :+
        deca                       ; A-1; the carry is dead (lsr follows)
:       lsr
        lsr
        lsr
        sta gy
        jmp @t10                   ; e0 (box class: 0 none/1 cyan/2 black), e1 (an enemy's range covers it) into E
@t1:    lda O_XL,y
        ora #TILEPX/2              ; a trampoline stands at 8x + 4: x*8 has bit 2 clear,
        sta O_XL,y                 ;  so the +4 cannot carry into O_XH
        lda q1
        submin0 2
        lsr
        lsr
        lsr
        sta gx0
        lda q1
        inca                       ; A+1; the carry is dead (lsr follows)
        lsr
        lsr
        lsr
        sta gx1
        lda gy1
        sta gy
        jmp @t10                   ; e0 = its rest state's baked box id (0: none), e1 = an enemy's range covers it (assets.py): into E as for a star
@t256:  lda q3
        jsr @x8                    ; A = lo(q3*8), X = q3>>5 (Y clobbered)
        ldy obj
        sta O_AL,y
        txa
        sta O_AH,y
        jmp @g1                    ; gx1 = (q1 + q3)>>3: @t4's tail, then @box
@t3:    lda q2
        submin0 4
        lsr
        lsr
        lsr
        sta gy
        jmp @box
@rm:    ora #1                     ; A+1 for mod16: the low nibble is clear, so no carry
        sta t16b
        jsr rnd                    ; t16 = rnd16 & $0FFF, then t16 mod t16b
        sta t16
        jsr rnd
        and #$0F
        sta t16+1
        jmp mod16                  ; (it returns C = 0: bcc -> rts)
@t4:    lda q3
        lsr
        lsr
        lsr
        lsr
        sta O_AH,y
        sta t16b+1
        lda q3
        asl
        asl
        asl
        asl
        sta O_AL,y
        ; C = rnd % (A+1) ; D = rnd % (B+1)  (A,B < 4096) -> use rnd16 & mask then reduce
        jsr @rm
        lda t16
        sta O_CL,y
        lda t16+1
        sta O_CH,y
        lda q4
        lsr
        lsr
        lsr
        lsr
        sta O_BH,y
        sta t16b+1
        lda q4
        asl
        asl
        asl
        asl
        sta O_BL,y
        jsr @rm                    ; B+1, likewise
        lda t16
        sta O_DL,y
        lda t16+1
        sta O_DH,y
        lda q2
        beq :+                     ; submin0 1 specialised: max(q2-1, 0)
        sbc #0                     ; C = 0 from mod16's exit (bcc -> rts): A-1
:       lsr
        lsr
        lsr
        sta gy
        lda q2
        clc
        adc q4
        lsr
        lsr
        lsr
        sta gy1
@g1:    lda q1                     ; @t256 joins here
        clc
        adc q3
        lsr
        lsr
        lsr
        sta gx1
        bpl @box                   ; N = 0 after lsr
@t11:   lda gy
@gy1:   sta gy1
        bpl @box                   ; gy = q2>>3 < 32: N = 0
@t9:    lda q2
        submin0 2
        lsr
        lsr
        lsr
        ldx gy                     ; the prologue left q2>>3 in gy: that is gy1
        sta gy
        txa                        ; X is dead: @bx loads it
        bpl @gy1                   ; gy was q2>>3 < 32: N = 0
@t12:   lda q3
        sta O_AL,y
        lda q4
        sta O_BL,y
        lda q5
        sta O_CL,y
@t10:   lda q3                     ; e0, e1: a powerup's baked box id and its "an
        sta O_EL,y                 ;  enemy can reach it" (assets.py); the spike and
        lda q4                     ;  the switch (by @t12) never read E
        sta O_EH,y
@box:                              ; insert into grid cells gx0..gx1 x gy..gy1
        ; gy <= gy1 for every object of the 16 levels (no wrap: maps are <= 128 tiles
        ;  high, and the type 4 extents keep q2+q4 < 256): at least one grid row
@bx:    lda gx0                    ; per grid row: gx = gx0, then
        sta gx                     ; cell = gx + (gy << gridsh): the gx loop below
        lda gy                     ; steps the cell index with inx instead of reshifting
        ldx gridsh                 ; >= 2: every map is >= 256 px wide (maplw >= 5)
:       asl
        dex
        bne :-
:       clc
        adc gx
        tax
@cell:  ldy bent
        lda obj
        sta LV_BOBJ,y
        lda LV_GRID,x
        sta LV_BNEXT,y
        tya
        sta LV_GRID,x
        inc bent
        inx                        ; the next cell (X and gx are dead past the row: @bx, @ol
        lda gx                     ;  and the bin walk reload them)
        inc gx
        cmp gx1                    ; the cell just filled was gx1: the row is done
        bne @cell
:       inc gy
        lda gy1                    ; C set <=> gy <= gy1: another grid row
        cmp gy
        bcs @bx
@nextobj:
        ldy obj
        beq @objdone
        jmp @ol
@objdone:
        ; player state
        ldx #4                     ; px, py = startx, starty; vx, vy, anim = 0 (Y = 0 on
@ps:    lda startx,x               ;  both ways in: ldy nobj / ldy obj).  X = 4 copies
        sta px,x                   ;  exitx into vx and clears anim; X = 0 and 1 clear
        sty vx,x                   ;  vx again after
        dex
        bpl @ps
        mov16 ev_frame, frame
        sty facing
        sty running
        sty firing
        sty bactive
        sty exiting
        sty frame
        sty frame+1
        iny                        ; Y = 1
        sty hurt
        sty control
        rts
; A = tiles -> A/X = px lo/hi
@x8:    tay
        lsr
        lsr
        lsr
        lsr
        lsr
        tax
        tya
        asl
        asl
        asl
        rts

; t16 = t16 mod t16b (unsigned 16 bit, t16 < 4096, t16b >= 1)
mod16:  lda t16
        sec
        sbc t16b
        tax
        lda t16+1
        sbc t16b+1
        bcc :+
        sta t16+1
        stx t16
        bcs mod16                  ; C = 1: the bcc above was not taken
:       rts

; ============================================================================
; Per frame update: one step, at twice the original's rates -- every speed, gravity,
; friction, counter and timer moves two of its steps' worth (frame counts rendered
; frames, so its timers are halved).  Fills the sprite list; sets wx/wy.
; ============================================================================
game_frame:
        inc frame
        bne :+
        inc frame+1
:
  .if BHW
        lda #0                     ; bounce = 0 first: A = 0 serves the clock's wrap
        sta bounce
  .endif
        ldx star_clk               ; the stars' clock: a step a frame, 0..STARCLK-1
        inx
        cpx #STARCLK
        bcc @sc0
  .if BHW
        tax                        ; A = 0 (lda #0 above)
  .else
        ldx #0
  .endif
@sc0:   stx star_clk
  .if .not BHW
        stz bounce                 ; A is dead: lda health follows
  .endif
        ; ---- camera
        lda health
        beq @cam
        ; horizontal lookahead: ease the window's bias toward CAM_AHEAD_R (facing right,
        ; so Cleo sits 1/4 from the left and sees ahead) or CAM_AHEAD_L (facing left,
        ; 3/4) by two pixels a frame -- one character -- so she drifts to 3/4 of the way
        ; to her side of the screen without a visible snap.  (cam_off starts at WINPX/2
        ; and moves by 2: it stays even, as both targets are.)
        ldx #CAM_AHEAD_R
        lda facing                 ; 1 = left
        beq :+
        ldx #CAM_AHEAD_L
:       cpx cam_off
        beq @offok
        lda cam_off                ; (C is still cpx's)
        bcs @offup                 ; target > cam_off (cpx: C set when X >= cam_off)
        sbc #1                     ; C = 0: cam_off - 2
        bcs @offst                 ; C = 1: cam_off > target >= 40, no borrow
@offup: adc #1                     ; C = 1: cam_off + 2
@offst: sta cam_off
@offok: lda px
        sec
        sbc cam_off
        sta wx
        lda px+1
        sbc #0
        sta wx+1
        ; vertical: Cleo CAM_Y px from the window's top, one for one
        lda py
        sec
        sbc #CAM_Y
        sta wy
        lda py+1
        sbc #0
        sta wy+1
        jsr clamp_window
@cam:
        setbank BANK_LVL, BANK_LVL
        ; ---- bucket range (16-bit >> 6: a cell is BINPX = 64 px)
  .assert BINPX = 64, error, "the bucket range's shifts are a 64-px cell's"
        lda wx                     ; gx0 = wx >> 6 (wx < 16384): shift the top
        asl                        ; two bits of the low byte into the high byte
        tax                        ; X = wx<<1: cpx #$80 below gives C = wx bit 6
        lda wx+1
        rol
        cpx #$80
        rol
        sta gx0
        txa                        ; gx1 = (wx + 159) >> 6 = gx0 + 2 + ((wx & 63) >= 33):
        and #(BINPX-1)*2           ;  X is still wx<<1, so test (wx & 63)*2 >= 66
        cmp #(BINPX-((WINPX-1) & (BINPX-1)))*2 ;  (159 = 2*64 + 31; exact mod 256 for any 16-bit wx)
        lda gx0
        adc #(WINPX-1)/BINPX
        sta gx1
        lda wy                     ; gy = wy >> 6
        asl
        tax                        ; X = wy<<1: cpx #$80 below gives C = wy bit 6
        lda wy+1
        rol
        cpx #$80
        rol
        sta gy
        txa                        ; gy1 = (wy + VISLINES/2-1) >> 6, from gy: + its 64s,
        and #(BINPX-1)*2           ;  + 1 if wy's remainder carries (X is still wy<<1:
        cmp #(BINPX-((VISLINES/2-1) & (BINPX-1)))*2 ;  the remainder doubled)
        lda gy
        adc #(VISLINES/2-1)/BINPX
        sta gy1
        ; ---- the object list, cached between steps.
        ; LV_GRID/LV_BOBJ/LV_BNEXT and every O_TYPE are written only by level_init, so
        ; which objects the walk yields depends on nothing but the bucket rectangle --
        ; and that is unchanged on 77% of frames on L0 and 95% on L6.  So walk the grid
        ; only when the rectangle moves, and keep the deduped list to step through
        ; otherwise.  Order is preserved exactly: it sets the sprite draw order, which
        ; box stars depend on (see convert.py).
        lda gx0
        cmp bin_r
        bne @rebuild
        lda gx1                    ; bin_ok holds the list's gx1, or 0 for no list: gx1 is
        cmp bin_ok                 ;  never 0 (>= 2, wx >= 0), so this one test is both
        bne @rebuild
        lda gy
        cmp bin_r+2
        bne @rebuild
        lda gy1
        cmp bin_r+3
        bne @rebuild
        jmp @runlist               ; (the traversal between here and it is too far for
@rebuild:                          ;  a branch)
        lda gx0
        sta bin_r
        lda gx1
        sta bin_ok                 ; the list's gx1 (bin_r+1 is not used)
        lda gy
        sta bin_r+2
        lda gy1
        sta bin_r+3
        zero bin_nstar, bin_noth
@rows:  lda gx0
        sta gx
        lda gy                     ; row base = gy << gridsh, once per row
        ldx gridsh                 ; >= 2: every map is >= 256 px wide (maplw >= 5)
:       asl
        dex
        bne :-
        sta grow
@cells: lda grow
        clc
        adc gx
        tax
        lda LV_GRID,x
@walk:  cmp #GRID_NONE
        beq @cellend
        sta bent
        tax
        lda LV_BOBJ,x
        tay
        lda frame
        cmp O_STAMP,y
        beq @sk2                   ; already stamped: X is still bent, skip the reload
        sta O_STAMP,y
        lda O_TYPE,y               ; the walk only lists: @runlist processes, on a
        bne @apo                   ; rebuild as on a cached step, so the two take the
        ldx bin_nstar              ; same path through the handlers.  Stars go in their
        cpx #BINMAX                ; own list: the run then reaches ob_star without
        bcs @full                  ; reading the type or going through the table.
        tya
        sta LV_BINSTAR,x
        inc bin_nstar
        bne @skip                  ; bin_nstar was < BINMAX: never 0
@apo:   ldx bin_noth
        cpx #BINMAX
        bcs @full
        tya
        sta LV_BINOTH,x
        inc bin_noth
        bne @skip                  ; bin_noth was < BINMAX: never 0
@full:  stz bin_ok                 ; more objects than a list holds: process this one
        sty obj                    ; now and rebuild next step rather than lose it
        jsr process_object
        setbank BANK_LVL, BANK_LVL, 2
@skip:  ldx bent
@sk2:   lda LV_BNEXT,x
        jmp @walk
@cellend:
        lda gx
        cmp gx1
        beq :+
        inc gx
        bne @cells                 ; gx < gx1 <= 255: never 0
:       lda gy
        cmp gy1
        beq :+
        inc gy
        jmp @rows
:
@runlist:
        ; The stamp is written exactly as the traversal writes it.  It is only read when
        ; a list is rebuilt, but 'cmp frame' tests the low byte alone: let a stamp go 256
        ; steps stale and an object returning to range matches it and is skipped for
        ; the whole life of the cached list.
        ldx #0                     ; test at the bottom: bin_i kept in step with X
        cpx bin_nstar
        beq @rlo
@rls:   stx bin_i
        ldy LV_BINSTAR,x
        lda frame
        sta O_STAMP,y
        jsr po_star                ; no type read, no table, no obj (nothing a star
                                    ; runs reads it)
        ldx bin_i
        inx
        cpx bin_nstar
        bne @rls
@rlo:   ldx #0                     ; test at the bottom: bin_i kept in step with X
        cpx bin_noth
        beq @rldone
@rl2:   stx bin_i
        ldy LV_BINOTH,x
        lda frame
        sta O_STAMP,y
        sty obj
        jsr process_object
        ldx bin_i
        inx
        cpx bin_noth
        bne @rl2
@rldone:
        ; ---- after objects
        lda bounce
        beq :+
        stz vy                     ; vy = JUMP_VY (its low byte is 0)
        lda #>JUMP_VY
        sta vy+1
:                                  ; kill tile under player
        lda health                 ; dead: nothing hits.  (It was health <> 0 OR hurt = 0:
        beq @nokill                ;  a fall off the map leaves health 0 with hurt clear,
                                    ;  and a kill tile under her then took 0 to 255, alive.)
        mov16 qx, px               ; (alive, a kill tile hits through the invulnerability)
        clc
        lda py
        adc #CLEO_KILLY
        sta qy
        lda py+1
        adc #0                     ; A = qy+1, never stored: nothing reads it before it
        jsr get_tile_attr+2        ;  is next written; enter past get_tile_attr's lda qy+1
        bpl @nokill
        ; knockback by facing
        lda facing                 ; 0 or 1 (1 = left)
        lsr                        ; C = facing
        ror                        ; A = facing << 7: player_hit tests only hx+1's sign
        sta hx+1                   ; facing left -> hx negative -> vx = +KNOCK_VX
        jsr player_hit
@nokill:
        lda health
        beq player_dead            ; in range (player_hit is ~60 bytes)
        jmp player_update



; ============================================================================
; player_hit: knock back. hx = relative x of the enemy (sign used)
; ============================================================================
player_hit:
        mov16 ev_frame, frame
        lda #1                     ; bar_touch, inlined
        sta bar_dirty
        sta hurt
  .if BHW
        lda #0                     ; one zero for three stores and vx+1 below
  .else
        dec a
  .endif
        sta control
        sta vx                     ; both knockback speeds and JUMP_VY have
        sta vy                     ; a zero low byte
  .assert <KNOCK_VX = 0 && <JUMP_VY = 0 && <TRAMP_VY = 0 && <BOOM_VX = 0, error, "the speeds' low bytes are 0: only their high bytes are stored"
        dec health                 ; Z: no health left
        beq :+                     ; A = 0: no knockback, vx+1 = 0
        lda #>KNOCK_VX
        bit hx+1
        bmi :+
        lda #>(-KNOCK_VX)          ; -768 is $FD00: the HIGH byte is the non-zero one
:       sta vx+1
        lda #>JUMP_VY
        sta vy+1
        lda #SFX_HIT
        sta sfx_req
        rts

; ============================================================================
; player dead: fall, then respawn
; ============================================================================
player_dead:
        ; vy and py: the original's two steps (fall2)
        jsr fall2
        clc                        ; py += dpx: fall2 leaves A = dpx, X = dpx+1
        adc py
        sta py
        txa
        adc py+1
        sta py+1
        ; if (frame - ev_frame) > RESPAWN_F -> respawn (the original's 60 steps;
        ; unsigned delta: wrap-safe)
        lda frame
        sec
        sbc ev_frame
        tax
        lda frame+1
        sbc ev_frame+1
        bne @respawn
        cpx #RESPAWN_F+1
        bcc @draw
@respawn:
        mov16 px, startx
        mov16 py, starty
        mov16 ev_frame, frame
        lda #HEALTH_MAX
        sta health
        zero vx, vx+1, vy, vy+1, anim, dxl, dyl   ; (a respawn is no move to sweep;
                                    ;  the Model B's one zero serves the three below too:
                                    ;  dec lives keeps A)
        dec lives
        bne :+
        inc exiting                ; 0 here (the loop leaves on nonzero): game over
        rts                        ; handled by caller (lives == 0)
:
        sta0 facing, running, firing   ; A = 0 still
        lda #1
        sta hurt
        sta control
        sta bar_dirty              ; bar_touch, inlined
@draw:  mov16 spx, px
        mov16 spy, py
        lda #SPR_CLEO_DEAD
        jmp add_sprite

; ---- the frame's vertical motion: one update a frame, its velocity and its move the
; original's two steps' exactly -- each its gravity, vy = (vy + GRAV) * 31 >> 5, then
; its move, (vy + 128) >> 8 (MAXDWY0 down at most) -- summed into dpx (MAXFALL down
; at most; X = dpx+1).  No position between them is kept: player_update makes the move
; against the map (the altitude, looked at again until the move is made), and the
; objects test the stretch it covered (dxl, dyl: csweep).  fall2: both with gravity;
; move2: a jump's or a stand's, the first without it and the second with it only if
; rising (the original's second step took @grav on vy < 0).  q5: the first move.
fall2:  jsr gravity
        jsr step1
        sta q5
        jmp move2g                 ; the second gravity and move: move2's rising tail
move2:  jsr step1
        sta q5
        bit vy+1
        bpl fstep2
move2g: jsr gravity
fstep2: jsr step1
        ldx #$FF                   ; X = dpx+1: $FF up, 0 down
        clc
        adc q5                     ; the two moves (-40..16: a byte, signed)
        bmi @st                    ; up
        inx
        cmp #MAXFALL+1
        bcc @st
        lda #MAXFALL
@st:    sta dpx
        stx dpx+1
        rts
; A = (vy + 128) >> 8, signed: a step's move, at most MAXDWY0 down
step1:  lda vy                     ; C = the carry out of vy low + 128
        cmp #$80
        lda vy+1
        adc #0
        bmi @r
        cmp #MAXDWY0+1
        bcc @r
        lda #MAXDWY0
@r:     rts

; vy = (vy + GRAV) * 31 >> 5: the original's step of gravity
gravity:
        sec                        ; GRAV*31 - vy is -(vy + GRAV) + GRAV*32, so its >> 5
        lda #<(GRAV*31)            ; is the original's -(vy + GRAV) >> 5 plus GRAV, and vy
        sbc vy                     ; plus it is (vy + GRAV) * 31 >> 5.  vy is -2048..2480
        sta t16                    ; (gravity's fixed point), so 2480 - vy is 0..4528:
        lda #>(GRAV*31)            ; positive, under 8192, its >> 5 a byte
        sbc vy+1                   ; A:t16 = 2480 - vy
        .repeat 3
        asl t16                    ; three left shifts: A = (2480 - vy) >> 5, 0..141
        rol a
        .endrepeat
        adc vy                     ; C = 0: bit 13 of 2480 - vy, shifted out last
        sta vy
        bcc @hi
        inc vy+1
@hi:    rts


; ============================================================================
; player alive update
; ============================================================================
player_update:
        ; alt = getAltitude(px, py+CLEO_FEET)
                                    ; qx = px already: the kill-tile test, the only way in, set it
        clc
        lda py
        adc #CLEO_FEET
        sta qy
        lda py+1
        adc #0
        sta qy+1
        jsr get_altitude
        sta alt
        ; start throw?
        bne @nothrow
        lda keys                   ; down first: rarely held here
        and #K_DOWN
        beq @nothrow
        lda firing
        bne @nothrow
        lda control
        beq @nothrow
        lda bactive
        bne @nothrow
        sta anim                   ; A = 0: bactive, just tested
        inc firing                 ; 0 -> 1: firing was tested zero above
@nothrow:
        lda px                     ; where her move starts (dxl, dyl: at @hdone)
        sta pxs
        lda py
        sta pys
        ; vertical velocity
        bmi16 vy, @grav
        lda alt
        beq :+
        bpl @grav
:       stz vy                     ; both arms zero it: JUMP_VY = $FB00, low byte zero
        ldx firing                 ; X, so A stays 0 (B: stz vy's lda #0)
        bne @stand
        lda control
        beq @stand
        lda keys
        and #(K_UP|K_FIRE)
        beq @stand
        lda #>JUMP_VY
        sta vy+1
        inx                        ; X = 1 = SFX_JUMP: firing, in X, tested 0 above
        stx sfx_req
        bne @move                  ; always: X = 1
@grav:  jsr fall2
        bne @mvd                   ; always: fstep2 returns Z = 0 (dex to $FF, cmp unequal, or lda #MAXFALL)
@stand:
  .if BHW
        sta vy+1                   ; A = 0 on every way in
  .else
        stz vy+1
  .endif
        lda #1
        sta control                ; and on into move2
@move:  jsr move2
@mvd:   txa                        ; X = dpx+1, 0 or $FF (fall2/move2)
        bpl @down
        clc                        ; up: py += dpx, dpx+1 = $FF
        lda py
        adc dpx
        sta py
        bcs @upl
        dec py+1
@upl:   clc                        ; qx = px still: get_altitude keeps it
        lda py
        adc #CLEO_FEET
        sta qy
        lda py+1
        adc #0
        sta qy+1
        jsr get_altitude
        sta alt
        bpl @vdone
        inc py
        bne @upl
        inc py+1
        bpl @upl                   ; py+1 < $7F
@dland: sta dpx                    ; alt 0: on the ground, dy = 0 (alt and py stand)
        beq @vdone                 ; always: A = 0
@dlp:                              ; (the ':' below kept: the anonymous count)
:       tax                        ; 0 < alt <= dy: the altitude looks a tile ahead
        clc                        ;  at most, and a frame's fall (12) can reach it --
        adc py                     ;  go alt, and look again from
        sta py                     ;  there (else she stops short, alt 0 in the air:
        bcc :+                     ;  the standing frame)
        inc py+1
:       lda dpx
        stx dpx
        sec
        sbc dpx
        sta dpx                    ; dy - alt
        clc                        ; qx = px still: get_altitude keeps it
        lda py
        adc #CLEO_FEET
        sta qy
        lda py+1
        adc #0
        sta qy+1
        jsr get_altitude
        sta alt
@down:  lda alt                    ; dy = min(dy, alt); dpx+1 = 0 here
        beq @dland
        cmp dpx
        beq @dlp
        bcc @dlp                   ; alt > dy (unsigned) falls on, C = 1
@dfit:  sbc dpx                    ; C = 1: cmp's no borrow
        sta alt
        clc                        ; py += dpx
        lda py
        adc dpx
        sta py
        bcc @vdone
        inc py+1
@vdone:
        sec                        ; fell: maph - py - CLEO_H < 0
        lda maph
        sbc py
        tay
        lda maph+1
        sbc py+1
        cpy #CLEO_H
        sbc #0
        bpl @push
@fell:  mov16 ev_frame, frame
        zero health, control, vx, vx+1
        jsr bar_touch
        lda #SFX_DIE
        sta sfx_req
@push:  clc                        ; qx = px still; qy = py + CLEO_FEET in one pass
        lda py
        adc #<CLEO_FEET
        sta qy
        lda py+1
        adc #>CLEO_FEET
        sta qy+1
        jsr get_tile_attr
        and #PUSH_MASK
        sec
        sbc #PUSH_BIAS
        sta q6                     ; push (-2..2, PUSH_NONE = none)
        ; friction
        ldx control                ; X, not A: A keeps q6 for the push test
        beq @nofric                ; (in reach: 126 bytes on)
:                                  ; (unreferenced: keeps the anonymous labels' count)
        ldx alt
        beq :+
        bpl @air
:
        cmp #PUSH_NONE             ; A = q6 (push), still
        beq @air
        ; ground: vx = vx*58>>6 + push*48 (two of the original's vx*61>>6 + push*24), as
        ; vx - ceil(3w/32) with w = vx - 512p: 3w = 3vx - 1536p, whose 32nds are 3vx's
        ; less 48p exactly (the push folded in; |3w| < 32768 as |vx| < 1820, |p| <= 2)
        asl                        ; A = q6 (push), still: 2p
        eor #$FF
        sec
        adc vx+1                   ; A = vx+1 - 2p: w's high byte (its low byte is vx's)
        sta t16+1
        lda vx
        asl
        tax                        ; X = 2*w low, C untouched by tax
        lda t16+1
        rol                        ; A = 2*w high
        tay
        txa
        clc
        adc vx
        sta t16                    ; t16 = 3w low (= 3vx low)
        ldx #0
        tya
        adc t16+1                  ; A = 3w high, N = its sign
        bpl :+
        dex
:       stx t16+1                  ; t16+1:A:t16 = 3w sign-extended to 24 bits
        asl t16                    ; three left shifts: t16+1:A = floor(3w/32)
        rol
        rol t16+1
        asl t16
        rol
        rol t16+1
        asl t16
        rol
        rol t16+1                  ; t16 = the dropped bits (3w & 31) << 3
        ldy #0
        cpy t16                    ; C = nothing dropped: floor == ceil
        eor #$FF
        adc vx                     ; vx + ~floor + C = vx - ceil(3w/32)
        sta vx
        lda vx+1
        sbc t16+1
        sta vx+1
:                                  ; (unreferenced: keeps the anonymous labels' count)
        jmp @nofric
@air:                              ; vx = vx*3>>3 (two of the original's vx*5>>3): asr3(3vx), and 3vx fits 16 bits
        lda vx
        asl
        tax                        ; X = 2vx low (X and Y are dead past @nofric)
        lda vx+1
        rol                        ; A = 2vx high
        tay
        txa
        clc
        adc vx
        sta vx                     ; 3vx low, straight into vx: no add16 at the end
        tya
        adc vx+1                   ; A = 3vx high (vx+1 not written yet)
        cmp #$80                   ; 3vx >> 3 signed: C = the sign (A >= $80), rolled in
        ror
        ror vx
        cmp #$80
        ror
        ror vx
        cmp #$80
        ror
        ror vx
        sta vx+1
@nofric:
        ; horizontal input
        lda control
        beq @norun
        lda keys
        and #(K_LEFT|K_RIGHT)
        beq @norun
        eor #(K_LEFT|K_RIGHT)      ; A = 2 left, 1 right; both held: A = 0, as on the
        beq @norun                 ; other two ways to @norun
        tax                        ; X = 2 left, 1 right: @acctab's index
        lsr                        ; A = 1 left, 0 right: the facing flag
        sta facing
        lda running
        ora firing
        bne :+
        sta anim                   ; A = running|firing = 0
:                                  ; accel = (alt > 0 || push == PUSH_NONE) ? ACC_AIR : ACC_GROUND:
        ; two of the original's 288 : 36, through its friction (each pairs with one:
        ; 480 with vx*3>>3, 72 with vx*58>>6), which hold the original's top speed,
        ; KNOCK_VX (768), exactly
        lda alt
        beq :+
        bpl @acc480
:       lda q6
        cmp #PUSH_NONE
        bne @acc72
@acc480:
        inx
        inx                        ; X = 4 left, 3 right: the 480 pair
@acc72: clc                        ; vx += the accel, negated for left: one add for both
        lda vx
        adc @acctab-1,x
        sta vx
        lda vx+1
        adc @acctab+3,x
        sta vx+1
        lda #1
        bne @norun                 ; Z = 0 from the load: running = 1
@acctab:                           ; by X-1: the ground's right, left, the air's right, left
        .byte <ACC_GROUND, <(-ACC_GROUND), <ACC_AIR, <(-ACC_AIR)
        .byte >ACC_GROUND, >(-ACC_GROUND), >ACC_AIR, >(-ACC_AIR)
@norun: sta running                ; A = 1 from the run, 0 on the three ways from above
@hmove:
        ; steps = ((vx + 128) >> 8) * 2: the frame's two ; dir = sign
        lda vx
        cmp #$80                   ; C = carry out of vx_lo + 128, without the clc
        lda vx+1
        adc #0                     ; A = high byte of vx + 128
        asl                        ; two steps' (|A| < 64)
        sta dpx
        beq @hdone                 ; dpx = 0: dpx+1 is dead after @hdone (vy_step rewrites dpx)
        and #$80
        beq :+
        lda #$FF
:       sta dpx+1                  ; qx = px and qy = py+16 already, set at @push
@hstep: bmi @hneg
        inc qx
        bne @hget
        inc qx+1
        bne @hget                  ; always: qx+1 <= 8 (px is inside the map, < 2048)
@hneg:  lda qx
        bne :+
        dec qx+1
:       dec qx
@hget:  jsr get_altitude
        bpl @hok                   ; N from get_altitude's closing sbc
        cmp #$FF
        bne @wall
@hok:   ldx qx                     ; px += dir: qx is px + dir already
        stx px                     ; (X is free: A still holds the altitude)
        ldx qx+1
        stx px+1
@hmoved:
        ; if a <= 1: py += a ; alt = 0 else alt = a   (a may be -1: step up a slope)
        tax                        ; N from the altitude
        bmi @stepn
        cmp #2
        bcs @alt
        adc py                     ; C is clear from the cmp: 0 or 1, addend high byte 0
        sta py
        bcc :+
        inc py+1
        bcs :+                     ; always: C = 1, the adc's carry
@stepn: clc                        ; negative: high byte of the addend is $FF
        adc py
        sta py
        bcs :+                     ; no borrow (255 times in 256): py+1 is unchanged
        dec py+1                   ; (C = 0: falls into the 0/1 case's zero)
:       lda #0                     ; alt = 0 (A is dead: @hnext reloads it)
@alt:   sta alt
@hnext:                            ; steps -= dir
        ldx dpx+1                  ; X holds the direction for @hl (X is dead here)
        bmi :+
        dec dpx
        bpl :++                    ; always: dpx was 1..$7F, so N is clear
:       inc dpx
:       beq @hdone                 ; Z survives from the inc/dec
@hl:    clc                        ; qx = px already: @hok set px to it
        lda py
        adc #CLEO_FEET
        sta qy
        lda py+1
        adc #0
        sta qy+1
        txa                        ; dpx+1, still in X: N for @hstep
        jmp @hstep
@wall:
        zero vx, vx+1              ; (A is dead: @hdone reloads)
@hdone: lda px                     ; dxl, dyl: her move this frame, all of it (across;
        sec                        ;  down: the fall, a slope's step), the stretch the
        sbc pxs                    ;  objects' tests sweep next frame (csweep)
        sta dxl
        lda py
        sec
        sbc pys
        sta dyl
        ; animation counters: two steps a frame (every test is of an even count)
        inc anim
        inc anim
        lda anim                   ; anim in A for every test below; the flags come
        ldx firing                 ; through X (X is dead: written before any read below)
        beq @notfiring
        cmp #THROW_T1
        bne :+
        ; launch boomerang
        mov16 bx, px
        mov16 by, py
        zero bvx, bvy, bvy+1, bcnt
        lda #>BOOM_VX
        ldx facing                 ; X is dead (written before any read below)
        beq @bdir
        lda #>(-BOOM_VX)
@bdir:  sta bvx+1
        inc bactive                ; 0 here: a throw starts only with bactive clear
        lda #SFX_THROW
        sta sfx_req
        bne @animdone              ; always: SFX_THROW <> 0
:       cmp #THROW_END
        bne @animdone
        stz01 firing               ; 1 -> 0 (firing is only ever 0 or 1): Z = 1 on both
        beq @animdone              ;  (the Model B's dec; the cmp #THROW_END, which stz keeps)
@notfiring:
        ldx running                ; A = anim still
        beq :+
        cmp #RUN_ANIM
        bne @animdone
        beq @zanim                 ; always: Z = 1 from the cmp #RUN_ANIM
:       cmp #IDLE_ANIM
        bne @animdone
@zanim: stz anim
@animdone:
        ; timers
        lda hurt
        beq @afterhurt
        ; clear after (frame - ev_frame) > HURT_F (the original's 64 steps), using an
        ; unsigned delta so it works
        ; across the 16-bit frame wrap (a signed compare stuck the flashing state)
@hdelta: lda frame                 ; (also hurt = 0 with control = 0: from @afterhurt)
        sec
        sbc ev_frame
        tax                        ; hold the low byte of the delta in X
        lda frame+1
        sbc ev_frame+1
        bne @clrhurt               ; elapsed >= 256 -> clear
        cpx #HURT_F+1
        bcs @clrhurt
        lda control                ; hurt stands, so the delta is still in X and its
        bne @ctl                   ; high byte was zero: reuse it for the control
        cpx #CTRL_F                ; timer instead of subtracting frame-ev_frame twice
        bcc @noctl
        bcs @setctl                ; always
@afterhurt:
        lda control
        bne @ctl
        beq @hdelta                ; always: with hurt 0 the tests above decide the
                                    ; control alone (@clrhurt finds hurt 0 already)
@clrhurt:
        stz hurt
        lda control                ; the delta is past HURT_F, so past CTRL_F: set
        bne @ctl                   ; control if clear, as a second subtraction would
@setctl:
        inc control                ; control is 0 on every way in
        bne @ctl                   ; always: it is 1 now
@noctl:
        ldx #SPR_CLEO_MID          ; control lost: the mid-air frame, facing the knock
        lda vx+1
        bmi @spr2
        lda vx
        beq @spr2
        inx                        ; (+1: left)
@spr2:  txa                        ; the frame in A for @spr
        bne @spr                   ; always: SPR_CLEO_MID or +1
@ctl:   lda firing
        beq @nofire
        lda anim                   ; the throw's frames by its anim: 0..3 the first,
        cmp #THROW_T1              ;  4..5 the second, 6..9 the third, 10 up the second
        bcc @f14
        sbc #THROW_T2              ; C = 1: anim 6..9 -> 0..3, 4..5 wrap to $FE..$FF
        cmp #THROW_T3-THROW_T2
        lda #SPR_CLEO_THROW0+2     ; anim 4..5 or 10 up (lda keeps C)
        bcs @sprf
        lda #SPR_CLEO_THROW0+4     ; anim 6..9
        bne @sprf
@f14:   lda #SPR_CLEO_THROW0
        bne @sprf
@nofire:
        bmi16 vy, @jump
        lda alt
        beq @ground
        bpl @jump
@ground:
        lda anim
        ldx running                ; X dead: @spr keeps the frame in A (or tax)
        beq @standing
        lsr
        and #$FE                   ; (anim >> 2) << 1 with one shift, not three: the
        .assert RUN_ANIM = 16 && SPR_CLEO_RUN0 = 0, error, "the run's frame is (anim / 4) * 2 from id 0"
        bpl @sprf                  ;  run's four frame pairs; N=0: lsr cleared bit 7
@standing:
        cmp #BLINK0
        bcc @s8
        sbc #BLINK1                ; C = 1: anim 109..112 -> 0..3, 93..108 wrap to $E8..$FF
        cmp #BLINK_LEN
        lda #SPR_CLEO_IDLE1        ; anim 93..108 or 113 up (lda keeps C)
        bcs @sprf
        lda #SPR_CLEO_IDLE2        ; anim 109..112
        bne @sprf
@s8:    lda #SPR_CLEO_STAND
        bne @sprf
@jump:  bpl @jpos                  ; N = vy's sign both ways in (bit vy+1 / lda alt > 0)
        lda vy                     ; vy < 0: vy <= -JUMP_VYT is vy < -(JUMP_VYT-1) unsigned
        cmp #<(-(JUMP_VYT-1))
        lda vy+1
        sbc #>(-(JUMP_VYT-1))
        lda #SPR_CLEO_JUMP         ; (lda keeps C)
        bcc @sprf
@j22:   lda #SPR_CLEO_MID
        bne @sprf
@jpos:  lda vy                     ; vy >= 0: vy >= JUMP_VYT unsigned
        cmp #<JUMP_VYT
        lda vy+1
        sbc #>JUMP_VYT
        bcc @j22
        lda #SPR_CLEO_FALL
@sprf:  ora facing
@spr:   ldy hurt                   ; the frame stays in A (Y is dead: see below)
        beq @drawp
        tax                        ; flashing: hold the frame in X for the test
        lda frame
        and #1
        bne @boom
        txa
@drawp: ldy px                     ; Y, not A: A holds the frame for add_sprite
        sty spx
        ldy px+1
        sty spx+1
        ldy py
        sty spy
        ldy py+1
        sty spy+1
        jsr add_sprite
@boom:                             ; ---- boomerang: one flight step a frame.  Its move is made 8 px at most at a
        ; time, stopping in the first solid, so it cannot fly through a wall; the catch,
        ; like the objects' hits (bsweep), tests the box between where it was and where
        ; it is -- no position between a frame's ends is tested.
        lda #0
        sta bdx                    ; its move this frame (none unless it flies)
        sta bdy
        lda bactive
        bne :+
        jmp @bdone
:       lda bcnt
        cmp #BCNT_HIT
        bcc @bfly
        jmp @bcount                ; hit or stopped: it no longer flies
@bfly:  jsr brel                   ; the pull toward Cleo
        ldx #0                     ; the two axes' velocities, and their moves
        jsr bstep
        sta bmx
        ldx #2
        jsr bstep
        sta bmy
@bm:    lda bmx                    ; a part of the move: 8 px at most each way
        jsr clamp8
        tax
        eor #$FF                   ; bmx -= it
        sec
        adc bmx
        sta bmx
        txa
        clc
        adc bdx
        sta bdx
        txa
        ldx #0
        jsr bmove                  ; bx += it, and qx = bx
        lda bmy
        jsr clamp8
        tax
        eor #$FF
        sec
        adc bmy
        sta bmy
        txa
        clc
        adc bdy
        sta bdy
        txa
        ldx #2
        jsr bmove                  ; by += it, and qy = by
        jsr get_altitude           ; in a solid: it stops there
        bpl :+
        lda #BCNT_HIT
        sta bcnt
        bne @bcount                ; always
:       lda bmx
        ora bmy
        bne @bm
@bcount: lda bcnt                  ; two counts a frame: in flight 0, 2, 4, 6 and round
        clc                        ;  again (its spin); hit or stopped, from BCNT_HIT to
        adc #2                     ;  BCNT_GONE, gone
        cmp #BCNT_HIT
        bne :+
        lda #0
:       sta bcnt
        cmp #BCNT_GONE
        bne :+
        lda #0
        sta bactive
        beq @bdone                 ; always
:       jsr brel                   ; caught?  The box it crossed meets Cleo's: rx, ry
        ldx #RQ_BOOM_STAR          ;  in -7..7 (a star's -8..8 band, open)
        jsr bsweep
        bcc @bdraw
        stz01 bactive              ; bactive is 1 here (0/1 flag, nonzero on entry)
@bdraw: lda bactive
        beq @bdone
        mov16 spx, bx
        mov16 spy, by
        lda bcnt
        clc
        adc #2*SPR_BOOM0
        lsr                        ; (bcnt + 54) >> 1 = bcnt/2 + SPR_BOOM0: its 7 frames
        jsr add_sprite
@bdone:
        ; ---- exit reached?
        lda px                     ; inside the exit box is 0 <= px-exitx < EXIT_W and
        sec                        ; 0 <= py-exity < EXIT_H: one 16-bit subtract each,
        sbc exitx                  ; high byte zero (so the difference is 0..255)
        tax                        ; and low byte under the width
        lda px+1
        sbc exitx+1
        bne @noexit
        cpx #EXIT_W
        bcs @noexit
        lda py
        sec
        sbc exity
        tax
        lda py+1
        sbc exity+1
        bne @noexit
        cpx #EXIT_H
        bcs @noexit
        inc exiting                ; 0 here in play: the loop leaves on any nonzero
@noexit:
        rts


; ============================================================================
; Object processing.  Y = object index (obj).  Every type shares the prologue --
; spx/spy (where it draws) and rx/ry (relative to Cleo) -- then goes to its entry in
; @tab.  The handlers work on the object's arrays in place (O_AL..O_EH,y), with Y the
; index -- reloaded from obj after anything that changes it (add_score and bar_touch,
; player_hit, a handler's own scratch) -- and stage into zero page only what they
; use hard (the bat's velocity, for its move and chase).  The vanishing platform and
; the switch, rare and busy with Y over the map, keep wrappers (os_*) that copy in
; and back just the fields they touch.  ox/oy: spx/spy's copies, for those that
; read the position after moving spx/spy.
; ============================================================================
process_object:
  .if ::BHW
        ldx O_TYPE,y               ; X = otype, the dispatch index (split tables)
        stx otype
  .else
        lda O_TYPE,y
        sta otype
        asl                        ; X = otype*2, the dispatch index
        tax
  .endif
        lda O_XL,y                 ; rx/ry = object relative to the player
        sta spx                    ; spx/spy = where it draws: sta touches no flags,
        sec                        ; so the source byte can be banked on the way past
        sbc px
        sta rx
        lda O_XH,y
        sta spx+1                  ; sta touches no flags, so C survives for the sbc
        sbc px+1
        sta rx+1
        lda O_YL,y
        sta spy
        sec
        sbc py
        sta ry
        lda O_YH,y
        sta spy+1
        sbc py+1
        sta ry+1
@call:                             ; tail dispatch: the handler returns to our caller
  .if ::BHW                        ; jmp (abs,x) by hand, through jv (the 6502 has no
        lda @tlo,x                 ;  such form); A is clobbered: every handler loads it first
        sta jv
        lda @thi,x
        sta jv+1
        jmp (jv)
@tlo:   .lobytes ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .lobytes ob_spike, ob_none, ob_flame, ob_powerup, os_vanish, os_switch
@thi:   .hibytes ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .hibytes ob_spike, ob_none, ob_flame, ob_powerup, os_vanish, os_switch
  .else
        jmp (@tab,x)
@tab:   .word ob_star, ob_tramp, ob_snake, ob_rsnake, ob_bat, ob_walker, ob_walker
        .word ob_spike, ob_none, ob_flame, ob_powerup, os_vanish, os_switch
  .endif

; ---- the staged types' wrappers.  oin f, field: the object's field into zero page
; (fa..fe from O_AL..O_EH); oout the other way; Y = obj throughout the copies.
.macro oin f, lo
        lda lo,y
        sta f
.endmacro
.macro oout f, lo
        lda f
        sta lo,y
.endmacro
os_vanish:                         ; fe low, ox, oy
        oin fe, O_EL
        jsr os_oxy
        jsr ob_vanish              ; the frame's two steps: its count's map writes
        jsr ob_vanish              ;  fall on every fourth
        ldy obj
        oout fe, O_EL
        rts
os_switch:                         ; fa, fb, fc, fd: the low bytes
        oin fa, O_AL
        oin fb, O_BL
        oin fc, O_CL
        oin fd, O_DL
        jsr ob_switch
        ldy obj
                                    ; (fa..fc need no copy back: ob_switch only reads them)
        oout fd, O_DL
ob_none:                           ; (type 8, nothing to do: os_switch's rts)
        rts
os_oxy: lda spx                    ; ox, oy: the object's position (the prologue's spx,
        sta ox                     ; spy)
        lda spx+1
        sta ox+1
        lda spy
        sta oy
        lda spy+1
        sta oy+1
        rts

; range check: rx > lo && rx < hi && ry > lo2 && ry < hi2 ; X = offset of the limit
; quad in RNGTAB (RQ_*; limits stored + RQ_BIAS so the test is an unsigned byte compare
; on r ^ $80, after checking r fits in -128..127 - anything wider fails every limit
; anyway).  Returns carry set if inside. Clobbers A, X.
        .assert RQ_BIAS = $80, error, "in_range biases r by an eor: RQ_BIAS must be $80"
in_range:
        lda rx                     ; r fits -128..127 iff hi + (lo's sign) = 0 mod 256
        asl                        ; C = the low byte's sign
        lda rx+1
        adc #0                     ; $FF+1 and 0+0 are 0; nothing else is
        bne @nc                    ; (C = 0: adc #0 carries only into 0)
        lda rx
        eor #RQ_BIAS
        cmp RNGTAB,x
        bcc @nc
        beq @no                    ; rx > lo
        cmp RNGTAB+1,x
        bcs @no                    ; rx < hi
        lda ry
        asl
        lda ry+1
        adc #0
        bne @nc                    ; (C = 0, as above)
        lda ry
        eor #RQ_BIAS
        cmp RNGTAB+2,x
        bcc @nc
        beq @no
        cmp RNGTAB+3,x
        bcs @no
        sec
        rts
@no:    clc
@nc:    rts                        ; (C already 0)


;---- The swept tests: no position between a frame's ends is tested, only the
; stretch between them.  span: does r .. r + swd (r: A low, Y high, signed) meet
; (RNGTAB+o, RNGTAB+o+1) at X, open at both ends?  C = 1 if it does; X kept.
span:   sta swlo
        sty swhi
        jsr rbias                  ; one end, biased
        sta swa
        lda swd                    ; the other: r + swd
        ldy #0
        ora #0
        bpl :+
        dey
:       clc
        adc swlo
        pha
        tya
        adc swhi
        tay
        pla
        jsr rbias
        cmp swa                    ; A the high end, swa the low
        bcs :+
        ldy swa
        sta swa
        tya
:       cmp RNGTAB,x               ; high end > lo
        beq @no
        bcc @no
        lda swa
        cmp RNGTAB+1,x             ; low end < hi
        bcs @no
        sec
        rts
@no:    clc
        rts
; rbias: A = low, Y = high of a signed 16-bit r -> A = r clamped to -128..127, + 128
; (as in_range compares: a value past either end stays past every limit)
rbias:  cpy #$FF
        beq @n
        cpy #0
        bne @far
        cmp #$80                   ; 0..255: past 127 is 127
        bcc @in
@hi:    lda #$FF
        rts
@n:     cmp #$80                   ; -256..-1: under -128 is -128
        bcs @in
@lo:    lda #0
        rts
@far:   tya
        bmi @lo
        bpl @hi                    ; always
@in:    eor #RQ_BIAS
        rts
; csweep: Cleo's test, over her last move (dxl, dyl: where she was is r + d, rx/ry
; being the object less her): where she is, else the box between where she was and
; where she is meets the quad's -- the corner a diagonal move cuts, the 8-px trampoline
; band a 12-px fall would cross.  X and Y kept; C = 1 if inside.
csweep: jsr in_range               ; where she is: the hits, and quick
        bcs @r
        lda dxl
        ora dyl
        bne @go
@r:     rts                        ; (C = 0: she did not move)
@go:    sty swy
        lda dyl
        sta swe
        lda dxl
        bcc sweep                  ; always: C = 0 from in_range's miss
; bsweep: the boomerang's hit test, over its last move (bdx, bdy: where it was is
; r + bd, rx/ry being the object less the boomerang): the box between where it was and
; where it is meets the quad's.  X and Y kept; C = 1 if it does.
bsweep: sty swy
        lda bdy
        sta swe
        lda bdx
; sweep: rx over A, ry over swe (the move across and down), against quad X; Y back from
; swy.  C = 1 if both meet it.
sweep:  sta swd
        lda rx
        ldy rx+1
        jsr span
        bcc @n
        inx
        inx
        lda swe
        sta swd
        lda ry
        ldy ry+1
        jsr span
        dex
        dex
@n:     ldy swy
        rts

; bstep: the boomerang's flight on one axis, X = 0 (x) or 2 (y): bv -= bv/16 + bv/64
; + bv/128 (the original's two steps of 61/64 in one), bv += 4*r (r: rx or ry, the
; pull toward Cleo), A = the move, 2 * ((bv + 128) >> 8) (signed).  X kept.  (Against
; the original's two steps, thrown on the flat: 108 px out to its 105, back the same
; frame; its drift down settles at 10 px to its 9.)
bstep:  lda bvx+1,x                ; t16 = bv >> 4
        sta t16+1
        lda bvx,x
        ldy #4
:       pha
        lda t16+1
        cmp #$80
        ror a
        sta t16+1
        pla
        ror a
        dey
        bne :-
        sta t16
        ldy #3                     ; bv -= bv>>4, then >>6, then >>7
@d:     sec
        lda bvx,x
        sbc t16
        sta bvx,x
        lda bvx+1,x
        sbc t16+1
        sta bvx+1,x
        lda t16+1                  ; t16 >>= 2, then 1
        cmp #$80
        ror t16+1
        ror t16
        cpy #3
        bne :+
        lda t16+1
        cmp #$80
        ror t16+1
        ror t16
:       dey
        bne @d
        lda rx,x                   ; bv += 4*r
        sta t16
        lda rx+1,x
        asl t16
        rol a
        asl t16
        rol a
        sta t16+1
        clc
        lda bvx,x
        adc t16
        sta bvx,x
        lda bvx+1,x
        adc t16+1
        sta bvx+1,x
        lda bvx,x                  ; A = 2 * ((bv + 128) >> 8): the original's step's
        cmp #$80                   ;  move, twice -- as its two steps rounded it (a slow
        lda bvx+1,x                ;  pull stays put until it would move a pixel a step)
        adc #0
        asl a
        rts
; brel: rx = px - bx, ry = py - by + BOOM_REF_DY: Cleo less the boomerang (its pull,
; its catch)
brel:   sec
        lda px
        sbc bx
        sta rx
        lda px+1
        sbc bx+1
        sta rx+1
        sec
        lda py
        sbc by
        tax
        lda py+1
        sbc by+1
        sta ry+1
        txa
        clc
        adc #BOOM_REF_DY
        sta ry
        bcc :+
        inc ry+1
:       rts
; bmove: bx (X = 0) or by (X = 2) += A (signed), and qx/qy = it
bmove:  ldy #0
        ora #0
        bpl :+
        dey
:       clc
        adc bx,x
        sta bx,x
        sta qx,x
        tya
        adc bx+1,x
        sta bx+1,x
        sta qx+1,x
        rts
; clamp8: A (signed) to -BOOM_STEP..BOOM_STEP
clamp8: bmi @n
        cmp #BOOM_STEP+1
        bcc @r
        lda #BOOM_STEP
        rts
@n:     cmp #<-BOOM_STEP
        bcs @r
        lda #<-BOOM_STEP
@r:     rts

; boomerang-relative position: rx = spx - bx ; ry = spy - by  (spx/spy: the object's draw pos)
boom_rel:
        dif16 rx, spx, bx
        dif16 ry, spy, by
        rts
; boomerang hit test helper: bactive && bcnt < BCNT_HIT (in flight) -> carry set
boom_ready:
        lda bactive
        beq @no
        lda #BCNT_HIT-1
        cmp bcnt                   ; C = 7 >= bcnt = bcnt < 8
        rts
@no:    clc
        rts
add_score:                         ; A = points, BCD; X and Y kept
        sed                        ; (every interrupt clears D for itself: low.s, and the
        clc                        ;  65C02 by its own)
        adc score
        sta score
        lda score+1
        adc #0
        sta score+1
        lda score+2
        adc #0
        sta score+2
        cld
        jmp bar_touch

; ---------------------------------------------------------------- STAR (0)
; Cleo's two tests on a star -- the collect (RQ_STAR) and box_safe's (RQ_GUARD_STAR,
; grown by a frame's move) -- can only pass with rx in STARBAND_LO..STARBAND_HI (the
; guard's x limits, assets.inc).  So the star list's prologue (po_star) tests rx
; against that first, and outside it sets q2 (Cleo far): both tests are skipped, and
; ry, which only they read, is not worked out.  The boomerang's tests set rx and ry
; themselves (boom_rel), and clear q2, as does every other way in.
po_star:                           ; the star list's: Y = the star
        lda O_YL,y
        sta spy
        lda O_YH,y
        sta spy+1
        lda O_XL,y
        sta spx
        sec
        sbc px
        sta rx
        lda O_XH,y
        sta spx+1
        sbc px+1
        sta rx+1                   ; A = rx+1
        beq @pos
        cmp #$FF
        bne @far
        lda rx
        cmp #<STARBAND_LO
        bcs @near                  ; -29..-1
@far:   lda #1
        bne star_q2                ; always
@pos:   lda rx
        cmp #STARBAND_HI+1
        bcs @far                   ; 0..25 fall through
@near:  lda spy
        sec
        sbc py
        sta ry
        lda spy+1
        sbc py+1
        sta ry+1
ob_star:                           ; the object table's way in (the list full: rare):
        lda #0                     ;  rx and ry are process_object's, q2 = 0
star_q2:
        sta q2
ob_star1:
        lda O_CL,y
        beq @live
        ; ---- collected: the sparkle, its own count SPARKLE0..SPARKLE_END, a step a
        ; frame (the original's on even steps)
        lda O_AL,y
        cmp #SPARKLE_END           ; cap: a collected star's A must not wrap 8-bit
        bcs @anim                  ; (it would make the star reappear ~every 20s)
        adc #1                     ; C = 0: the bcs was not taken
        sta O_AL,y
        bcc @anim                  ; always: A <= SPARKLE_END
@live:  lda health
        beq @tryboom
        lda q2
        bne @tryboom               ; Cleo far: the collect cannot pass
        ldx #RQ_STAR
        jsr csweep
        bcs @collect
@tryboom:
        lda bactive
        beq @phase
        lda q2                     ; box_safe's Cleo test, now: boom_rel takes rx, ry
        bne @tbr                   ; (Cleo far: q2 says so already)
        ldx #RQ_GUARD_STAR
        jsr in_range               ; C = 1: she overlaps the box's guard band
        lda #2                     ; q2: 1 safe of her, $81 not (box_safe reads
        ror                        ;  only its sign and zero): C in at the top
:       sta q2                     ; (label kept unused: the anonymous count)
@tbr:   jsr boom_rel
        ldx #RQ_BOOM_STAR
        jsr bsweep
        bcc @phase
@collect:
        lda #SCORE_STAR            ; (1: O_CL = 1 says collected, and the score)
        sta O_CL,y
        dec stars
        jsr add_score              ; A = SCORE_STAR still; it ends in jmp bar_touch (Y kept)
        lda #SFX_STAR
        sta sfx_req
        lda #SPARKLE0              ; the sparkle's first step: its count, and A
        sta O_AL,y                 ;  for @anim
        bne @anim                  ; always
        ; ---- the spin: the level's star clock plus this star's phase (A, the
        ; packer's), mod STARCLK -- a star out of the bin window keeps its place in step
@phase: lda O_AL,y
        clc
        adc star_clk
        cmp #STARCLK
        bcc @spin                  ; A < STARCLK: the cmp #SPARKLE_END cannot pass
        sbc #STARCLK               ; C = 1: the bcc was not taken
@anim:  cmp #SPARKLE_END
        bcs @done
@spin:  lsr                        ; the frame: the spin's 6 (two steps each), then the sparkle's
        .assert STARCLK = 2*SPR_STAR_N && SPARKLE_END-SPARKLE0 = 2*SPR_SPARKLE_N && SPR_SPARKLE0 = SPR_STAR0+SPR_STAR_N, error, "a star's count halved is its frame, the sparkle's following the spin's"
        ldx O_EL,y                 ; the star's first box id (0: none -- its masked frames):
        beq @regc                  ; the sky's, black's, or its own baked six (assets.py)
        cmp #SPR_STAR_N            ; (carry unknown on the beq's path: forced there)
        bcs @reg                   ; C = 1 here, so @reg can assume it
        adc O_EL,y                 ; (C = 0: the bcs was not taken)
        ldx #RQ_GUARD_STAR         ; box_safe: Cleo's RNGTAB quad (the boomerang's is +RQ_BOOMOFF)
        bne box_safe               ; always: Z = 0 from the ldx
@regc:  sec
@reg:   adc #SPR_STAR0-1           ; C = 1: + SPR_STAR0
        jmp add_sprite
@done:  rts

; A box star is an opaque rectangle, so if the same frame is already on screen in the
; same place its pixels are still right -- unless something has been drawn through
; them.  The converter marks the stars an enemy's range covers; the rest can still be
; walked through by Cleo or the boomerang, which the collect check tests for with a
; band widened from "close enough to pick up" to "the rectangles touch".  Safe ones
; are drawn under an alias id BOXN above the real one.  The trampoline box is opaque
; the same way; both go through box_safe (at the end of ob_tramp).

; ---------------------------------------------------------------- TRAMPOLINE (1)
ob_tramp:                          ; A (O_AL) its spring's count: 2, 4 .. TRAMP_TOP, two steps a frame
        lda O_AL,y
        beq :+
        cmp #TRAMP_TOP-2           ; 2, 4, 6: + 2; 8: on to TRAMP_TOP, which is 0
        bcc @up
        lda #<(-3)                 ; C = 1: -3 + 2 + 1 wraps to 0
@up:    adc #2                     ; (C = 0 on the bcc's way: + 2)
        sta O_AL,y
:       lda health
        beq @draw
        ldx #RQ_TRAMP
        jsr csweep
        bcc @draw
        lda vy+1                   ; bmi16 vy and beq16 vy from one load
        bmi @draw
        ora vy
        beq @draw
        lda #2
        sta O_AL,y
        stz vy                     ; vy = TRAMP_VY (A dead: the lda below)
        lda #>TRAMP_VY
        sta vy+1
        lda spy                    ; on its surface, TRAMP_SINK px into the band, where
        sbc #TRAMP_SINK            ;  the original's step-a-time test found her: a frame's
                                    ;  two steps may carry her deeper or through it
                                    ;  (C = 1: csweep's, the bcc @draw not taken)
        sta py
        lda spy+1
        sbc #0
        sta py+1
        lda #SFX_JUMP
        sta sfx_req
@draw:  lda O_AL,y                 ; at rest (0): its rest state's baked box, if it has
        bne @bounce                ; one (assets.py: an id a trampoline; 0 for none)
        lda O_EL,y
        bne @rest
@bounce:                           ; (A = O_AL, or 0: frame 0; A even, so the carry in
                                    ;  cannot change A/4 -- no clc)
        adc #2+4*SPR_TRAMP0        ; (A + 2)/4 + SPR_TRAMP0 as one add: A <= 8, so no carry out
        lsr
        lsr                        ; bounce frame 0..2: the masked frames, SPR_TRAMP0 on
        jmp add_sprite
@rest:
        stzx q2                    ; (box_safe's Cleo test: rx, ry are hers; A live)
        ldx #RQ_GUARD_TRAMP        ; box_safe: Cleo's RNGTAB quad (the boomerang's is +RQ_BOOMOFF)
                                    ; (no clc: q2 = 0, so box_safe's in_range sets C first)
        ; fall through
; A = frame, X = the RNGTAB quad for Cleo (RQ_GUARD_STAR, RQ_GUARD_TRAMP, RQ_GUARD_PW;
; the boomerang's is X + RQ_BOOMOFF -- in_range and boom_rel leave X alone), C = 0,
; q2: 0 test Cleo (rx, ry are hers), 1 she is clear, $80 she is not (a star's
; prologue, or its boomerang test, which takes rx, ry).  Adds BOXN if nothing can draw
; through the box, then tail-calls add_sprite.
box_safe:
        sta q1
        lda O_EH,y                 ; an enemy's range covers it
        bne @no
        lda q2
        bmi @no                    ; Cleo overlaps (the star's boomerang test found)
        bne @cfar                  ; Cleo clear
        jsr in_range               ; Cleo overlaps its rectangle
        bcs @no
@cfar:  lda bactive
        bne @bt
        lda firing                 ; a throw that launches this frame (Cleo's step runs
        beq @yes                   ;  after the objects, anim 2 -> 4) starts from her
        lda anim                   ;  place: test it there (bx, by are dead until the
        eor #2                     ;  launch writes them; eor keeps C clear)
        bne @yes
        mov16 bx, px
        mov16 by, py
@bt:    jsr boom_rel
        txa
        ora #RQ_BOOMOFF            ; (the quads are 4-aligned: ora is the add)
        tax
        jsr in_range               ; the boomerang overlaps it
        bcs @no
@yes:   lda q1                     ; both ways in fall through a 'bcs @no' that was not
        adc #BOXN                  ; taken, so C is already clear here
        bcc @add                   ; always: id + BOXN < 256 (ids < BOXID0+BOXN)
@no:    lda q1
@add:   jmp add_sprite

; ---------------------------------------------------------------- GREEN SNAKE (2)
ob_snake:                          ; in place: Y = obj throughout (reloaded after
                                    ; add_score, whose bar_touch changes it).  Fields:
                                    ; A (O_AL/AH) the turn point, B (O_BL/BH) the offset,
                                    ; C (O_CL) the state, E (O_EL) the counter
        jsr @adv                   ; the frame's two steps of its state machine (the
        jsr @adv                   ;  turn is an exact B = A)
@coll:  clc                        ; rx and spx += B
        lda rx
        adc O_BL,y
        sta rx
        lda rx+1
        adc O_BH,y
        sta rx+1
        clc
        lda spx
        adc O_BL,y
        sta spx
        lda spx+1
        adc O_BH,y
        sta spx+1
        lda health
        beq @boom
        ldx #RQ_SNAKE
        jsr csweep
        bcc @boom
        lda O_CL,y
        cmp #SNK_DEAD
        bcs @boom
        cmp #2                     ; C = C >= 2 for both arms: no op below touches C
        lda ry+1
        bmi @nostomp
        ora ry
        beq @nostomp
        lda vy+1
        bmi @nostomp
        ora vy
        beq @nostomp
        ; stomped: the carry is still C >= 2 (nothing down to the bcs touches it)
        ldx O_CL,y                 ; C += 2 through X (C is 0..3 here): inx leaves the carry
        inx
        inx
        txa
        sta O_CL,y
        lda #1
        sta bounce
        bcs @ks                    ; 2 and 3 (now 4 and 5): 5 points
        bcc @kz                    ; always
@nostomp:
                                    ; C = C >= 2 still: the cmp #2 above the stomp tests
        bcs @boom
        lda hurt
        bne @boom
        mov16 hx, rx
        jsr player_hit
        ldy obj
@boom:  jsr boom_ready
        bcc @draw
        jsr boom_rel
        ldx #RQ_BOOM_SNAKE
        jsr bsweep
        bcc @draw
        lda O_CL,y
        cmp #SNK_DEAD
        bcs @draw
        lda bvx+1                  ; C = the boomerang's sign: state 4, or 5 moving left
        asl
        lda #SNK_DEAD/2
        rol
        sta O_CL,y
        lda #BCNT_HIT              ; bcnt = BCNT_HIT: boom_ready now fails, so the bne
        sta bcnt                   ;  @boom below goes straight on to @draw
@ks:    lda #SCORE_SNAKE           ; the two kills' shared tail (add_score keeps X and Y)
        jsr add_score
@kz:    lda #0
        sta O_EL,y
        lda #SFX_KILL
        sta sfx_req
        bne @boom                  ; always: A = SFX_KILL (5), Z = 0
@draw:  ldx O_BL,y                 ; B <= -SNAKE_FLYMAX: not drawn (as B < 1-SNAKE_FLYMAX, biased)
        cpx #<(1-SNAKE_FLYMAX)
        lda O_BH,y
        eor #$80
        sbc #(>(1-SNAKE_FLYMAX) ^ $80)
        bcc @done
        txa                        ; B - A against SNAKE_FLYMAX, as @c4 (C = 1: the bcc fell through)
        sbc O_AL,y
        tax
        lda O_BH,y
        sbc O_AH,y
        eor #$80
        cpx #<SNAKE_FLYMAX
        sbc #(>SNAKE_FLYMAX ^ $80)
        bcs @done
        lda O_CL,y
        cmp #2
        and #1                     ; and leaves C from the cmp: both arms want C & 1
        bcs @f6
        ldx O_EL,y                 ; E is 0..11 whenever C < 2; the 0..63 ladder @s23
        ora @ftab,x                ; runs only while C >= 2, and that takes @f6.  A is
        jmp add_sprite             ; C & 1: cmp/and/bcs/ldx leave it
@f6:    ora #SPR_SNAKE0+6          ; the base is even: ora is the add
        jmp add_sprite
@ftab:  .byte SPR_SNAKE0+0,SPR_SNAKE0+0,SPR_SNAKE0+0,SPR_SNAKE0+2,SPR_SNAKE0+2,SPR_SNAKE0+2
        .byte SPR_SNAKE0+4,SPR_SNAKE0+4,SPR_SNAKE0+4,SPR_SNAKE0+2,SPR_SNAKE0+2,SPR_SNAKE0+2
        .assert (SPR_SNAKE0 & 1) = 0, error, "ob_snake: the frame is added by ora: SPR_SNAKE0 must be even"
@done:  rts
@adv:   lda O_EL,y                 ; both arms step the counter
        clc
        adc #1
        sta O_EL,y
        ldx O_CL,y                 ; X is free here (the handler never reads it before a load)
        cpx #2
        bcs @s23
        cmp #SNAKE_E_WRAP
        beq @z                     ; E = 12: back to 0, a pause frame (no step)
        cmp #0                     ; the pause frames 0, 3, 6, 9: no step
        beq @ar
        cmp #SNAKE_PAUSE
        beq @ar
        cmp #2*SNAKE_PAUSE
        beq @ar
        cmp #3*SNAKE_PAUSE
        beq @ar
        clc                        ; C = 0 for both steps (txa, bne leave it)
        txa
        bne @c1
@c0:    lda O_BL,y                 ; B + 1
        adc #1
        sta O_BL,y
        bcc @c0c                   ; A = O_BL already (the sta keeps it)
        lda O_BH,y
        adc #0                     ; C = 1: + 1
        sta O_BH,y
        lda #0                     ; the low byte the carry left
@c0c:   cmp O_AL,y                 ; B = A: on to state 1
        bne @ar
        lda O_BH,y
        cmp O_AH,y
        bne @ar
        lda #1                     ; 0 -> 1, Z = 0
        bne @cset
@c1:    lda O_BL,y                 ; B - 1 (C = 0): a borrow leaves C = 0 and the low
        sbc #0                     ;  byte $FF, so B is not 0
        sta O_BL,y
        bcc @dech                  ; the borrow: @c5's tail takes it from the high byte
        bne @ar                    ; Z from the sbc
        lda O_BH,y                 ; B = 0: back to state 0
        bne @ar
@cset:  sta O_CL,y                 ; A = 0 (the bne above was not taken), or 1 from @c0
@ar:    rts
@s23:   cmp #SNAKE_DEAD_E
        bne @s45
        txa                        ; C & 1: back to state 0 or 1
        and #1
        sta O_CL,y
@z:     lda #0                     ; E = 0 is a pause frame: neither state steps on it
        sta O_EL,y
@rt:    rts
; states 2 and 3 do nothing; 4 and 5, the snake dying (X = O_CL)
@s45:   cpx #SNK_DEAD
        bcc @rt
        bne @c5                    ; carry set; Z: the state is 4
@c4:                               ; if B < A + SNAKE_FLYMAX: B += SNAKE_FLY
                                    ; C = 1 here (cpx / bne @c5): B - A against the
        lda O_BL,y                 ; immediate, as @c5 tests its own limit
        sbc O_AL,y
        tax
        lda O_BH,y
        sbc O_AH,y
        eor #$80
        cpx #<SNAKE_FLYMAX
        sbc #(>SNAKE_FLYMAX ^ $80)
        bcs @cj
        lda O_BL,y                 ; C = 0: the bcs @cj above was not taken
        adc #SNAKE_FLY
        sta O_BL,y
        bcc @cj
        lda O_BH,y
        adc #0                     ; C = 1: + 1
        sta O_BH,y
        rts
@c5:    ldx O_BL,y                 ; B <= -SNAKE_FLYMAX: to @coll (as B < 1-SNAKE_FLYMAX,
        cpx #<(1-SNAKE_FLYMAX)     ;  biased; X is dead after @adv, as @c4's tax assumes)
        lda O_BH,y
        eor #$80
        sbc #(>(1-SNAKE_FLYMAX) ^ $80)
        bcc @cj
        txa                        ; C = 1: the bcc was not taken
        sbc #SNAKE_FLY
        sta O_BL,y
        bcs @cj
@dech:  lda O_BH,y                 ; (and @c1's borrow, C = 0 there too)
        sbc #0                     ; C = 0: - 1
        sta O_BH,y
@cj:    rts

; ---------------------------------------------------------------- RED SNAKE in basket (3)
ob_rsnake:                         ; in place: Y = obj (reloaded after the calls and
                                    ; the scratch that change it).  Fields: A (O_AL) the
                                    ; dormancy counter, B (O_BL/BH) knocked (1 or 2: its
                                    ; side), C and D (O_CL/CH, O_DL/DH) the knock's flight.
                                    ; ox/oy: the position (it draws twice, moving spx/spy)
        lda spx
        sta ox
        lda spx+1
        sta ox+1
        lda spy
        sta oy
        lda spy+1
        sta oy+1
        lda O_BL,y                 ; B: 0, or 1 or 2 knocked (its high byte stays 0)
        beq @up
        jmp @knocked
@up:
        ; A is a dormancy counter running -127..RSNAKE_UP (CleoApp.run case 3: A++, and
        ; at 17 A = -(rnd&63)-64) -- the same idiom as the spike, and a signed byte
        ; holds it.
        lda O_AL,y                 ; (two steps a frame: past RSNAKE_UP as well as at it)
        clc
        adc #2
        sta O_AL,y
        bmi @norst
        cmp #RSNAKE_UP
        bcc @norst
        jsr rnd
        and #DORM_MASK
        eor #DORM_MASK
        clc
        adc #<(-(DORM_BASE+DORM_MASK))   ; 192-r: the byte form of -(r&63)-64
        sta O_AL,y
@norst:                            ; rise = (A*A >> 3) - 28 while the snake is up: baked (rise_tab).
        ; The reference skips when A <= -16 (CleoApp.run 2865: bipush -16, if_icmple),
        ; so it is up for A >= RSNAKE_SHOW (-15).
                                    ; A = the counter on both ways in
        eor #$80                   ; bias the signed byte so the compare can be unsigned
        cmp #<(RSNAKE_SHOW+$80)    ; -15 -> 113: at -16 the rise is +4 and the tall
        bcc @nowarm                ; frame's tail shows 4 px under the basket; at -15
                                    ; it is 0 and the snake is flush with its bottom
        and #RISE_N-1              ; (the bias is bit 7's: A & 31 is the counter's,
        tax                        ;  -15..16 -> 17..31, 0..16)
        lda rise_tab,x
        sta rise
        ldx #0                     ; its high byte: the sign
        ora #0
        bpl :+
        dex
:       stx rise+1
        lda #1                     ; snake visible
        bne @vis                   ; always: A = 1
@nowarm:
        lda #0
@vis:   sta q6
@boom:  jsr boom_ready
        bcc @hitp
        jsr boom_rel
        ldx #RQ_BOOM_RSNAKE
        jsr bsweep
        bcc @hitp
        lda #SCORE_RSNAKE
        jsr add_score
        ldy obj
        ldx #1
        bgt16 ox, px, @kx
        ldx #2
@kx:    txa                        ; B's high byte is already 0: @up runs only
        sta O_BL,y                 ; when B = 0, and nothing since has written it
        lda q6
        beq @kr
        lda rise                   ; C = the rise
        sta O_CL,y
        lda rise+1
        sta O_CH,y
@kr:    lda #BCNT_HIT
        sta bcnt
        lda #SFX_KILL
        sta sfx_req
@hitp:  dif16 rx, ox, px           ; afresh: the boomerang test above may leave rx
        lda q6                     ; boomerang-relative, and a boomerang passing the
        beq @draw                  ; snake while Cleo stood at its height would read
                                    ; as Cleo touching it
        lda health
        beq @draw
        sec                        ; ry = oy - py + rise, in one pass: the
        lda oy                     ; difference waits in X (low) and Y (high)
        sbc py
        tax
        lda oy+1
        sbc py+1
        tay
        clc
        txa
        adc rise
        sta ry
        tya
        adc rise+1
        sta ry+1
        ldy obj
        ldx #RQ_RSNAKE
        jsr csweep
        bcc @draw
        lda hurt
        bne @draw
        mov16 hx, rx
        jsr player_hit
        ldy obj
@draw:  lda q6                     ; rising, at the top, sinking: a frame pair each
        beq @basket
        ldx #SPR_RSNAKE0
        lda O_AL,y
        bmi @fr
        ldx #SPR_RSNAKE0+2
        cmp #0                     ; A still holds the counter; ldx did not touch it
        beq @fr
        ldx #SPR_RSNAKE0+4
@fr:    stx q1
        bge16 px, ox, @fr1
        inc q1                     ; (+1: facing left)
@fr1:   mov16 spy, oy
        add16 spy, rise            ; snake Y = oy + parabola
        lda q1
        jsr add_sprite
@basket:                           ; spx = ox still: ox was copied from it on entry
        mov16 spy, oy              ; and nothing since writes spx
        lda #SPR_BASKET
        jmp add_sprite
@knocked:                          ; (in place: C and D the flight)
        lda O_CL,y                 ; C > -256 (as C >= -255, biased), or done
        cmp #<(-255)
        lda O_CH,y
        eor #$80
        sbc #(>(-255) ^ $80)
        bcs @k1
        rts
@k1:    lda O_CL,y                 ; C -= RSNAKE_KNOCK: two steps' 16
        sec
        sbc #RSNAKE_KNOCK
        sta O_CL,y
        lda O_CH,y
        sbc #0
        sta O_CH,y
        lda O_BL,y
        cmp #1
        bne @kl
        lda O_DL,y                 ; D += RSNAKE_KNOCK
        clc
        adc #RSNAKE_KNOCK
        sta O_DL,y
        lda O_DH,y
        adc #0
        sta O_DH,y
        jmp @kf
@kl:    lda O_DL,y                 ; D -= RSNAKE_KNOCK
        sec
        sbc #RSNAKE_KNOCK
        sta O_DL,y
        lda O_DH,y
        sbc #0
        sta O_DH,y
@kf:    ldx #SPR_RSNAKE0+1         ; the rising pair, facing Cleo
        bgt16 ox, px, @kf1
        ldx #SPR_RSNAKE0
@kf1:   clc                        ; spy = oy + C in one pass (as spx = ox + D below)
        lda oy
        adc O_CL,y
        sta spy
        lda oy+1
        adc O_CH,y
        sta spy+1
        txa                        ; the frame is still in X
        jsr add_sprite             ; (Y kept)
        clc
        lda ox                     ; spx = ox + D: the pot flies too (@basket draws 60
        adc O_DL,y                 ;  at spx, which it otherwise takes to be ox)
        sta spx
        lda ox+1
        adc O_DH,y
        sta spx+1
        jmp @basket


; ---------------------------------------------------------------- BAT (4)
ob_bat:                            ; Y = obj.  C and D (O_CL/CH, O_DL/DH: the velocity)
                                    ; are staged into fc/fd for the move and the chase
                                    ; and put back straight after it; the rest -- A and
                                    ; B (the chase's limits), E (the counter), the
                                    ; falling -- in place, Y reloaded after the calls
                                    ; that change it (add_score, player_hit)
        lda O_EL,y
        cmp #BAT_DEAD_E
        bcc @alive
        jmp @dead
@alive: adc #2                     ; A = E < 8 and C = 0 from the bcc:
        and #BAT_FLAP_N-1          ; E = (E + 2) & 7: two steps
        sta O_EL,y
        lda O_DL,y
        sta fd
        lda O_DH,y
        sta fd+1
        lda O_CL,y
        sta fc
        lda O_CH,y
        sta fc+1
        ; rx += C>>1 ; ry += D>>1 (Y is scratch here)
                                    ; A = fc+1: X:Y = fc >> 1 (arithmetic); rx += it, spx += it
        cmp #$80
        ror a
        tax
        lda fc
        ror a
        tay
        clc
        adc rx
        sta rx
        txa
        adc rx+1
        sta rx+1
        clc
        tya
        adc spx
        sta spx
        txa
        adc spx+1
        sta spx+1
        lda fd+1                   ; and fd >> 1 into ry, spy
        cmp #$80
        ror a
        tax
        lda fd
        ror a
        tay
        clc
        adc ry
        sta ry
        txa
        adc ry+1
        sta ry+1
        clc
        tya
        adc spy
        sta spy
        txa
        adc spy+1
        sta spy+1
        ; chase: the frame's two steps of it (each limited)
        ldx #2                     ; the step count in X (the loop leaves X alone)
        ldy obj
@chase: bpl16 rx, @rxpos
        lda fc                     ; C >= A (bge16's signed compare): no faster
        cmp O_AL,y
        lda fc+1
        sbc O_AH,y
        bvc @cv
        eor #$80
@cv:    bpl @ydir
        inc fc
        bne @ydir
        inc fc+1
        bne @ydir                  ; fc + 1 = 0 only when fc became 0: @rxpos then finds
                                    ;  rx <> 0 (negative) and fc = 0, and goes to @ydir
@rxpos: beq16 rx, @ydir
        beq16 fc, @ydir
        ; (C >= 0 always: it stays in 0..A, so no sign test)
        lda fc
        bne :+
        dec fc+1
:       dec fc
@ydir:  bpl16 ry, @rypos
        lda fd                     ; D >= B: no faster
        cmp O_BL,y
        lda fd+1
        sbc O_BH,y
        bvc @dv2
        eor #$80
@dv2:   bpl @vput
        inc fd
        bne @vput
        inc fd+1
        bne @vput                  ; fd + 1 = 0 only when fd became 0: @rypos then finds
                                    ;  ry <> 0 (negative) and fd = 0, and goes to @vput
@rypos: beq16 ry, @vput
        lda fd+1                   ; (D >= 0 always: it stays in 0..B, so no sign test)
        ora fd
        beq @vput
        lda fd
        bne @dl
        dec fd+1
@dl:    dec fd
@vput:  dex
        bne @chase
        lda fc                     ; the velocity back
        sta O_CL,y
        lda fc+1
        sta O_CH,y
        lda fd
        sta O_DL,y
        lda fd+1
        sta O_DH,y
@boom:  jsr boom_ready
        bcc @player
        lda rx                     ; rx, ry (Cleo's) kept on the stack across the
        pha                        ;  boomerang's test: her tests below read them
        lda rx+1
        pha
        lda ry
        pha
        lda ry+1
        pha
        jsr boom_rel
        ldx #RQ_BOOM_BAT
        jsr bsweep
        pla                        ; pla/sta do not touch carry
        sta ry+1
        pla
        sta ry
        pla
        sta rx+1
        pla
        sta rx
        bcc @player
        lda #BCNT_HIT              ; bcnt first: the kill does not read it
        sta bcnt
@kill:  lda #SCORE_BAT
        jsr add_score
        ldy obj
        lda #<BATFALL_A0           ; A = the fall's first vy
        sta O_AL,y
        lda #>BATFALL_A0
        sta O_AH,y
        lda #BAT_DEAD_E
        sta O_EL,y
        lda #SFX_KILL
        sta sfx_req
        bne @draw                  ; SFX_KILL <> 0
@player:
        lda health
        beq @draw
        ldx #RQ_BAT_STOMP
        jsr csweep
        bcc @draw
        lda ry                     ; a stomp if she was above it where her last move
        clc                        ;  started (ry + dyl > BAT_STOMP_Y): a frame's fall
        adc dyl                    ;  (12) can take her from over it to level with it
        tax
        lda dyl                    ; (dyl's sign into the high byte)
        and #$80
        beq :+
        lda #$FF
:       adc ry+1
        bmi @nostomp
        bne :+
        cpx #BAT_STOMP_Y+1
        bcc @nostomp
:       lda vy+1                   ; bmi16 vy, then beq16 vy, from one load
        bmi @nostomp
        ora vy
        beq @nostomp
        lda #1                     ; bounce first: the kill does not read it
        sta bounce
        bne @kill                  ; A = 1
@nostomp:
        lda hurt
        bne @draw
        ldx #RQ_BAT
        jsr csweep
        bcc @draw
        mov16 hx, rx
        jsr player_hit
        ldy obj
@draw:  lda O_EL,y                 ; the flap's three frame pairs by E: 0..1 and 4..5 the
        cmp #BAT_FLAP_WIDE         ;  first, 2..3 the second, 6..7 the third (wide)
        and #2                     ; C: E >= 6 draws the third; else the first, or the
        ora #SPR_BAT0              ;  second for E 2..3 (SPR_BAT0 has bit 1 clear)
        .assert (SPR_BAT0 & 2) = 0, error, "ob_bat: the frame's ora needs SPR_BAT0's bit 1 clear"
        bcc @fr
        lda #SPR_BAT0+4
@fr:    sta q1
        bge16 px, spx, @wob        ; spx > px: one frame on
        inc q1
@wob:                              ; wobble: x += BAT_OFFSET[(s + obj*5) & 15] ; y += BAT_OFFSET[((5*s>>2) + obj*7) & 15],
        ; s = 2*frame: the original's step count
        lda frame
        asl
        sta t16b                   ; s (low byte: all the indices use)
        lda obj
        asl
        asl
        clc
        adc obj
        adc t16b
        and #BATOFF_N-1
        tax
        lda bat_off,x
        bpl @wx1                   ; spx += a signed byte, without building the word:
        dec spx+1                  ; pre-borrow the high byte when it is negative
@wx1:   clc
        adc spx
        sta spx
        bcc @wx2
        inc spx+1
@wx2:   lda t16b
        asl
        asl                        ; A = 5*s, low byte only: the high byte of 5*s is
                                    ; dead (the >>2 below shifts the low byte alone,
                                    ; no clc: s and 4s are even, so a carry in only sets
                                    ; bit 0, which the >>2 drops;
        adc t16b                   ; and only t16's low byte is used)
        lsr
        lsr
        sta t16
        lda obj
        asl
        asl
        asl                        ; 8*obj: mod 16 only bit 3 is left, so eor adds it
        eor t16
        sec
        sbc obj                    ; q + 8*obj - obj = q + 7*obj (mod 16)
        and #BATOFF_N-1
        tax
        lda bat_off,x
        bpl @wy1
        dec spy+1
@wy1:   clc
        adc spy
        sta spy
        bcc @wy2
        inc spy+1
@wy2:   lda q1
        jmp add_sprite
@dead:                             ; falling (in place)
        lda O_DL,y                 ; D - B's high byte: D >= B + 256 is that >= 1, signed
        cmp O_BL,y                 ; (B = 16*q4 <= 4080 and D -6..~4600 while falling:
        lda O_DH,y                 ;  no overflow, and the high byte stays -36..18)
        sbc O_BH,y
        cmp #1
        bpl @done
        clc                        ; A += 2*BAT_GRAV (two steps), the new low byte in X
        lda O_AL,y
        adc #2*BAT_GRAV
        sta O_AL,y
        tax
        lda O_AH,y
        adc #0
        sta O_AH,y                 ; want only the high byte of A + 128:
        cpx #$80                   ; C = carry out of A_lo + 128
        adc #0                     ; the step, signed
        ldx #0                     ; X = the step's sign extension (ldx leaves C)
        asl                        ; two (N its sign)
        bpl @dpos
        dex
@dpos:  clc                        ; D += it, sign extended
        adc O_DL,y
        sta O_DL,y
        txa
        adc O_DH,y
        sta O_DH,y
@fdok:                             ; A = O_DH,y: both ways in end on its sta
        cmp #$80                   ; spy += D >> 1 (arith)
        ror a
        tax                        ; the high half waits in X (dead: add_sprite loads it)
        lda O_DL,y
        ror a
        clc
        adc spy
        sta spy
        txa
        adc spy+1
        sta spy+1
        lda O_CH,y                 ; same again for C into spx
        cmp #$80
        ror a
        tax
        lda O_CL,y
        ror a
        clc
        adc spx
        sta spx
        txa
        adc spx+1
        sta spx+1
        bgt16 spx, px, @f66
        lda #SPR_BAT0+4            ; (falling: the wide pair, facing Cleo)
        bne @fgo                   ; always: Z = 0 from the lda
@f66:   lda #SPR_BAT0+5
@fgo:   jmp add_sprite
@done:  rts
bat_off: .byte 0,1,1,2,2,2,1,1,0,<-1,<-1,<-2,<-2,<-2,<-1,<-1
        .assert * - bat_off = BATOFF_N, error, "bat_off: BATOFF_N entries"

; ---------------------------------------------------------------- MASK (5) / MUMMY (6)
ob_walker:                         ; in place: Y = obj throughout (reloaded after
                                    ; player_hit).  Fields: A (O_AL/AH) the far end, B
                                    ; (O_BL/BH) the offset, C (O_CL) the direction, E
                                    ; (O_EL) the counter
        lda O_EL,y                 ; E + 2 (two steps), WALK_E_WRAP back to 0: E is even, 0..10
        cmp #WALK_E_WRAP-2
        bcc @e                     ; C = 0: E + 2
        lda #<(-3)                 ; C = 1 (E = 10): -3 + 2 + 1 = 0
@e:     adc #2
        sta O_EL,y
        lda O_CL,y                 ; the step is WALK_STEP, a frame's: the original's 1 and 2
        bne @left
        lda O_BL,y                 ; walking right.  B can be -1 coming in (the left
        sec                        ; path rests one past the near end), and the carry
        adc #WALK_STEP-1           ; out of the add is what clears its sign byte -- drop
        sta O_BL,y                 ; that and -1 + 3 becomes -254, not 2.  (sec: the + 1)
        bcc @r1
        lda #0                     ; the carry: B was -2 or -1 (high byte $FF), now 1
        sta O_BH,y                 ; or 2.  A = 0 is below A (48..192) as 1 or 2 is
@r1:    cmp O_AL,y                 ; past here B's high byte is 0 and B is 0..194, so
        bcc @coll                  ; the unsigned compare says what the signed 16-bit did
        lda #1                     ; C = 0 here (bne @left fell through): now 1
        bne @cset                  ; always: the store is @stop's
@left:  lda O_BL,y
        clc                        ; B - WALK_STEP: the step (C = 0 is the - 1)
        sbc #WALK_STEP-1
        sta O_BL,y
        beq @stop                  ; B reached 0 (a borrow never leaves zero: >= 254)
        bcs @coll                  ; no borrow, not zero: still walking
        lda #$FF                   ; borrow == B went negative: that IS the bmi16 test.
        sta O_BH,y                 ; B was 1 or 2 (high byte 0), so the high byte is $FF
@stop:  lda #0
@cset:  sta O_CL,y
@coll:  clc                        ; rx and spx += B
        lda rx
        adc O_BL,y
        sta rx
        lda rx+1
        adc O_BH,y
        sta rx+1
        clc
        lda spx
        adc O_BL,y
        sta spx
        lda spx+1
        adc O_BH,y
        sta spx+1
        lda health
        beq @boom
        ldx #RQ_WALKER
        jsr csweep
        bcc @boom
        lda hurt
        bne @boom
        mov16 hx, rx
        jsr player_hit
        ldy obj
@boom:  jsr boom_ready
        bcc @draw
        jsr boom_rel
        ldx #RQ_BOOM_WALKER
        jsr bsweep
        bcc @draw
        bit bvx+1
        bmi @bleft
        ; bvx > 0: if B < A: C = 0.  A is 48..192 (its high byte 0) and B -2..194,
        ; so B < A is B negative, or its low byte below A's
        lda O_BH,y
        bmi @bc0
        lda O_BL,y
        cmp O_AL,y
        bcs @bset
@bc0:   lda #0
        beq @bsc                   ; always
@bleft:                            ; bvx < 0: if B > 0: C = 1
        lda O_BH,y
        bmi @bset
        lda O_BL,y
        beq @bset
        lda #1
@bsc:   sta O_CL,y
@bset:  lda #BCNT_HIT
        sta bcnt
@draw:  lda O_BH,y                 ; standing frame at either end.  Past the sign test
        bmi @f8                    ; B's high byte is 0, so the rest is an 8-bit compare
        lda O_BL,y
        beq @f8
        cmp O_AL,y
        bcs @f8
        ldx O_EL,y                 ; E in X, so each arm can load its frame early: the
        cpx #WALK_FRAME_E          ;  walk's four frame pairs, one every WALK_FRAME_E of E
        bcc @f0
        cpx #2*WALK_FRAME_E
        bcc @f2
        cpx #3*WALK_FRAME_E
        lda #4
        bcc @fr                    ; C = 0: C + 4
        lda #6-1                   ; C = 1 (the cpx fell through): C + 6
@fr:    adc O_CL,y
@sp:    ldx otype                  ; the frame stays in A: no round trip through q1
        cpx #OT_MUMMY              ; otype is OT_MASK or OT_MUMMY (the walker's two table entries)
        bne @s5                    ; the mask: C = 0 from the cpx
        adc #SPR_MUMMY0-SPR_MASK0-1   ; the mummy: C = 1, so A + 9, and C = 0 again
@s5:    adc #SPR_MASK0
        jmp add_sprite
@f0:    lda O_CL,y                 ; C = 0: the bcc
        bcc @sp
@f2:    lda #2                     ; C = 0: the bcc
        bcc @fr
@f8:    lda #WALK_STAND_F
        bne @sp

; ---------------------------------------------------------------- SPIKE (7)
ob_spike:
        ; A is a dormancy counter running -127..SPIKE_UP (CleoApp.run case 7: A++, and
        ; at 24 A = -(rnd&63)-64).  That fits a signed byte exactly, so the byte IS the
        ; value and the high half was only ever its sign extension.  In place: O_AL, Y =
        ; obj (reloaded after player_hit).
        lda O_AL,y                 ; (two steps a frame: past SPIKE_UP as well as at it)
        clc
        adc #2
        sta O_AL,y
        bmi @nowrap
        cmp #SPIKE_UP
        bcc @nowrap
        jsr rnd
        and #DORM_MASK
        eor #DORM_MASK             ; 63-r, then +129, is 192-r: the byte form of
        clc                        ; -(r&63)-64, i.e. -64 down to -127
        adc #<(-(DORM_BASE+DORM_MASK))
        sta O_AL,y
@nowrap:
        ldx health                 ; A = the counter on both ways in, and ldx keeps it
        beq @draw
        cmp #SPIKE_OUT             ; unsigned: a dormant (negative) A is >= 8 too
        bcs @draw
        ; rx > -8 && rx < (A+1)*2 && ry > -24 && ry < 8: the quad's x limit is its
        ; height's
        asl                        ; A < 8 and C = 0 (bcs fell through): 2A, C = 0
        adc #2+RQ_BIAS             ; (fa+1)*2 biased
        sta RNGTAB+RQ_SPIKE+1
        ldx #RQ_SPIKE
        jsr csweep
        bcc @draw
        lda hurt
        bne @draw
        lda rx+1                   ; only hx+1 goes over: player_hit reads just its sign
        sta hx+1                   ;  and hx's low byte is read nowhere.  The original knocks
        ora rx                     ; Cleo right when rx <= 0 (CleoApp.run case 7: rx > 0 is
        bne @ph                    ; -768, else +768), player_hit only when hx < 0: level
        dec hx+1
@ph:    jsr player_hit             ; with the spike (rx = 0), hx = -256 says so
        ldy obj
@draw:  lda O_AL,y                 ; out: frames 0..7 up, then (23 - A)/2 down
        bmi @done
        cmp #SPIKE_OUT
        bcc @fu
        eor #$FF                   ; A (8..23), C = 1: 255-A+23+1 = 23-A, C = 1
        adc #SPIKE_UP-1
        lsr
        clc                        ; only the lsr can leave C set; bcc arrives with C=0
@fu:    adc #SPR_SPIKE0
        jmp add_sprite
@done:  rts

; ---------------------------------------------------------------- FLAME (9)
ob_flame:                          ; in place: E (O_EL) the frame, a step every other
        lda frame                  ;  frame (the original's every fourth step)
        lsr                        ; C = the frame's low bit; the lda keeps it
        lda O_EL,y
        bcs @f                     ; odd frame: C = 1, so the adc is E + SPR_FLAME0
        adc #1                     ; C = 0: the bcs fell through
        and #SPR_FLAME_N-1
        sta O_EL,y
        sec                        ; C = 1 for the shared adc, whatever the step left
@f:     adc #SPR_FLAME0-1
        jmp add_sprite

; ---------------------------------------------------------------- POWERUP (10)
ob_powerup:                        ; in place: A (O_AL) the pickup's progress; Y = obj
        lda O_AL,y                 ; (reloaded after bar_touch)
        bne @adv
        ldx health                 ; health below the full HEALTH_MAX only: 0 wraps to 255
        dex
        cpx #HEALTH_MAX-1
        bcs @draw
        ldx #RQ_POWERUP
        jsr csweep
        bcc @draw
        lda #HEALTH_MAX
        sta health
        jsr bar_touch              ; A = 1 on return and Y kept (lda #1 / sta bar_dirty)
        sta O_AL,y                 ; the pickup starts (O_AL was 0: bne @adv fell through)
        lda #SFX_POWER
        sta sfx_req
        bne @draw                  ; Z = 0: SFX_POWER is 6
@adv:   cmp #PICKUP_END
        bcs @done
        adc #2                     ; C = 0: the bcs was not taken; two steps
        sta O_AL,y
@draw:  lda O_AL,y
        lsr
        bne @pk                    ; picking up: its frames
        sta q2                     ; A = 0 (the bne fell through): box_safe tests Cleo
        lda O_EL,y                 ; at rest: its baked box (every powerup has one: the
        ldx #RQ_GUARD_PW           ;  full dither, its reds kept -- assets.py), kept still
                                    ;  as the stars' and trampolines' are (box_safe: rx, ry
                                    ;  are Cleo's; her band, the boomerang's +RQ_BOOMOFF)
        clc
        jmp box_safe
@pk:    cmp #SPR_PICKUP_N+1        ; A = 1..2: the pickup's frames; 3, gone
        bcs @done
        adc #SPR_PICKUP0-1
        jmp add_sprite
@done:  rts

; ---------------------------------------------------------------- VANISHING BLOCK (11)
ob_vanish:
        lda fe
        bne @count
        ; rx > -16 && rx <= 0 && ry == 16 && vy == 0
        ldx #RQ_VANISH
        jsr csweep
        bcc @ret
        lda vy
        ora vy+1
        bne @ret
        inc fe                     ; fe was 0: bne @count fell through
@ret:   rts
@count: inc fe
        lda fe
  .if ::BHW
        and #VANISH_EVERY-1        ; bitimm's save and restore of A are not needed:
        bne @ret                   ; A is reloaded
        lda fe
  .else
        bit #VANISH_EVERY-1
        bne @ret
  .endif
        cmp #VANISH_GONE
        bcc @half                  ; fe < 12: fe >> 1
        cmp #VANISH_BACK
        lda #VANISH_SOLID_F        ; lda keeps C from the cmp
        bcc @set
        lda #VANISH_END
        sbc fe                     ; carry is already set: bcc fell through
@half:  lsr
@set:   sta q1
        ; the tiles at (ox>>3, oy>>3) and one right: the frame's ids from the header
        mov16 qx, ox
        mov16 qy, oy
        jsr tilexy                 ; X = tile x, A = tile y
        sta q5                     ; tile y (q4/q5: gx/gy are the live grid-walk cursor)
        jsr map_tile               ; sets map_ptr, Y = tx; X kept, bank 7 back
        ldx q1
        lda LV_HDR+HDR_SPECIAL,x
        jsr map_put                ; X and Y kept
        iny
        lda LV_HDR+HDR_SPECIAL+1,x
        jsr map_put
        dey
        lda fe                     ; the count's wrap first (mark_dirty leaves fe
        eor #VANISH_END            ;  alone), so the marks can be the tail
        bne @mk                    ; A = 0 when fe = VANISH_END
        sta fe
@mk:    tya                        ; tile x
        ldx q5                     ; (falls into mark_pair; A, X, Y dead on return)

; mark tiles (A, X) and (A+1, X) dirty, in that order: the vanishing block's and the
; switch's pairs.  mark_dirty keeps its tmp = A, tmp2 = X.  A, X, Y clobbered.
mark_pair:
        ldy #0                     ; the map has changed: no map memo (get_altitude)
        sty mok                    ;  (Y is free: mark_dirty takes A and X)
        jsr mark_dirty
        ldx tmp
        inx
        txa
        ldx tmp2
        jmp mark_dirty

; ---------------------------------------------------------------- SWITCH (12)
ob_switch:
        lda fd
        bne @draw
        ldx #RQ_SWITCH
        jsr csweep
        bcc @draw
        lda #SCORE_SWITCH          ; (BCD)
        jsr add_score
        lda #SFX_POWER
        sta sfx_req
        ; copy map columns (A-2, A-1) -> (A, A+1) for rows B .. B+C-1
        lda fc
        beq @set
        sta q4
        lda fb
        sta q5                     ; row counter (q5: the grid-walk cursor must stay intact)
@rl:    ldx fa
        dex
        dex
        lda q5
        jsr map_tile               ; map_ptr = row, Y = X = fa-2, A = (row),fa-2
        iny
        iny
        jsr map_put                ; -> (row),fa
        dey
        jsr map_byte               ; A = (row),fa-1
        iny
        iny
        jsr map_put                ; -> (row),fa+1
        lda fa
        ldx q5
        jsr mark_pair              ; (row),fa and (row),fa+1
        inc q5
        dec q4
        bne @rl
@set:   inc fd                     ; fd = 0 here (bne @draw fell through): now 1
@draw:  lda fd
        clc
        adc #SPR_SWITCH0
        jmp add_sprite

; ============================================================================
; Status bar digits (drawn straight into the bar, from bank 7's packed digits)
; ============================================================================
        .segment "GAMECODE"         ; bank 7, with the digit art
; draw digit A at bar pixel column X (even), digit slot Y (0..HUD_NSLOTS-1): its
; DIGIT_PACKED packed bytes become 64 bytes of the bar.
;
; The bar remembers the nine values it was last drawn with, because redraw_hud redraws
; all nine whenever anything changes and a score tick usually moves only one of them --
; the other eight were copies for no pixels (5.0K cycles a render on an L0 run, 3.2% of
; the frame, when measured).  The bank is BANK_LVL on entry and on exit, so the skip
; path must not touch it.
draw_health:                       ; falls into bar_digit
        lda health
        ldx #HUD_X_HEALTH
        ldy #HUD_SLOT_HEALTH
bar_digit:
        cmp BARCACHE,y             ; one bar, so one cache: no cur_buf in the index
        beq bd_same
        sta BARCACHE,y
        asl                        ; d * DIGIT_PACKED: the digit's packed bytes (assets.py:
        asl                        ; a nibble per byte column and two game rows)
        asl
        asl
        .assert DIGIT_PACKED = 16, error, "bar_digit: four shifts index the digits"
        sta tmp4
        stx ptr                    ; x is even at every call: x * 4 = char * 8
        lda #0                     ; the high byte, built in A
        asl ptr
        rol a
        asl ptr
        rol a                      ; C = 0: A was 0 or 1, so this rol shifted a 0 out
  .assert <BARADDR = 0, error, "bar_digit: the low-byte add was dropped"
        adc #>BARADDR              ; (<BARADDR = 0: nothing to add to the low byte)
        sta ptr+1
        jsr @row                   ; the top char row, then the one below it
        add16i ptr, ROWBYTES
@row:   ldy #0                     ; 8 packed bytes -> 32: each byte column's four
@b:     ldx tmp4                   ; line pairs, top line and bottom from digtop/BOT
        lda digits_art,x
        inc tmp4
        pha
        lsr
        lsr
        lsr
        lsr
        tax
        lda digtop,x
        sta (ptr),y
        iny
        lda digbot,x
        sta (ptr),y
        iny
        pla
        and #$0F
        tax
        lda digtop,x
        sta (ptr),y
        iny
        lda digbot,x
        sta (ptr),y
        iny
        cpy #DIGIT_ROWBYTES
        bne @b
bd_same:
        rts

bar_touch:
        lda #1
        sta bar_dirty
        rts


redraw_hud:                        ; lives and stars inlined (redraw_hud was their one caller)
        lda lives                  ; lives: 1 digit at HUD_X_LIVES
        ldx #HUD_X_LIVES
        ldy #HUD_SLOT_LIVES
        jsr bar_digit
        jsr draw_health
        lda stars                  ; stars remaining: 2 digits at HUD_X_STARS and on
        ldx #0                     ; X = A / 10, q1 = A mod 10 (div10, inlined)
:       cmp #10
        bcc :+
        sbc #10
        inx
        bcs :-                     ; always: A >= 10 went in, so C = 1
:       sta q1
        txa
        ldx #HUD_X_STARS
        ldy #HUD_SLOT_STARS
        jsr bar_digit
        lda q1
        ldx #HUD_X_STARS+DIGIT_W
        ldy #HUD_SLOT_STARS+1
        jsr bar_digit              ; and falls into draw_score
draw_score:                        ; 5 digits from HUD_X_SCORE: the BCD score's nibbles,
        ldx #HUD_NSLOTS-1          ; slots 8..HUD_SLOT_SCORE0, the ones first
@d:     stx q1                     ; the slot (bar_digit keeps q1)
        lda #HUD_NSLOTS-1
        sec
        sbc q1                     ; the digit's number, 0..4: its byte, and C = the high
        lsr                        ;  nibble's
        tay
        lda score,y
        bcc :+
        lsr
        lsr
        lsr
        lsr
:       and #$0F
        pha
        lda q1
        tay                        ; Y = the slot (the cache's)
        asl
        asl
        asl                        ; C = 0: slot*8 < 128
        .assert DIGIT_W = 8, error, "draw_score: three shifts space the digits"
        adc #HUD_X_SCORE-HUD_SLOT_SCORE0*DIGIT_W   ; slot*8 + 76 = 108..140
        tax
        pla
        jsr bar_digit
        ldx q1
        dex
        cpx #HUD_SLOT_SCORE0
        bcs @d
        rts
        .segment "GAMECODE"
; ============================================================================
; bar_bg: the bar has a fixed home outside the ring, so it stays put however the
; window scrolls and is only written when its contents change (in the ring it would
; move with every vertical scroll: 1280 bytes to copy again, 13,310 cycles).  Its
; template (icons, labels, blank digit slots) is the BAR file, which the
; loader puts in place with the game's image (ldprog.s) and nothing redraws.  The template
; buries the digits, so this resets the digit cache: its "already drawn" values are
; no longer true.  One bar, one cache: not one per buffer.
; ============================================================================
bar_bg:
        ldx #HUD_NSLOTS-1          ; A = LDOP_GAME ($80) from ldprog's one call: never a
                                    ; digit, so every slot reads as not drawn
@bci:   sta BARCACHE,x
        dex
        bpl @bci
        rts

; ============================================================================
; Random
; ============================================================================
rnd:    lsr seed+1
        ror seed
        bcc :+
        lda seed+1
        eor #RND_TAPS
        sta seed+1
:       lda seed
        rts

; The map's row addresses (level_init) and in_range's limits: tables whose reads are
; hot, each in a page.
        .segment "GAMEBSS"
BARCACHE:  .res 16                 ; bar_bg resets it, bar_digit keeps it: HUD_NSLOTS used
        .assert HUD_NSLOTS <= 16, error, "BARCACHE: a byte a HUD slot"
; (the small variables in the room before MROWH's half page: the colder ones -- the
; hottest are zero page's, ZPGAME above)
ma:        .res 1                  ; the map memo's tiles above and below the memo's (mt)
mb:        .res 1
pxs:       .res 1                  ; Cleo's px, py at her move's start (player_update):
pys:       .res 1                  ;  her move that frame (dxl, dyl) is from them
bdx:       .res 1                  ; the boomerang's move this frame (bsweep's stretch)
bdy:       .res 1
bmx:       .res 1                  ; and what of it is still to make (8 px at a time)
bmy:       .res 1
swe:       .res 1                  ; (sweep's: the move down)
; the level's (level_init's: this image's, zeroed as it comes in -- what the menus set
; stays in zero page)
stars:     .res 1                  ; the stars left to collect
nobj:      .res 1                  ; the level's objects
exiting:   .res 1                  ; the level is over (the exit reached, or no lives left)
gridsh:    .res 1                  ; log2 of the collision grid width
bin_ok:    .res 1                  ; the bin walk's list is current: its gx1, or 0 for none
rise:      .res 2                  ; the red snake's rise above its basket (ob_rsnake)
        .segment "GAMEROWH"         ; (half-page aligned, after GAMEBSS: MROWH in one page,
MROWH:     .res MAPROWS            ;  and LV_OBJST, GAMEOBJ's, on the next -- the cfg's
                                    ;  order; the row addresses' high bytes)
        .assert <MROWH = $80, error, "MROWH: the cfg's GAMEROWH is half-page aligned after GAMEBSS"
        .segment "GAMELVL"          ; $8220-$82FF: bank 7 below the image's variables
RNGTAB:    .res RNGTAB_LEN         ; in_range's limits: the level file's header tail
        .assert RNGTAB = LV_HDR + HDR_LEN, error, "RNGTAB: where the loader puts the header's tail"
MROWL:     .res MAPROWS            ; the row addresses' low bytes
; The red snake's rise above its basket, by its counter A & 31 (A = -15..16 while it
; is up): (A*A >> 3) - 28, the reference's parabola (CleoApp.run), baked
        .segment "GAMEDATA"
rise_tab:
        .repeat RISE_N, i
          .if i <= RSNAKE_UP-1
        .byte <((i*i >> 3) - 28)
          .else
        .byte <(((RISE_N-i)*(RISE_N-i) >> 3) - 28)
          .endif
        .endrepeat
; The score and the hi-score: BCD, ones first, five digits shown (a sixth in the
; top byte's high nibble is room).  Resident -- bank 7's last page, kept through
; both images: the menus show them and set the hi-score; the game keeps them.
        .segment "GAMEHI"
score:     .res 3
hi_score:   .res 3
        .assert hi_score = score + 3, error, "draw_number: Y = 0 score, 3 hi-score"
        .assert >MROWL = >(MROWL+MAPROWS-1) && >MROWH = >(MROWH+MAPROWS-1), warning, "MROWL/MROWH cross a page: their reads +1"

        .segment "GAMECODE"      
; ============================================================================
; Sound effect ids
; ============================================================================
SFX_JUMP  = 1
SFX_STAR  = 2
SFX_THROW = 3
SFX_HIT   = 4
SFX_KILL  = 5
SFX_POWER = 6
SFX_DIE   = 7
