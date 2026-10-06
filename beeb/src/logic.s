; ============================================================================
; CLEO - the game's logic: a port of CleoApp.run() from the J2ME original.  One
; step a rendered frame, each the original's two steps' worth: Cleo (the player's
; move against the map, her animation, the boomerang), the objects (thirteen types,
; walked from a collision grid), the swept collision tests, and the status bar's
; digits.  Both machines; the Model B's hardware (BHW) never enters -- every .if BHW
; here is a CPU spelling, and says so.
;
; Segments: ZPGAME (the game's zero page: its state and the frame's scratch), GAMEBSS,
; GAMEROWH, GAMELVL and GAMEHI (bank 7's variables and tables, the loader's and the
; game's), GAMECODE (bank 7's game image, with the engine code it calls), GAMEDATA
; (rise_tab).
;
; Exported: level_init and game_frame (game.s's level loop), redraw_hud (hook_hud:
; the engine's render_frame, main.s), bar_bg (hook_image: the loader, main.s), the
; game state the menus set (level, lives, seed, max_level, score, hi_score) and
; read (exiting, stars: game.s).  The sound effect ids (SFX_*) index game.s's
; sfx_tab.
;
; The two rules the collision code keeps:
;   -- no intermediate positions.  A frame moves Cleo (dxl, dyl) and the boomerang
;      (bdx, bdy) in one go; a test against a thin or stompable object looks at
;      where she is, and failing that at the whole box between where she was and
;      where she is (csweep, bsweep: span over each axis); a big enemy that cannot
;      be stomped (the mask, the mummy, the red snake) is tested where both were
;      drawn, by the frames' own boxes (body_hit).  Nothing is tested at a position
;      between a frame's ends.
;   -- the limits are the packer's.  Every test is in_range's quad (lo, hi, lo2,
;      hi2: rx > lo, rx < hi, ry > lo2, ry < hi2, each stored + RQ_BIAS), read from
;      RNGTAB by its RQ_* offset (assets.inc, from tools/assets.py RNGTAB_QUADS); the
;      loader puts the table in with the level's header (its tail: RNGTAB = LV_HDR +
;      HDR_LEN).  The game writes two: the spike's x limit (ob_spike) and RQ_BODY,
;      built for each body_hit from the two frames' boxes.
; ============================================================================

; ---------------------------------------------------------------- constants
; Every rate is two of the original's steps a frame (game_frame).  Positions are
; game pixels, speeds 1/256ths of one a frame.  The sprite ids (SPR_*), the object
; types (OT_*), in_range's quads (RQ_*) and the HUD's columns (HUD_X_*) are the
; packer's: assets.inc.
MAXFALL   = 12                     ; Cleo's fall a frame at most (the camera follows
                                   ;  it): the original's MAXDWY0 a step, two steps,
MAXDWY0   = 8                      ;  less a tile's slack
GRAV      = 80                     ; gravity's step: vy = (vy + GRAV) * 31 >> 5
JUMP_VY   = -1280                  ; a jump's vy (and a knock-up's, a stomp's bounce)
TRAMP_VY  = -2048                  ; a trampoline's
KNOCK_VX  = 768                    ; a hit's knockback, and Cleo's top speed
BOOM_VX   = 3584                   ; the boomerang's throw
ACC_GROUND = 72                    ; running: the ground's acceleration, and the air's
ACC_AIR   = 480
JUMP_VYT  = 384                    ; |vy| from which a jump shows its rising/falling frame
CLEO_FEET = 16                     ; her feet: py + 16 (the altitude is read there)
CLEO_KILLY = 12                    ; where a kill tile is felt: py + 12
CLEO_H    = 24                     ; her height: off the map's bottom past maph - 24
EXIT_W    = 16                     ; the exit's box, from (exitx, exity)
EXIT_H    = 24
CAM_Y     = 46                     ; Cleo's y in the window, one for one
CAM_AHEAD_R = WINPX/4              ; the camera's lookahead: facing right, Cleo a
CAM_AHEAD_L = 3*WINPX/4            ;  quarter in from the left; left, three quarters
PUSH_MASK = 7                      ; a tile attribute: bits 0-2 the push + PUSH_BIAS,
PUSH_BIAS = 3                      ;  bit 7 a kill tile
PUSH_NONE = 3                      ; a push of 3 is the original's "none": the air's
                                   ;  friction and acceleration apply
ALT_OUTSIDE = 8                    ; the alt byte of a pixel off the map (the original's)
RESPAWN_F = 30                     ; dead: frames before the respawn
HURT_F    = 32                     ; hurt: frames of invulnerability,
CTRL_F    = 13                     ;  the control back after this many
THROW_T1  = 4                      ; a throw's anim: the launch, and its frame changes
THROW_T2  = 6
THROW_T3  = 10
THROW_END = 12                     ;  (the anim ends)
RUN_ANIM  = 16                     ; the run anim wraps here (4 frames of 4)
IDLE_ANIM = 128                    ; the stand's wraps here: the blink's first frame from
BLINK0    = 93                     ;  BLINK0, its second for BLINK_LEN from BLINK1
BLINK1    = 109
BLINK_LEN = 4
STARCLK   = 12                     ; the stars' spin: 12 steps (6 frames, two steps each)
SPARKLE0  = 12                     ; a collected star's count: SPARKLE0 up to SPARKLE_END
SPARKLE_END = 18                   ;  (3 frames, then gone)
BCNT_HIT  = 8                      ; the boomerang's count: in flight 0..6 (its spin);
BCNT_GONE = 14                     ;  hit or stopped, BCNT_HIT to BCNT_GONE, then inactive
BOOM_STEP = 8                      ; its move, 8 px at a time (the altitude read between)
BOOM_REF_DY = 8                    ; brel's ry = py - by + 8: Cleo's reference point is
                                   ;  8 px below the boomerang's (its pull and its catch)
TRAMP_TOP = 10                     ; a trampoline's spring count: 2, 4, 6, 8, then back
                                   ;  to 0 in place of TRAMP_TOP
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
BAT_STOMP_Y = 4                    ; a stomp: Cleo above it by more than this where her
                                   ;  move began
BATOFF_N  = 16                     ; bat_off's entries (the wobble)
WALK_STEP = 3                      ; the mask's and mummy's step a frame
HIT_INSET_AIR = 4                  ; body_hit: each frame's box pulled in this far (px)
HIT_INSET_GROUND = 2               ;  each side, off the art's transparent corners --
                                   ;  less on the ground, where her feet and the enemy's
                                   ;  head are solid to the box's edge (measured)
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
BINMAX    = BINMAXDEF              ; the bin walk's lists (assets.py: the objects' grid
                                   ;  cells under the worst window)
OBJCLR_PAGES = 10                  ; level_init's clear: 10 pages from O_STAMP
BIN_TILESHIFT = 3                  ; a grid cell is 8 tiles (BINPX px)
        .assert (TILEPX << BIN_TILESHIFT) = BINPX, error, "the collision grid's cell is BINPX"
NIBBLE    = $0F                    ; a byte's low nibble: an alt byte's (get_altitude),
                                   ;  a packed digit's (bar_digit), a BCD score's
; the HUD's digit slots (BARCACHE): lives, health, the stars' two, the score's five
HUD_SLOT_LIVES  = 0
HUD_SLOT_HEALTH = 1
HUD_SLOT_STARS  = 2
HUD_SLOT_SCORE0 = 4
HUD_NSLOTS      = 9
DIGIT_ROWBYTES = TILECHARS*CHARBYTES ; a digit's char row: 4 chars
DEC_BASE  = 10                     ; the stars' two decimal digits (redraw_hud)
; the sound effects: 1-based into game.s's sfx_tab (sfx_jump, sfx_star, ... in this
; order); sfx_req takes one (the kernel's sound_tick plays it)
SFX_JUMP  = 1
SFX_STAR  = 2
SFX_THROW = 3
SFX_HIT   = 4
SFX_KILL  = 5
SFX_POWER = 6
SFX_DIE   = 7

; ---------------------------------------------------------------- object arrays (bank 7)
; OBJ_MAX (levelfmt.inc) objects at most, a byte a field each, from LV_OBJST
; (gamedata.s, GAMEOBJ: page aligned).  The fields: the frame stamp, the type, the
; position (X, Y: 16-bit, two arrays each) and five state words A..E, their meaning
; the type's (each handler's header).
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

; ---------------------------------------------------------------- variables
; The game's zero page, after the engine's (defs.inc).  The state the menus' image
; sets for the game (level, lives, seed, max_level) must live here or in GAMEHI: the
; game's image zeroes GAMEBSS as it comes in.  The frame's hottest scalars are here
; too (profiled with test/hotvars.mjs: 5-11 accesses a frame each); the colder ones
; (stars, gridsh, rise, nobj, exiting, bin_ok: an access a frame or fewer) are
; GAMEBSS's, below.
        .segment "ZPGAME": zeropage
bin_i:     .res 1                  ; the bin walk's index (44-64 accesses a frame)
bin_nstar: .res 1                  ; the cached bin walk's lengths: stars,
bin_noth:  .res 1                  ;  everything else
frame:     .res 2                  ; the frame count: the stamps' and the timers' clock
px:        .res 2                  ; Cleo: her position (px, py: game pixels, the
py:        .res 2                  ;  sprite's reference point), her velocity (vx,
vx:        .res 2                  ;  vy: 1/256 px a frame; a negative vy is up)
vy:        .res 2
anim:      .res 1                  ;  her animation count (two a frame)
ev_frame:  .res 2                  ; the frame of the last event (a hit, a death, a
                                   ;  respawn): the hurt and control timers' start
facing:    .res 1                  ; 1 = left (a sprite id's low bit)
running:   .res 1                  ; 0/1: a run key held this frame
firing:    .res 1                  ; 0/1: a throw's animation is running
hurt:      .res 1                  ; 0/1: invulnerable (HURT_F frames after a hit)
control:   .res 1                  ; 0/1: the keys act (lost for CTRL_F frames by a hit)
bx:        .res 2                  ; the boomerang: its position, velocity (as Cleo's),
by:        .res 2
bvx:       .res 2
bvy:       .res 2
bcnt:      .res 1                  ;  count (BCNT_HIT, BCNT_GONE) and 0/1 in play
bactive:   .res 1
bounce:    .res 1                  ; 0/1: a stomp this frame (vy = JUMP_VY after the objects)
startx:    .res 2                  ; the level's start and exit, in game pixels
starty:    .res 2                  ;  (level_init: four words in a row, a loop fills them)
exitx:     .res 2
exity:     .res 2
level:     .res 1                  ; the level, 0..NLEVELS-1 (even main, odd bonus)
lives:     .res 1
health:    .res 1                  ; 0..HEALTH_MAX; 0 = dead (player_dead runs)
max_level: .res 1                  ; the menus': the chooser's reach
last_keys: .res 1                  ; the menus': their key edge detection (menu.s)
logicvs:   .res 1                  ; game.s's: vsyncs at the last logic step
cam_off:   .res 1                  ; the window's bias: wx = px - cam_off (eased toward
                                   ;  CAM_AHEAD_R or _L, 2 a frame)
seed:      .res 2                  ; rnd's LFSR state (the menus seed it: RND_SEED)
; the frame's scratch
ox:        .res 2                  ; an object's position (os_oxy: spx/spy's copy, for the
oy:        .res 2                  ;  handlers that move spx/spy and read it after)
fa:        .res 2                  ; a staged object's fields (os_vanish, os_switch: the
fb:        .res 2                  ;  low bytes of A..E; the bat: C, D whole in fc, fd)
fc:        .res 2
fd:        .res 2
fe:        .res 2
rx:        .res 2                  ; the object less Cleo (process_object), or less the
ry:        .res 2                  ;  boomerang (boom_rel): what in_range tests
qx:        .res 2                  ; the map queries' pixel (get_altitude, get_tile_attr)
qy:        .res 2
alt:       .res 1                  ; the altitude under Cleo's feet (player_update)
q1:        .res 1                  ; six bytes of scratch, each routine's own (level_init
q2:        .res 1                  ;  reads the object record into q1..q5; the star's q2
q3:        .res 1                  ;  is po_star's "Cleo far"; q5 fall2's first move;
q4:        .res 1                  ;  q6 the push, player_update, and the red snake's
q5:        .res 1                  ;  "out")
q6:        .res 1
obj:       .res 1                  ; the object being processed (Y in the handlers)
star_clk:  .res 1                  ; the stars' clock, 0..STARCLK-1: a star's spin step
                                   ;  is it plus its phase
bin_r:     .res 4                  ; the bin walk's rectangle, gx0, (unused), gy, gy1
                                   ;  (its gx1 is bin_ok, GAMEBSS: the list's validity)
gx:        .res 1                  ; the grid walk's cursor: the cell (gx, gy) over
gy:        .res 1                  ;  gx0..gx1 x gy..gy1 (level_init, game_frame)
gx0:       .res 1
gx1:       .res 1
gy1:       .res 1
bent:      .res 1                  ; the grid's chain entries used (level_init), then a
                                   ;  walk's current entry (game_frame)
otype:     .res 1                  ; the object's type (level_init, process_object)
t16:       .res 2                  ; 16-bit scratch: mod16's dividend, gravity's and the
t16b:      .res 2                  ;  boomerang's products, the bat's wobble index
dpx:       .res 2                  ; Cleo's move this frame on the axis in hand: the fall
                                   ;  (fall2, move2: low byte signed, high its sign), then
                                   ;  the steps across (player_update @hmove)
hx:        .res 2                  ; player_hit's: the enemy's rx (its sign alone is read)
grow:      .res 1                  ; the grid walk's row base: gy << gridsh
mok:       .res 1                  ; the map memo (get_altitude): 0 for none; where it is
mkxlo:     .res 1                  ;  (qx & $F8, qx+1, qy & $F8, qy+1) and the tile (mt;
mkxhi:     .res 1                  ;  the tiles above and below it, ma and mb, are
mkylo:     .res 1                  ;  GAMEBSS's)
mkyhi:     .res 1
mt:        .res 1
dxl:       .res 1                  ; Cleo's move this frame, across and down: the stretch
dyl:       .res 1                  ;  csweep tests (its start, pxs and pys, is GAMEBSS's)
swd:       .res 1                  ; span's: the stretch, its biased low end, r (low,
swa:       .res 1                  ;  high), and Y kept across sweep
swlo:      .res 1
swhi:      .res 1
swy:       .res 1
        .zeropage

; Bank 7's variables.  GAMEBSS is zeroed as the game's image comes in (ldprog.s);
; the cfg orders GAMEBSS, then GAMEROWH (half-page aligned: MROWH in one page), then
; GAMEOBJ (gamedata.s: the object arrays, page aligned).
        .segment "GAMEBSS"
BARCACHE:  .res 16                 ; the HUD's digit last drawn in each slot (bar_digit
                                   ;  skips a match; bar_bg resets it)
        .assert HUD_NSLOTS <= 16, error, "BARCACHE: a byte a HUD slot"
ma:        .res 1                  ; the map memo's tiles above and below the memo's (mt)
mb:        .res 1
pxs:       .res 1                  ; Cleo's px, py at her move's start (player_update):
pys:       .res 1                  ;  her move that frame (dxl, dyl) is from them
bdx:       .res 1                  ; the boomerang's move this frame (bsweep's stretch)
bdy:       .res 1
bmx:       .res 1                  ; and what of it is still to make (BOOM_STEP at a time)
bmy:       .res 1
swe:       .res 1                  ; sweep's: the move down
stars:     .res 1                  ; the level's: the stars left to collect (game.s reads it),
nobj:      .res 1                  ;  its objects,
exiting:   .res 1                  ;  the level is over (the exit reached, or no lives left:
                                   ;  game.s's loop leaves on nonzero),
gridsh:    .res 1                  ;  log2 of the collision grid's width in cells,
bin_ok:    .res 1                  ;  the bin walk's list is current: its gx1, or 0 for none
rise:      .res 2                  ; the red snake's rise above its basket (ob_rsnake)
cleo_id:   .res 1                  ; the sprite Cleo was last drawn as (player_update):
                                   ;  her body for body_hit, where she was drawn
hit_k:     .res 1                  ; body_hit's RQ_BIAS + 2 x its inset, by cleo_id
        .segment "GAMEROWH"
MROWH:     .res MAPROWS            ; the map rows' addresses, high bytes (level_init fills
                                   ;  both; the map queries read them)
        .assert <MROWH = $80, error, "MROWH: the cfg's GAMEROWH is half-page aligned after GAMEBSS"
        .segment "GAMELVL"
; RNGTAB: the collision quads.  The packer writes one table (tools/assets.py
; RNGTAB_QUADS) as every level file's header tail and the loader lays it here, at
; LV_HDR + HDR_LEN ($8220): in_range's and span's reads stay in page $82.  A quad
; is four bytes at offset RQ_<name> (assets.inc): x lo, x hi, y lo, y hi, each
; stored + RQ_BIAS.  The box is open -- r > lo and r < hi on each axis -- where r
; is the object less the mover: Cleo's rx, ry (process_object) or the boomerang's
; (boom_rel).  The offsets are symbols, so the packer may place a quad anywhere,
; except that a guard band's boomerang quad is its Cleo one's + RQ_BOOMOFF
; (box_safe's ora; both sides assert it).  One byte changes in play: ob_spike
; writes RQ_SPIKE's x hi from its height before each test.
RNGTAB:    .res RNGTAB_LEN         ; RNGTAB_LEN: the packer's room (assets.inc)
        .assert RNGTAB = LV_HDR + HDR_LEN, error, "RNGTAB: where the loader puts the header's tail"
MROWL:     .res MAPROWS            ; the row addresses' low bytes
        .assert >MROWL = >(MROWL+MAPROWS-1) && >MROWH = >(MROWH+MAPROWS-1), warning, "MROWL/MROWH cross a page: their reads +1"
; The score and the hi-score: BCD, ones first, five digits shown (the top byte's
; high nibble is room for a sixth).  Resident -- bank 7's last page, kept through both
; images: the menus show them and set the hi-score (game.s, menu.s); the game scores.
        .segment "GAMEHI"
score:     .res 3
hi_score:  .res 3
        .assert hi_score = score + 3, error, "draw_number (menu.s): Y = 0 the score, 3 the hi-score"

; ---------------------------------------------------------------- macros
; 16-bit arithmetic on zero page or absolute words (lo, then hi).  A is clobbered by
; every one; the flags are the last instruction's.
; mov16 dst, src: dst = src
.macro mov16 dst, src
        lda src
        sta dst
        lda src+1
        sta dst+1
.endmacro
; add16 dst, src: dst += src
.macro add16 dst, src
        clc
        lda dst
        adc src
        sta dst
        lda dst+1
        adc src+1
        sta dst+1
.endmacro
; add16i dst, imm: dst += imm.  A byte-sized imm skips the high byte's add with a
; bcc over the inc (dst in zero page: the inc is 2 bytes) -- except for dpx, whose
; one caller (fstep2) wants the high byte in A.
.macro add16i dst, imm
        clc
        lda dst
        adc #<(imm)
        sta dst
  .if (>(imm) = 0) .and (.not .xmatch({dst}, {dpx}))
        .assert (dst) < $100, error, "add16i: bcc *+4 skips a zero-page inc"
        bcc *+4                    ; no carry: the high byte stands
        inc dst+1
  .else
        lda dst+1
        adc #>(imm)
        sta dst+1
  .endif
.endmacro
; sub16i dst, imm: dst -= imm (as add16i)
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
; dif16 dst, aa, bb: dst = aa - bb
.macro dif16 dst, aa, bb
        sec
        lda aa
        sbc bb
        sta dst
        lda aa+1
        sbc bb+1
        sta dst+1
.endmacro
; bgt16 aa, bb, label: branch if aa > bb (signed), bge16: if aa >= bb.  No overflow
; fixup: every caller compares x positions (px, and an object's x within a wobble or
; a knock of it: both under 2048), never a pair 2^15 apart.
.macro bgt16 aa, bb, label
        lda bb
        cmp aa
        lda bb+1
        sbc aa+1
        bmi label
.endmacro
.macro bge16 aa, bb, label
        lda aa
        cmp bb
        lda aa+1
        sbc bb+1
        bpl label
.endmacro
; bmi16 var, label / bpl16 var, label: branch on var's sign (A kept: bit)
.macro bmi16 var, label
        bit var+1
        bmi label
.endmacro
.macro bpl16 var, label
        bit var+1
        bpl label
.endmacro
; submin0 n: A = max(A - n, 0), unsigned (one ':' forward skip)
.macro submin0 n
        sec
        sbc #n
        bcs :+                     ; no borrow: A >= n, the difference stands
        lda #0
:
.endmacro
; beq16 var, label: branch if var = 0
.macro beq16 var, label
        lda var
        ora var+1
        beq label
.endmacro

; ---- the map queries' pieces
; altof: A = a tile id -> A = its alt byte at pixel column qx & 7: alt_tab[cls*8 +
; (qx & 7)], cls = LV_ALTCLS[id] (< 32: the three asls shift nothing out, and
; leave C = 0).  Y clobbered.
.macro altof
        tay
        lda LV_ALTCLS,y
        asl
        asl
        asl
        eor qx                     ; (A & $F8) | (qx & 7): A's low 3 bits are 0
        and #<-TILEPX
        eor qx
        tay
        lda alt_tab,y
.endmacro
; tile_coord lo: A = a pixel coordinate's high byte (< 8, so the pixel is inside a
; map of at most 2048) -> A = its tile coordinate (hi << 5) | (lo >> 3), in one byte
; by rotation; q2 scratch; C = 0 after.
.macro tile_coord lo
        lsr                        ; A = hi >> 1, C = hi bit 0
        sta q2
        lda lo
        and #<-TILEPX
        ora q2                     ; lo7..lo3, 0, hi2, hi1 (C = hi0)
        ror
        ror
        ror                        ; hi2..hi0, lo7..lo3 (C = 0: a zero rotated out)
.endmacro
; memo_test miss: is (qx, qy) in the map memo's tile?  A = qy+1 on entry; to miss if
; not (mok = 0: no memo), else falls through with X = mok (nonzero), A = qx & $F8.
.macro memo_test miss
        ldx mok
        beq miss
        cmp mkyhi
        bne miss
        lda qx+1
        cmp mkxhi
        bne miss
        lda qy
        and #<-TILEPX
        cmp mkylo
        bne miss
        lda qx
        and #<-TILEPX
        cmp mkxlo
        bne miss
.endmacro

; ---- Cleo's pieces
; feet_qy: qy = py + CLEO_FEET (her feet; qx is px already at every site).  A
; clobbered, C = the add's.
.macro feet_qy
        clc
        lda py
        adc #<CLEO_FEET
        sta qy
        lda py+1
        adc #>CLEO_FEET
        sta qy+1
.endmacro
; feet_alt: alt = the altitude under her feet (get_altitude: X, Y, tp, qy clobbered)
.macro feet_alt
        feet_qy
        jsr get_altitude
        sta alt
.endmacro
; hit_cleo skip: an enemy touches her -- unless she is invulnerable (hurt), knock
; her back from it (player_hit: hx = rx, its sign the direction); Y = obj again
.macro hit_cleo skip
        lda hurt
        bne skip
        lda rx+1                   ; player_hit reads only hx+1's sign
        sta hx+1
        jsr player_hit
        ldy obj
.endmacro
; grid_rowbase: A = gy << gridsh (the grid row's first cell), gx = gx0; X = 0.
; gridsh >= 2: every map is at least 256 px wide (maplw >= 5).  One ':' loop.
.macro grid_rowbase
        lda gx0
        sta gx
        lda gy
        ldx gridsh
:       asl
        dex
        bne :-
.endmacro
; bin_range w, g0, g1, len: the grid cells a window edge covers: g0 = w >> 6 (w <
; 16384) and g1 = (w + len) >> 6 -- g0 + len's 64s, + 1 if w's remainder carries.
; w's top two low-byte bits are shifted into the high byte; X = w << 1 keeps the
; remainder doubled for the test.  A, X clobbered.
.macro bin_range w, g0, g1, len
        .assert BINPX = 64, error, "bin_range: the shifts are a 64-px cell's"
        lda w
        asl
        tax                        ; X = w << 1: cpx #$80 below gives C = w bit 6
        lda w+1
        rol
        cpx #$80
        rol
        sta g0
        txa
        and #(BINPX-1)*2           ; (w & 63) * 2 >= (64 - len % 64) * 2: the remainder
        cmp #(BINPX-((len) & (BINPX-1)))*2 ;  carries (exact mod 256 for any 16-bit w)
        lda g0
        adc #(len)/BINPX
        sta g1
.endmacro

; ---- the objects' pieces
; objrel sp, olo, ohi, p, r: sp = the object's coordinate (olo/ohi,y), r = it less p
; (16-bit).  sta touches no flags, so C carries from the sbc to the sbc.
.macro objrel sp, olo, ohi, p, r
        lda olo,y
        sta sp
        sec
        sbc p
        sta r
        lda ohi,y
        sta sp+1
        sbc p+1
        sta r+1
.endmacro
; oxy_set: ox, oy = spx, spy (the object's position, kept while a handler moves spx/spy)
.macro oxy_set
        lda spx
        sta ox
        lda spx+1
        sta ox+1
        lda spy
        sta oy
        lda spy+1
        sta oy+1
.endmacro
; addb_rxspx: rx and spx += B (O_BL/BH,y): the snake's offset along
; their path, applied to where they are and where they draw
.macro addb_rxspx
        clc
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
.endmacro
; boom_test rq, miss: the boomerang in flight (boom_ready) and the box its last move
; crossed meets this object's quad rq (boom_rel, bsweep: rx, ry are then the object
; less the boomerang); to miss if not.  X = rq after a hit.
.macro boom_test rq, miss
        jsr boom_ready
        bcc miss
        jsr boom_rel
        ldx #rq
        jsr bsweep
        bcc miss
.endmacro
; snake_bge lim: C = B >= lim (signed, 16-bit, B = O_BL/BH,y): the high bytes'
; compare with the sign bit flipped, the low bytes' borrow carried in.  X = B low.
.macro snake_bge lim
        ldx O_BL,y
        cpx #<(lim)
        lda O_BH,y
        eor #$80
        sbc #(>(lim) ^ $80)
.endmacro
; snake_bage lim: C = B - A >= lim (signed): A = B's low byte and C = 1 on entry;
; the difference's low byte in X.
.macro snake_bage lim
        sbc O_AL,y
        tax
        lda O_BH,y
        sbc O_AH,y
        eor #$80
        cpx #<(lim)
        sbc #(>(lim) ^ $80)
.endmacro
; dormant_reset: A (O_AL,y) = -(rnd & DORM_MASK) - DORM_BASE: the red snake's and the
; spike's rest, -127..-64 (63 - r, then + 129, is 192 - r: the byte form)
.macro dormant_reset
        jsr rnd
        and #DORM_MASK
        eor #DORM_MASK
        clc
        adc #<(-(DORM_BASE+DORM_MASK))
        sta O_AL,y
.endmacro
; adds8 var: var (16-bit) += A (a signed byte), without building the word: the high
; byte pre-borrowed when A is negative.  Two ':' skips.
.macro adds8 var
        bpl :+
        dec var+1
:       clc
        adc var
        sta var
        bcc :+
        inc var+1
:
.endmacro
; oin f, lo / oout f, lo: an object's field byte (lo,y) into zero page f, and back
.macro oin f, lo
        lda lo,y
        sta f
.endmacro
.macro oout f, lo
        lda f
        sta lo,y
.endmacro

        .segment "GAMECODE"
; ---------------------------------------------------------------- map queries
; The map is bank 5's and this code bank 7's, so every touch goes through low RAM's
; map_row, map_col, map_byte and map_put (lowram.s), which page bank 7 back.  A
; pixel's tile is (x >> 3, y >> 3); a map is 2^maplw tiles wide and its sizes
; (mapw, maph) multiples of 256 px, so "inside" is a compare of the high byte alone,
; and a high byte under 8 lets the tile coordinate be built in one byte (tile_coord).

; ----------------------------------------------------------------------------
; map_tile: the tile id at a tile coordinate
;   In:    X = the tile column, A = the tile row (< MAPROWS)
;   Out:   A = the tile id; map_ptr = the row's address (MROWL/H: level_init's);
;          Y = the column
;   Uses:  A Y
;   Keeps: X
;   Post:  bank 7 paged (map_byte)
; ----------------------------------------------------------------------------
map_tile:
        tay
        lda MROWL,y
        sta map_ptr
        lda MROWH,y
        sta map_ptr+1
        txa
        tay
        jmp map_byte

; ----------------------------------------------------------------------------
; tilexy: the tile under pixel (qx, qy), if it is inside the map
;   In:    qx, qy
;   Out:   C = 1 outside the map (then A, X are partial); else C = 0, X = qx >> 3,
;          A = qy >> 3
;   Uses:  A X, q2
; The high bytes alone decide "inside" (the map sizes are multiples of 256).
; ----------------------------------------------------------------------------
tilexy:
        lda qx+1
        cmp mapw+1
        bcs @out
        tile_coord qx
        tax
        lda qy+1
        cmp maph+1
        bcs @out
        tile_coord qy
@out:   rts                        ; C = 0 inside (tile_coord's rors), 1 outside (the bcs)

; ----------------------------------------------------------------------------
; get_info: the alt byte of a pixel
;   In:    qx, qy
;   Out:   A = the alt byte of the tile under (qx, qy) at its column, ALT_OUTSIDE off
;          the map
;   Uses:  A X Y, q2, map_ptr
;   Post:  bank 7 paged
; The general query: get_altitude's way for a pixel off the map.
; ----------------------------------------------------------------------------
get_info:
        jsr tilexy
        bcs @out                   ; (outside: the constant, after the rts)
        jsr map_tile
        altof
        rts
@out:   lda #ALT_OUTSIDE
        rts

; ----------------------------------------------------------------------------
; get_altitude: the altitude at a pixel -- how far below (positive) or above
; (negative) the pixel the ground is, from the tile's alt byte and its neighbour's
;   In:    qx, qy = the pixel (qx inside the map's width if qy is inside its height)
;   Out:   A = the altitude, signed (N from the last sbc: callers branch on it);
;          qy moved to the neighbouring tile where one was read
;   Uses:  A X Y, q2, q5, tp, map_ptr, the memo (mok, mkxlo..mkyhi, mt, ma, mb)
;   Post:  bank 7 paged
;   Cost:  measured 850 cycles a frame on both machines, 4.4 calls (test/linecyc.mjs,
;          L0/4/8/10, 60 frames, 4 Oct 2026); the memo hit on 81% of them
; The original's getAltitude (CleoApp) on the packer's alt bytes (alt.bin, by alt
; class and pixel column: altof).  With n3 the tile's alt byte, n4 its high nibble
; and n5 = qy & 7 the pixel's line in the tile: above the tile's ground, n5 <
; (n3 & 15), the answer is n4 - n5 when n4 is not 0, else the tile above's -- its
; n4 - 8 - n5 if its low nibble is 8, else -n5; on or below the ground it is the
; tile below's n4 + 8 - n5.  The three tiles come from one visit to bank 5
; (map_col), the rest is arithmetic.
; The map memo: the last tile read (mt, with the tiles above and below it, ma and
; mb) and where it is (mkxlo..mkyhi: the tile's pixel origin).  Cleo's queries --
; under her feet, at each step across, through her fall -- land in the tile the
; one before did more often than not, and then skip the arithmetic and the bank 5
; visit.  It holds across frames: mok = 0 (none) at a level's start and wherever
; the map is written (mark_pair).  A pixel off the map takes the general way (@off),
; a get_info at a time; above the map's top qy+1 = $FF, which the unsigned compare
; with maph+1 also calls outside.
; ----------------------------------------------------------------------------
get_altitude:
        lda qy+1
        cmp maph+1
        bcs @offj
        memo_test @read            ; the memo's tile?  (A = qy+1)
        lda ma                     ; yes: its column's three tiles, as map_col gave them
        sta tp
        lda mb
        sta tp+1
        lda mt
        jmp @have
@offj:  jmp @off                   ; (off the map: out of a branch's reach)
@read:  lda qy+1                   ; tilexy's, in line: the row into X, the column into Y
        tile_coord qy
        tax
        lda qx+1
        cmp mapw+1
        bcs @offj
        tile_coord qx
        tay
        lda MROWL,x
        sta map_ptr
        lda MROWH,x
        sta map_ptr+1
        jsr map_col                ; A = the tile, tp = the one above, tp+1 the one below
        sta mt                     ; the memo: this tile, its column's two others, where
        tay                        ;  it is
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
        sta mok                    ; qy+1 + 1: nonzero (qy+1 < maph+1 <= 8)
        inc mok
        tya
@have:  altof
        tax                        ; X = n3, the alt byte
        lda qy
        and #TILEPX-1
        sta q5                     ; n5, the pixel's line in the tile
        txa
        and #NIBBLE                ; C = 0 from altof (its third asl)
        sbc q5                     ; (n3 & 15) - n5 - 1: C = 1 iff n5 < (n3 & 15)
        bcs @above                 ; above the tile's ground
        lda qy                     ; below it: the tile below (C = 0 from the sbc: + 8)
        adc #TILEPX
        sta qy
        bcc @below                 ; no carry: qy+1 as tested at entry, inside the map
        inc qy+1
        lda qy+1                   ; the pixel 8 below: the tile below, or get_info's
        cmp maph+1                 ;  ALT_OUTSIDE past the map's bottom (tilexy's test)
        lda #ALT_OUTSIDE
        bcs @below2
@below: lda tp+1
        altof
@below2:
        lsr
        lsr
        lsr
        lsr                        ; its n4
        clc
        adc #TILEPX+1              ; n4 + 8 - n5: the carry into the sbc is the clc's 0
        sbc q5                     ;  (the add cannot overflow), the - 1
        rts
@off:   lda qy                     ; off the map: its alt byte is get_info's ALT_OUTSIDE,
        and #TILEPX-1              ;  so n5 < (n3 & 15) and n4 = 0 always -- the tile
        sta q5                     ;  above's case, straight to it
        lda qy                     ; (C = 1 from the bcs that came here: - 8)
        sbc #TILEPX
        sta qy
        bcs :+
        dec qy+1
:       jsr get_info
        jmp @top
@above: txa
        lsr
        lsr
        lsr
        lsr                        ; n4
        bne @d2                    ; the tile's own top: n4 - n5
        lda qy                     ; n4 = 0: the tile above (- 8)
        sec
        sbc #TILEPX
        sta qy
        bcs @up                    ; no borrow: qy+1 as tested at entry, inside the map
        dec qy+1
        lda qy+1                   ; the pixel 8 above: the tile above, or get_info's
        cmp maph+1                 ;  ALT_OUTSIDE above the map's top (qy+1 = $FF) or past
        lda #ALT_OUTSIDE           ;  its bottom
        bcs @top
@up:    lda tp
        altof                      ; (on into @top)
@top:   tax
        and #NIBBLE
        cmp #TILEPX
        beq @full                  ; a full tile above: its n4 - 8 - n5
        lda #0                     ; else 0 - n5 - 1 (n4, which was 0: @d2's in line)
        sec
        sbc q5
        rts
@full:  txa
        lsr
        lsr
        lsr
        lsr                        ; C = 1: the low nibble is 8 (the cmp)
        sbc #TILEPX
@d2:    sec
        sbc q5
        rts

; ----------------------------------------------------------------------------
; get_tile_attr: the attribute byte of the tile under a pixel
;   In:    qx, qy; or (get_tile_attr+2) A = qy+1 not yet stored, qx, qy's low byte
;   Out:   A = LV_ATTR0[tile]: bits 0-2 the push + PUSH_BIAS, bit 7 a kill tile;
;          PUSH_BIAS (no push, no kill) off the map
;   Uses:  A X Y, q2, map_ptr
;   Post:  bank 7 paged
;   Cost:  measured 178 cycles a frame on both machines, 2 calls (as get_altitude's)
; get_altitude's memo test, then the tile's id from the memo (mt) or the map
; (map_byte: this tile alone, no memo written).  game_frame's kill-tile test enters
; at +2 with A = py + CLEO_KILLY's high byte, which the store here keeps for the
; memo test and @read.
; ----------------------------------------------------------------------------
get_tile_attr:
        lda qy+1
        cmp maph+1
        bcs @out
        sta qy+1                   ; (the +2 entry's A)
        memo_test @read            ; the memo's tile?
        lda mt
        jmp @attr
@read:  lda qy+1                   ; tilexy's, in line (as get_altitude's)
        tile_coord qy
        tax
        lda qx+1
        cmp mapw+1
        bcs @out
        tile_coord qx
        tay
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

; ---------------------------------------------------------------- level init
; ----------------------------------------------------------------------------
; level_init: the level's state from its loaded data (the loader has gathered the
; level into the banks: its header LV_HDR, its objects LV_OBJS in main RAM)
;   In:    LV_HDR (HDR_STARTX..HDR_EXITY the start and the exit in tiles, HDR_NOBJ),
;          LV_OBJS (nobj records of OBJ_BYTES: type, x, y in tiles, e0, e1, e2),
;          maplw (map_row's), MROWL/H's room
;   Out:   startx..exity, nobj, gridsh, MROWL/H (every row's address), cam_off;
;          the object arrays (O_*) and the collision grid (LV_GRID, LV_BOBJ,
;          LV_BNEXT) built; px, py = the start; vx, vy, anim, facing, running,
;          firing, bactive, exiting, frame = 0; hurt, control = 1; ev_frame =
;          frame; bin_ok, mok, dxl, dyl, star_clk, stars, bent cleared then stars
;          counted; Y = 1 (game.s stores it into bar_dirty)
;   Uses:  A X Y, t16, t16b, q1..q5, gx, gy, gx0, gx1, gy1, obj, otype, map_ptr
;   Pre:   bank 7 paged; interrupts may run (map_row pages bank 5 and back)
; Each object's record goes into the O_* arrays (its type, its position in game
; pixels, and by type its e-fields into the state words); the state words A..E
; start at zero but for what the type's case sets.  Its collision box, in grid
; cells (gx0..gx1, gy..gy1: a cell is 8 tiles), defaults to the tile it stands on
; and the one left of it, (x-1)>>3..x>>3, y>>3..(y+1)>>3, widened by type to what
; the object can reach; the object is chained into every cell of the box (LV_GRID
; heads a cell's chain, LV_BOBJ/LV_BNEXT the entries, GRID_NONE the end).
; game_frame walks the cells under the window to find the objects in play.
; ----------------------------------------------------------------------------
level_init:
        .assert starty = startx+2 && exitx = startx+4 && exity = startx+6, error, "level_init: the start and exit words in a row"
        .assert HDR_STARTY = HDR_STARTX+1 && HDR_EXITX = HDR_STARTX+2 && HDR_EXITY = HDR_STARTX+3, error, "level_init: the header's four in a row"
        ldy #2*(HDR_EXITY-HDR_STARTX) ; exity down to startx: Y = 2 * the field
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
        ; ---- the state cleared: the objects' arrays, then the grid
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
@clr:   sta (t16),y
        iny
        bne @clr
        inc t16+1
        dex
        bne @clr
        dex                        ; X = $FF: the loop left X = 0
        txa                        ; A = $FF = GRID_NONE: every cell empty
        .assert GRID_NONE = $FF, error, "level_init fills the grid with X's $FF"
:       sta LV_GRID-GRIDN,x        ; X = $FF..$80: LV_GRID+127 down to +0
        dex
        bmi :-
        ; ---- the objects, last to first
        ldy nobj
        jmp @nextobj+2             ; to the loop's beq @objdone (ldy obj is 2 bytes: obj
                                   ;  is zero page); Z is ldy nobj's
@ol:    dey
        sty obj
        ; the record: t16 = LV_OBJS + obj*OBJ_BYTES (6: 2obj + obj, doubled)
        .assert OBJ_BYTES = 6, error, "level_init: the entry's address is obj * 6 by shifts and an add"
        lda #(>LV_OBJS) >> 2       ; t16+1's seed: the two rols make it (>LV_OBJS) & $FC
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
        ldazx t16                  ; lda (t16), Y kept (= obj; X is free until @x8's)
        sta otype
        sta O_TYPE,y
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
        .assert 16*OBJ_MAX <= OBJCLR_PAGES*256, error, "level_init's clear must cover O_AL..O_EH"
        ; the box's defaults: gx0 = (x-1)>>3, gy = y>>3, gx1 = x>>3, gy1 = (y+1)>>3
  .if BHW                          ; (CPU spelling: max(q1-1, 0) through X, dead here)
        ldx q1
        beq @g0
        dex
@g0:    txa
  .else
        lda q1
        beq @gmax                  ; 0 stays 0, else A - 1
        dec a
  .endif
@gmax:  lsr
        lsr
        lsr
        sta gx0
        lda q1
        lsr
        lsr
        lsr
        sta gx1
        ldx q2                     ; (X is dead: @box sets it before use)
        txa
        lsr
        lsr
        lsr
        sta gy
        inx                        ; y + 1 (8-bit, as the original's)
        txa
        lsr
        lsr
        lsr
        sta gy1
        ldy obj
        lda otype                  ; A = otype for the cmps below; X counts it down
        tax                        ;  (X is dead: the cases and @box set it first)
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
:       cmp #OT_FLAME
        bne :+
        jmp @t9
:       cmp #OT_VANISH
        bne :+
        jmp @t11
:       cmp #OT_SWITCH
        bne :+
        jmp @t12
:       jmp @t10                   ; OT_SPIKE, OT_POWERUP: the defaults, and e0, e1 into E
@t0:    jsr rnd                    ; (drawn as the original did, so the enemies' draws
        lda q5                     ;  follow as they were)
        sta O_AL,y                 ; A = e2: its phase in the spin (the packer's, balanced
        inc stars                  ;  over the stars a screen shows at once)
        lda gy                     ; gy1 = y>>3 (the prologue's gy), gy = (y-1)>>3
        sta gy1
        lda q2
        beq :+
        deca                       ; A - 1; the carry is dead (lsr follows)
:       lsr
        lsr
        lsr
        sta gy
        jmp @t10                   ; e0 (the box id: 0 none), e1 (an enemy's range covers
                                   ;  it) into E
@t1:    lda O_XL,y
        ora #TILEPX/2              ; a trampoline stands at 8x + 4: x*8 has bit 2 clear,
        sta O_XL,y                 ;  so the + 4 cannot carry into O_XH
        lda q1
        submin0 2
        lsr
        lsr
        lsr
        sta gx0                    ; gx0 = (x-2)>>3, gx1 = (x+1)>>3, gy = gy1 = (y+1)>>3
        lda q1
        inca                       ; A + 1; the carry is dead (lsr follows)
        lsr
        lsr
        lsr
        sta gx1
        lda gy1
        sta gy
        jmp @t10                   ; e0 (its rest state's baked box id: 0 none), e1 (an
                                   ;  enemy's range covers it) into E, as a star's
@t256:  lda q3                     ; the green snake, the mask, the mummy: A = e0 in game
        jsr @x8                    ;  pixels (its path's far end); gx1 = (x + e0)>>3
        ldy obj
        sta O_AL,y
        txa
        sta O_AH,y
        jmp @g1                    ; @t4's tail, then @box
@t3:    lda q2                     ; the red snake: gy = (y-4)>>3 (it rises)
        submin0 4
        lsr
        lsr
        lsr
        sta gy
        jmp @box
@rm:    ora #1                     ; A + 1 for mod16: the low nibble is clear, so no carry
        sta t16b
        jsr rnd                    ; t16 = rnd16 & $0FFF, then t16 mod t16b
        sta t16
        jsr rnd
        and #$0F
        sta t16+1
        jmp mod16                  ; (it returns C = 0: bcc -> rts)
@t4:    lda q3                     ; the bat: A = e0*16 and B = e1*16, its chase's limits;
        lsr                        ;  C = rnd mod (A+1), D = rnd mod (B+1) its velocity
        lsr                        ;  (A, B < 4096: rnd16 & $0FFF, reduced by mod16)
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
        jsr @rm                    ; B + 1, likewise
        lda t16
        sta O_DL,y
        lda t16+1
        sta O_DH,y
        lda q2                     ; gy = max(y-1, 0)>>3, gy1 = (y + e1)>>3
        beq :+
        sbc #0                     ; C = 0 from mod16's exit (bcc -> rts): A - 1
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
@g1:    lda q1                     ; (@t256 joins here) gx1 = (x + e0)>>3
        clc
        adc q3
        lsr
        lsr
        lsr
        sta gx1
        bpl @box                   ; N = 0 after lsr
@t11:   lda gy                     ; the vanishing block: gy1 = gy
@gy1:   sta gy1
        bpl @box                   ; gy = q2>>3 < 32: N = 0
@t9:    lda q2                     ; the flame: gy = (y-2)>>3, gy1 = y>>3
        submin0 2
        lsr
        lsr
        lsr
        ldx gy                     ; the prologue left y>>3 in gy: that is gy1
        sta gy
        txa                        ; (X is dead: @box loads it)
        bpl @gy1                   ; gy was q2>>3 < 32: N = 0
@t12:   lda q3                     ; the switch: A, B, C = e0, e1, e2 (its map columns)
        sta O_AL,y
        lda q4
        sta O_BL,y
        lda q5
        sta O_CL,y
@t10:   lda q3                     ; e0, e1 into E: a star's or a trampoline's box id and
        sta O_EL,y                 ;  "an enemy can reach it", a powerup's box id
        lda q4                     ;  (assets.py); the spike and the switch never read E
        sta O_EH,y
        ; ---- into the grid: cells gx0..gx1 x gy..gy1.  gy <= gy1 for every object
        ; of the 16 levels (no wrap: maps are at most 128 tiles high, and the bat's
        ; extents keep q2 + q4 < 256): at least one grid row
@box:
@bx:    grid_rowbase               ; gx = gx0; A = gy << gridsh: the row's first cell.
        clc                        ;  The gx loop steps the cell index with inx
        adc gx                     ;  instead of reshifting
        tax
@cell:  ldy bent                   ; a new chain entry: this object, linked ahead of the
        lda obj                    ;  cell's chain
        sta LV_BOBJ,y
        lda LV_GRID,x
        sta LV_BNEXT,y
        tya
        sta LV_GRID,x
        inc bent
        inx                        ; the next cell (X and gx are dead past the row: @bx,
        lda gx                     ;  @ol and the bin walk reload them)
        inc gx
        cmp gx1                    ; the cell just filled was gx1: the row is done
        bne @cell
        inc gy
        lda gy1                    ; C set <=> gy <= gy1: another grid row
        cmp gy
        bcs @bx
@nextobj:
        ldy obj
        beq @objdone
        jmp @ol
@objdone:
        ; ---- Cleo's state
        .assert vx = px+4 && anim = vx+4, error, "level_init: @ps copies px..vx and zeroes vx..anim with one count"
        ldx #vx-px                 ; px, py = startx, starty; vx, vy, anim = 0 (Y = 0 on
@ps:    lda startx,x               ;  both ways in: ldy nobj / ldy obj).  X = 4 copies
        sta px,x                   ;  exitx's low byte into vx and clears anim; X = 1
        sty vx,x                   ;  and 0 clear vx again after
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
; ---- @x8: A = tiles -> A/X = game pixels lo/hi (x8); Y clobbered
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

; ----------------------------------------------------------------------------
; mod16: t16 = t16 mod t16b
;   In:    t16 (unsigned, < 4096), t16b (>= 1)
;   Out:   t16 = the remainder; C = 0
;   Uses:  A X
; By repeated subtraction: level_init's bat (@rm), whose t16 is at most 4095 and
; t16b at least 1 -- a few thousand passes at the very worst, at a level's start.
; ----------------------------------------------------------------------------
mod16:
        lda t16
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

; ---------------------------------------------------------------- the frame
; ----------------------------------------------------------------------------
; game_frame: one logic step -- two of the original's -- for a rendered frame
;   In:    keys; the game's state; bank 7 paged
;   Out:   frame + 1; star_clk stepped; wx, wy (the camera, clamped) while alive;
;          the objects in the window processed (their state, the sprite list, the
;          score, bar_dirty, sfx_req); then Cleo's step (player_update, or
;          player_dead); exiting set when the level ends
;   Uses:  A X Y, everything the handlers use (ZPGAME's scratch, spx/spy)
;   Post:  bank 7 paged
;   Cost:  measured 680 (Model B) / 740 (Master) cycles a frame in this routine's
;          own lines (test/linecyc.mjs, L0/4/8/10, 60 frames, 4 Oct 2026); the
;          logic as a whole 5.1K / 5.5K, 6.8% / 7.3% of the frame
; The objects run before Cleo: a stomp sets bounce, a trampoline her vy, for her
; step to take; her kill-tile test sits between them.  The objects are found by
; the collision grid -- the cells under the window, gx0..gx1 x gy..gy1 (a cell is
; BINPX px; the window's right and bottom edges are WINPX-1 and VISLINES/2-1 in,
; the latter the window's height in game pixels) -- and the walk's result is cached:
; LV_GRID/LV_BOBJ/LV_BNEXT and every O_TYPE are written only by level_init, so the
; list depends on nothing but the rectangle, which stands still on most frames
; (the old measurement: 77% on L0, 95% on L6).  Order is preserved exactly, as it
; sets the sprite draw order (box stars depend on it: convert.py).  The stars have
; a list of their own (LV_BINSTAR), run through po_star with no type read; the
; rest (LV_BINOTH) go through process_object.  A list that fills up (BINMAX)
; processes the object at once and asks for a rebuild next step rather than lose it.
; The stamp (O_STAMP = frame's low byte) dedupes an object chained into several
; cells; it is only read on a rebuild, and a stamp 256 steps stale would match --
; so the run lists write it every step too.
; ----------------------------------------------------------------------------
game_frame:
        inc frame
        bne :+
        inc frame+1
:
  .if BHW                          ; (CPU spelling: bounce = 0 first, its 0 in A for the
        lda #0                     ;  clock's wrap; the Master clears it after with stz)
        sta bounce
  .endif
        ldx star_clk               ; the stars' clock: a step a frame, 0..STARCLK-1
        inx
        cpx #STARCLK
        bcc @sc0
  .if BHW                          ; (CPU spelling)
        tax                        ; A = 0 (lda #0 above)
  .else
        ldx #0
  .endif
@sc0:   stx star_clk
  .if .not BHW                     ; (CPU spelling)
        stz bounce                 ; A is dead: lda health follows
  .endif
        ; ---- the camera (alive: a death leaves the window where it was)
        lda health
        beq @cam
        ; the lookahead: ease the window's bias toward CAM_AHEAD_R (facing right, so
        ; Cleo sits a quarter in from the left and sees ahead) or CAM_AHEAD_L (left,
        ; three quarters) by two pixels a frame -- one character -- so she drifts
        ; without a visible snap.  (cam_off starts at WINPX/2 and moves by 2: it stays
        ; even, as both targets are.)
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
@offok: lda px                     ; wx = px - cam_off
        sec
        sbc cam_off
        sta wx
        lda px+1
        sbc #0
        sta wx+1
        lda py                     ; wy = py - CAM_Y: Cleo CAM_Y px from the window's top
        sec
        sbc #CAM_Y
        sta wy
        lda py+1
        sbc #0
        sta wy+1
        jsr clamp_window
@cam:
        setbank BANK_LVL, BANK_LVL
        ; ---- the grid cells under the window (16-bit >> 6: a cell is BINPX = 64 px)
        bin_range wx, gx0, gx1, WINPX-1
        bin_range wy, gy, gy1, VISLINES/2-1
        ; ---- the object list: cached while the rectangle stands
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
        jmp @runlist               ; (the walk between here and it is too far for a branch)
@rebuild:
        lda gx0
        sta bin_r
        lda gx1
        sta bin_ok                 ; the list's gx1 (bin_r+1 is not used)
        lda gy
        sta bin_r+2
        lda gy1
        sta bin_r+3
        zero bin_nstar, bin_noth
@rows:  grid_rowbase               ; gx = gx0; A = gy << gridsh, once a row
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
        bne @apo                   ;  rebuild as on a cached step, so the two take the
        ldx bin_nstar              ;  same path through the handlers.  Stars go in their
        cpx #BINMAX                ;  own list: the run then reaches ob_star without
        bcs @full                  ;  reading the type or going through the table.
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
        sty obj                    ;  now and rebuild next step rather than lose it
        jsr process_object
        setbank BANK_LVL, BANK_LVL, 2
@skip:  ldx bent
@sk2:   lda LV_BNEXT,x
        jmp @walk
@cellend:
        lda gx
        cmp gx1
        beq @rowend
        inc gx
        bne @cells                 ; gx < gx1 <= 255: never 0
@rowend:
        lda gy
        cmp gy1
        beq @runlist
        inc gy
        jmp @rows
@runlist:
        ldx #0                     ; the stars (test at the bottom: bin_i kept in step
        cpx bin_nstar              ;  with X)
        beq @rlo
@rls:   stx bin_i
        ldy LV_BINSTAR,x
        lda frame
        sta O_STAMP,y
        jsr po_star                ; no type read, no table, no obj (nothing a star runs
        ldx bin_i                  ;  reads it)
        inx
        cpx bin_nstar
        bne @rls
@rlo:   ldx #0                     ; the rest
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
        ; ---- after the objects: a stomp's bounce, the kill tile under her
        lda bounce
        beq @nobnc
        stz vy                     ; vy = JUMP_VY (its low byte is 0)
        lda #>JUMP_VY
        sta vy+1
@nobnc: lda health                 ; dead: nothing hits.  (It was health <> 0 OR hurt = 0:
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
        lda facing                 ; the knockback by facing: 0 or 1 (1 = left)
        lsr                        ; C = facing
        ror                        ; A = facing << 7: player_hit tests only hx+1's sign
        sta hx+1                   ;  (facing left -> hx negative -> vx = +KNOCK_VX)
        jsr player_hit
@nokill:
        lda health
        beq player_dead            ; in reach: player_hit, between, is 45 bytes (B)
        jmp player_update

; ----------------------------------------------------------------------------
; player_hit: an enemy or a kill tile touches her: a health off, knocked back
;   In:    hx+1's sign = the enemy's side (rx+1: negative, it is to her left)
;   Out:   health - 1; hurt, control = 1, 0; ev_frame = frame; vx = KNOCK_VX away
;          from it (0 with no health left), vy = JUMP_VY; bar_dirty = 1 (the HUD's
;          health); sfx_req = SFX_HIT
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
player_hit:
        mov16 ev_frame, frame
        lda #1                     ; bar_touch, in line
        sta bar_dirty
        sta hurt
  .if BHW                          ; (CPU spelling: A = 1 -> 0 for the stores below)
        lda #0
  .else
        dec a
  .endif
        sta control
        sta vx                     ; both knockback speeds and JUMP_VY have a zero low
        sta vy                     ;  byte
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

; ----------------------------------------------------------------------------
; player_dead: her step with no health: the fall, then the respawn
;   In:    px, py, vy; ev_frame = the death's frame; lives
;   Out:   py, vy (fall2); after RESPAWN_F frames: px, py = the start, health =
;          HEALTH_MAX, vx, vy, anim, dxl, dyl = 0, facing, running, firing = 0,
;          hurt, control = 1, bar_dirty = 1, lives - 1 -- or exiting = 1 with no
;          lives left (the level loop ends the game: game.s).  The dead sprite
;          added while falling.
;   Uses:  A X Y, dpx, q5, t16, spx, spy
; A tail call of game_frame's (beq player_dead).  The delta frame - ev_frame is
; unsigned: wrap-safe.
; ----------------------------------------------------------------------------
player_dead:
        jsr fall2                  ; vy and py: the original's two steps
        clc                        ; py += dpx: fall2 leaves A = dpx, X = dpx+1
        adc py
        sta py
        txa
        adc py+1
        sta py+1
        lda frame                  ; frame - ev_frame > RESPAWN_F (the original's 60
        sec                        ;  steps): respawn
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
        zero vx, vx+1, vy, vy+1, anim, dxl, dyl ; (a respawn is no move to sweep;
                                   ;  the Model B's one zero serves the three below too:
                                   ;  dec lives keeps A)
        dec lives
        bne @alive
        inc exiting                ; 0 here (the loop leaves on nonzero): game over
        rts
@alive: sta0 facing, running, firing ; A = 0 still
        lda #1
        sta hurt
        sta control
        sta bar_dirty              ; bar_touch, in line
@draw:  mov16 spx, px
        mov16 spy, py
        lda #SPR_CLEO_DEAD
        jmp add_sprite

; ----------------------------------------------------------------------------
; fall2, move2: the frame's vertical motion -- the original's two steps of velocity
; and move, summed into dpx
;   In:    vy
;   Out:   vy stepped (gravity); dpx = the two moves' sum, clamped to MAXFALL down
;          (up, -14 at most: TRAMP_VY through fall2), dpx+1 = its sign ($FF up, 0
;          down); A = dpx, X = dpx+1, Z = 0
;   Uses:  A X, q5, t16
; A step is its gravity, vy = (vy + GRAV) * 31 >> 5, then its move, (vy + 128) >> 8
; (MAXDWY0 down at most).  No position between the two is kept: player_update
; makes the whole move against the map, and the objects test the stretch it covered
; (dxl, dyl: csweep).  fall2: both steps with gravity (a fall, a death); move2: a
; jump's or a stand's -- the first move without it and the second with it only if
; rising (the original's second step took gravity on vy < 0).  q5 holds the first
; move.  Z = 0 on exit: fstep2 ends on a dex to $FF, an unequal cmp, or lda #MAXFALL.
; ----------------------------------------------------------------------------
fall2:
        jsr gravity
        jsr step1
        sta q5
        jmp move2g                 ; the second gravity and move: move2's rising tail
move2:
        jsr step1
        sta q5
        bit vy+1
        bpl fstep2
; ---- move2g: the second step's gravity (fall2's, and move2's when rising)
move2g: jsr gravity
; ---- fstep2: the second step's move, summed with the first (q5) into dpx
fstep2: jsr step1
        ldx #$FF                   ; X = dpx+1: $FF up, 0 down
        clc
        adc q5                     ; the two moves (-14..16: a byte, signed)
        bmi @st                    ; up
        inx
        cmp #MAXFALL+1
        bcc @st
        lda #MAXFALL
@st:    sta dpx
        stx dpx+1
        rts

; ----------------------------------------------------------------------------
; step1: a step's move from vy
;   In:    vy
;   Out:   A = (vy + 128) >> 8, signed, at most MAXDWY0 down
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
step1:
        lda vy                     ; C = the carry out of vy low + 128
        cmp #$80
        lda vy+1
        adc #0
        bmi @r
        cmp #MAXDWY0+1
        bcc @r
        lda #MAXDWY0
@r:     rts

; ----------------------------------------------------------------------------
; gravity: vy = (vy + GRAV) * 31 >> 5, the original's step of gravity
;   In:    vy (-2048..2480: gravity's fixed point)
;   Out:   vy
;   Uses:  A, t16
;   Keeps: X Y
; GRAV*31 - vy is -(vy + GRAV) + GRAV*32, so its >> 5 is the original's -(vy +
; GRAV) >> 5 plus GRAV, and vy plus it is (vy + GRAV) * 31 >> 5.  2480 - vy is
; 0..4528: positive, under 8192, its >> 5 a byte -- three left shifts of the 16-bit
; difference leave it in A.
; ----------------------------------------------------------------------------
gravity:
        sec
        lda #<(GRAV*31)
        sbc vy
        sta t16
        lda #>(GRAV*31)
        sbc vy+1                   ; A:t16 = 2480 - vy
.repeat 3
        asl t16                    ; three left shifts: A = (2480 - vy) >> 5, 0..141
        rol
.endrepeat
        adc vy                     ; C = 0: bit 13 of 2480 - vy, shifted out last
        sta vy
        bcc @hi
        inc vy+1
@hi:    rts

; ---------------------------------------------------------------- Cleo
; ----------------------------------------------------------------------------
; player_update: her step while alive -- the throw, the vertical move against the
; map, the friction and the run, the move across, the animation and timers, her
; sprite, the boomerang's flight, the exit
;   In:    keys; px, py, vx, vy, alt's state; qx = px (game_frame's kill-tile test
;          set it: the only way in); bounce taken by game_frame; the objects run
;   Out:   px, py, vx, vy, anim, facing, running, firing, hurt, control, alt; dxl,
;          dyl = her move (for next frame's csweep); the boomerang's bx, by, bvx,
;          bvy, bcnt, bactive, bdx, bdy; health = 0 off the map's bottom; sfx_req;
;          exiting = 1 in the exit's box; her sprite and the boomerang's added
;   Uses:  A X Y, qx, qy, q6, dpx, t16, pxs, pys, bmx, bmy, spx, spy, and
;          get_altitude's (the memo)
;   Pre:   bank 7 paged
;   Cost:  measured 845 cycles a frame in this routine's own lines on both machines
;          (test/linecyc.mjs, L0/4/8/10, 60 frames, 4 Oct 2026)
; The vertical move: fall2/move2 give the frame's dy (dpx) and the map is asked
; (get_altitude under her feet) until the move is made -- going up, back down a
; pixel at a time while the altitude says she is inside the ground; going down,
; the lesser of dy and the altitude, and where the altitude is short of dy, from
; there again (the altitude looks a tile ahead at most, and a frame's fall can
; reach it).  The move across is a pixel at a time with the altitude read at each:
; -1 or 1 is a slope's step, taken (py += alt, alt = 0), 0 the flat, 2 or more
; leaves her in the air (alt kept), and below -1 is a wall that stops her (vx = 0).
; No position between the frame's ends is kept; dxl, dyl record the whole move for
; the objects' swept tests next frame.
; ----------------------------------------------------------------------------
player_update:
        feet_alt                   ; alt = the altitude under her feet (qx = px already)
        bne @nothrow               ; a throw starts standing: alt = 0, down held, no
        lda keys                   ;  throw running, control, no boomerang out
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
        ; ---- the vertical velocity
        bmi16 vy, @grav            ; rising: gravity's step
        lda alt
        beq :+
        bpl @grav                  ; in the air: gravity's step
:       stz vy                     ; on the ground (or in it): vy = 0 or a jump's, JUMP_VY =
        ldx firing                 ;  $FB00 (low byte zero either way); X, so A stays 0
        bne @stand                 ;  (the Model B's stz is lda #0)
        lda control
        beq @stand
        lda keys
        and #(K_UP|K_FIRE)
        beq @stand
        lda #>JUMP_VY
        sta vy+1
        inx                        ; X = 1 = SFX_JUMP: firing, in X, tested 0 above
        .assert SFX_JUMP = 1, error, "player_update: the jump's sfx is firing + 1"
        stx sfx_req
        bne @move                  ; always: X = 1
@grav:  jsr fall2
        bne @mvd                   ; always: fstep2 returns Z = 0
@stand:
  .if BHW                          ; (CPU spelling: A = 0 on every way in on the B,
        sta vy+1                   ;  whose stz at ':' is lda #0; the Master's stz
  .else                            ;  keeps A = alt -- negative in the ground -- on
        stz vy+1                   ;  the firing way, so its sta would store alt)
  .endif
        lda #1
        sta control                ; and on into move2
@move:  jsr move2
@mvd:   txa                        ; X = dpx+1, 0 or $FF (fall2/move2)
        bpl @down
        clc                        ; ---- up: py += dpx (dpx+1 = $FF), then back down
        lda py                     ;  while inside the ground
        adc dpx
        sta py
        bcs @upl
        dec py+1
@upl:   feet_alt
        bpl @vdone
        inc py
        bne @upl
        inc py+1
        bpl @upl                   ; py+1 < $7F
@dland: sta dpx                    ; alt 0: on the ground, dy = 0 (alt and py stand)
        beq @vdone                 ; always: A = 0
@dlp:   tax                        ; 0 < alt <= dy: the altitude looks a tile ahead at
        clc                        ;  most, and a frame's fall (12) can reach it -- go
        adc py                     ;  alt, and look again from there (else she stops
        sta py                     ;  short, alt 0 in the air: the standing frame)
        bcc :+
        inc py+1
:       lda dpx
        stx dpx
        sec
        sbc dpx
        sta dpx                    ; dy - alt
        feet_alt
@down:  lda alt                    ; ---- down: dy = min(dy, alt); dpx+1 = 0 here
        beq @dland
        cmp dpx
        beq @dlp
        bcc @dlp                   ; alt > dy (unsigned) falls on, C = 1
        sbc dpx                    ; C = 1: cmp's no borrow
        sta alt
        clc                        ; py += dpx
        lda py
        adc dpx
        sta py
        bcc @vdone
        inc py+1
@vdone:
        sec                        ; off the map's bottom: maph - py - CLEO_H < 0
        lda maph
        sbc py
        tay
        lda maph+1
        sbc py+1
        cpy #CLEO_H
        sbc #0
        bpl @push
        mov16 ev_frame, frame      ; fell: dead (no health, control lost, stopped)
        zero health, control, vx, vx+1
        jsr bar_touch
        lda #SFX_DIE
        sta sfx_req
@push:  feet_qy                    ; the tile under her feet: its push
        jsr get_tile_attr
        and #PUSH_MASK
        sec
        sbc #PUSH_BIAS
        sta q6                     ; the push (-2..2, PUSH_NONE = none)
        ; ---- friction
        ldx control                ; X, not A: A keeps q6 for the push test
        beq @nofric
        ldx alt
        beq :+
        bpl @air
:       cmp #PUSH_NONE             ; A = q6 (the push), still
        beq @air
        ; the ground's: vx = vx*58>>6 + push*48 (two of the original's vx*61>>6 +
        ; push*24), as vx - ceil(3w/32) with w = vx - 512p: 3w = 3vx - 1536p, whose
        ; 32nds are 3vx's less 48p exactly (the push folded in; |3w| < 32768 as |vx| <
        ; 1820, |p| <= 2)
        asl                        ; A = q6 (the push), still: 2p
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
.repeat 3
        asl t16                    ; the 24 bits left by three: t16+1:A = floor(3w/32),
        rol                        ;  t16 = the dropped bits, (3w & 31) << 3
        rol t16+1
.endrepeat
        ldy #0
        cpy t16                    ; C = nothing dropped: floor = ceil
        eor #$FF
        adc vx                     ; vx + ~floor + C = vx - ceil(3w/32)
        sta vx
        lda vx+1
        sbc t16+1
        sta vx+1
        jmp @nofric
@air:   lda vx                     ; the air's: vx = vx*3>>3 (two of the original's vx*5>>3)
        asl                        ;  as asr3(3vx); 3vx fits 16 bits
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
.repeat 3
        cmp #$80                   ; 3vx >> 3 signed: C = the sign (A >= $80), rolled in
        ror
        ror vx
.endrepeat
        sta vx+1
@nofric:
        ; ---- the run
        lda control
        beq @norun
        lda keys
        and #(K_LEFT|K_RIGHT)
        beq @norun
        eor #(K_LEFT|K_RIGHT)      ; A = 2 left, 1 right; both held: A = 0, as on the
        beq @norun                 ;  other two ways to @norun
        .assert K_LEFT = 1 && K_RIGHT = 2, error, "player_update: the run's table index is the key bits"
        tax                        ; X = 2 left, 1 right: @acctab's index
        lsr                        ; A = 1 left, 0 right: the facing flag
        sta facing
        lda running
        ora firing
        bne :+
        sta anim                   ; A = running|firing = 0: a run starts its anim over
:       lda alt                    ; the acceleration: ACC_AIR in the air or with no push,
        beq :+                     ;  else ACC_GROUND -- two of the original's 288 and 36,
        bpl @acc480                ;  through its friction (each pairs with one: 480 with
:       lda q6                     ;  vx*3>>3, 72 with vx*58>>6), which hold the original's
        cmp #PUSH_NONE             ;  top speed, KNOCK_VX (768), exactly
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
        ; ---- the move across: steps = ((vx + 128) >> 8) * 2, the frame's two; dir =
        ; its sign; a step at a time against the altitude
        lda vx
        cmp #$80                   ; C = carry out of vx_lo + 128, without the clc
        lda vx+1
        adc #0                     ; A = high byte of vx + 128
        asl                        ; two steps' (|A| < 64)
        sta dpx
        beq @hdone                 ; dpx = 0: dpx+1 is dead after @hdone (the fall rewrites it)
        and #$80
        beq :+
        lda #$FF
:       sta dpx+1                  ; qx = px and qy = py + CLEO_FEET already, set at @push
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
        bne @wall                  ; below -1: a wall
@hok:   ldx qx                     ; px += dir: qx is px + dir already
        stx px                     ; (X is free: A still holds the altitude)
        ldx qx+1
        stx px+1
        ; a <= 1: py += a, alt = 0 (a = -1 steps up a slope); else alt = a
        tax                        ; N from the altitude
        bmi @stepn
        cmp #2
        bcs @alt
        adc py                     ; C is clear from the cmp: 0 or 1, addend high byte 0
        sta py
        bcc @alt0
        inc py+1
        bcs @alt0                  ; always: C = 1, the adc's carry
@stepn: clc                        ; negative: high byte of the addend is $FF
        adc py
        sta py
        bcs @alt0                  ; no borrow (255 times in 256): py+1 is unchanged
        dec py+1
@alt0:  lda #0                     ; alt = 0 (A is dead: @hnext reloads it)
@alt:   sta alt
@hnext: ldx dpx+1                  ; steps -= dir; X holds the direction for @hl (X is
        bmi @hinc                  ;  dead here)
        dec dpx
        bpl @hcnt                  ; always: dpx was 1..$7F, so N is clear
@hinc:  inc dpx
@hcnt:  beq @hdone                 ; Z survives from the inc/dec
@hl:    feet_qy                    ; (qx = px already: @hok set px to it)
        txa                        ; dpx+1, still in X: N for @hstep
        jmp @hstep
@wall:  zero vx, vx+1              ; (A is dead: @hdone reloads)
@hdone: lda px                     ; dxl, dyl: her move this frame, all of it (across;
        sec                        ;  down: the fall, a slope's step), the stretch the
        sbc pxs                    ;  objects' tests sweep next frame (csweep)
        sta dxl
        lda py
        sec
        sbc pys
        sta dyl
        ; ---- the animation counter: two steps a frame (every test is of an even count)
        inc anim
        inc anim
        lda anim                   ; anim in A for every test below; the flags come
        ldx firing                 ;  through X (X is dead: written before any read below)
        beq @notfiring
        cmp #THROW_T1
        bne @tend
        mov16 bx, px               ; the launch: the boomerang from her place, BOOM_VX
        mov16 by, py               ;  her way
        zero bvx, bvy, bvy+1, bcnt
        lda #>BOOM_VX
        ldx facing                 ; (X is dead: written before any read below)
        beq @bdir
        lda #>(-BOOM_VX)
@bdir:  sta bvx+1
        inc bactive                ; 0 here: a throw starts only with bactive clear
        lda #SFX_THROW
        sta sfx_req
        bne @animdone              ; always: SFX_THROW <> 0
@tend:  cmp #THROW_END
        bne @animdone
        stz01 firing               ; 1 -> 0 (firing is only ever 0 or 1): Z = 1 on both
        beq @animdone              ;  (the Model B's dec; the cmp #THROW_END, which stz keeps)
@notfiring:
        ldx running                ; A = anim still
        beq @idle
        cmp #RUN_ANIM
        bne @animdone
        beq @zanim                 ; always: Z = 1 from the cmp #RUN_ANIM
@idle:  cmp #IDLE_ANIM
        bne @animdone
@zanim: stz anim
@animdone:
        ; ---- the timers: hurt clears after HURT_F frames (the original's 64 steps),
        ; control comes back after CTRL_F; the deltas unsigned, so they work across the
        ; 16-bit frame wrap (a signed compare stuck the flashing state)
        lda hurt
        beq @afterhurt
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
        bne @ctl                   ;  high byte was zero: reuse it for the control
        cpx #CTRL_F                ;  timer instead of subtracting frame-ev_frame twice
        bcc @noctl
        bcs @setctl                ; always
@afterhurt:
        lda control
        bne @ctl
        beq @hdelta                ; always: with hurt 0 the tests above decide the
                                   ;  control alone (@clrhurt finds hurt 0 already)
@clrhurt:
        stz hurt
        lda control                ; the delta is past HURT_F, so past CTRL_F: set
        bne @ctl                   ;  control if clear, as a second subtraction would
@setctl:
        inc control                ; control is 0 on every way in
        bne @ctl                   ; always: it is 1 now
@noctl: ldx #SPR_CLEO_MID          ; ---- her sprite.  Control lost: the mid-air frame,
        lda vx+1                   ;  facing the knock
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
@spr:   sta cleo_id                ; her body for the objects' next test (body_hit)
        ldy hurt                   ; the frame stays in A (Y is dead: see below)
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
        ; ---- the boomerang: one flight step a frame.  Its move is made BOOM_STEP
        ; px at most at a time, stopping in the first solid, so it cannot fly
        ; through a wall; the catch, like the objects' hits (bsweep), tests the box
        ; between where it was and where it is -- no position between a frame's
        ; ends is tested.
@boom:  lda #0
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
@bm:    lda bmx                    ; a part of the move: BOOM_STEP px at most each way
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
        bpl @bmore
        lda #BCNT_HIT
        sta bcnt
        bne @bcount                ; always
@bmore: lda bmx
        ora bmy
        bne @bm
@bcount:
        lda bcnt                   ; two counts a frame: in flight 0, 2, 4, 6 and round
        clc                        ;  again (its spin); hit or stopped, from BCNT_HIT to
        adc #2                     ;  BCNT_GONE, gone
        cmp #BCNT_HIT
        bne :+
        lda #0
:       sta bcnt
        cmp #BCNT_GONE
        bne @bcatch
        lda #0
        sta bactive
        beq @bdone                 ; always
@bcatch:
        jsr brel                   ; caught?  The box it crossed meets Cleo's: rx, ry
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
        lsr                        ; (bcnt + 2*SPR_BOOM0) >> 1 = bcnt/2 + SPR_BOOM0: its 7 frames
        .assert BCNT_GONE/2 = SPR_BOOM_N, error, "player_update: the boomerang's frames are its count halved"
        jsr add_sprite
@bdone:
        ; ---- the exit reached?  Inside its box is 0 <= px-exitx < EXIT_W and 0 <=
        ; py-exity < EXIT_H: one 16-bit subtract each, high byte zero (so the difference
        ; is 0..255) and low byte under the width
        lda px
        sec
        sbc exitx
        tax
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

; ---- the boomerang's flight: player_update's helpers (@bfly, @bm)
; ----------------------------------------------------------------------------
; bstep: the boomerang's flight on one axis -- the original's two steps of drag and
; pull in one, and the move they give
;   In:    X = 0 (x) or 2 (y); bvx,x = the velocity; rx,x = Cleo less the boomerang
;          on the axis (brel)
;   Out:   bvx,x -= bv/16 + bv/64 + bv/128 (11/128: near two steps of 61/64, whose
;          drag is 0.092), += 4*r (the pull);
;          A = the move, 2 * ((bv + 128) >> 8), signed
;   Uses:  A Y, t16
;   Keeps: X
; Against the original's two steps, thrown on the flat: 108 px out to its 105, back
; the same frame; its drift down settles at 10 px to its 9 (the old measurement).
; The move is the original's step's, twice -- as its two steps rounded it (a slow
; pull stays put until it would move a pixel a step).
; ----------------------------------------------------------------------------
bstep:
        lda bvx+1,x                ; t16 = bv >> 4 (arithmetic): four rotates of the
        sta t16+1                  ;  pair, the sign rolled in from a cmp #$80
        lda bvx,x
        ldy #4
@shr:   pha
        lda t16+1
        cmp #$80
        ror
        sta t16+1
        pla
        ror
        dey
        bne @shr
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
        bne @d1
        lda t16+1
        cmp #$80
        ror t16+1
        ror t16
@d1:    dey
        bne @d
        lda rx,x                   ; bv += 4*r
        sta t16
        lda rx+1,x
        asl t16
        rol
        asl t16
        rol
        sta t16+1
        clc
        lda bvx,x
        adc t16
        sta bvx,x
        lda bvx+1,x
        adc t16+1
        sta bvx+1,x
        lda bvx,x                  ; A = 2 * ((bv + 128) >> 8)
        cmp #$80
        lda bvx+1,x
        adc #0
        asl
        rts

; ----------------------------------------------------------------------------
; brel: Cleo less the boomerang: rx = px - bx, ry = py - by + BOOM_REF_DY (her
; reference point is BOOM_REF_DY below the boomerang's: its pull and its catch)
;   In:    px, py, bx, by
;   Out:   rx, ry
;   Uses:  A X
;   Keeps: Y
; ----------------------------------------------------------------------------
brel:
        sec
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

; ----------------------------------------------------------------------------
; bmove: the boomerang moves on one axis, and the map query's pixel follows
;   In:    A = the move (signed byte), X = 0 (x) or 2 (y)
;   Out:   bx,x += A; qx,x = bx,x
;   Uses:  A Y
;   Keeps: X
; ----------------------------------------------------------------------------
bmove:
        ldy #0
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

; ----------------------------------------------------------------------------
; clamp8: A (signed) clamped to -BOOM_STEP..BOOM_STEP
;   In:    A, N from it (the caller's lda)
;   Out:   A
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
clamp8:
        bmi @n
        cmp #BOOM_STEP+1
        bcc @r
        lda #BOOM_STEP
        rts
@n:     cmp #<-BOOM_STEP
        bcs @r
        lda #<-BOOM_STEP
@r:     rts

; ---------------------------------------------------------------- the objects
; ----------------------------------------------------------------------------
; process_object: one object's step, by its type
;   In:    Y = obj = the object; its O_* fields; px, py
;   Out:   spx, spy = its position (where it draws), rx, ry = it less Cleo, otype;
;          then the handler's (its fields, the sprite list, the score, bounce,
;          player_hit's)
;   Uses:  A X Y and the handler's
;   Pre:   bank 7 paged
;   Cost:  measured 255 (Model B) / 270 (Master) cycles a frame, 3 calls
;          (test/linecyc.mjs, L0/4/8/10, 60 frames, 4 Oct 2026)
; Every type shares the prologue, then goes to its entry in the table (a tail
; dispatch: the handler returns to our caller).  The handlers work on the object's
; arrays in place (O_AL..O_EH,y) with Y the index -- reloaded from obj after
; anything that changes it (add_score and bar_touch, player_hit, a handler's own
; scratch) -- and stage into zero page only what they use hard (the bat's velocity,
; for its move and chase).  The vanishing block and the switch, rare and busy with
; Y over the map, have wrappers (os_*) that copy in and back just the fields they
; touch.  The stars' list skips this: po_star is their own prologue (ob_star is
; the table's entry, for a star that overflowed the list).
; ----------------------------------------------------------------------------
process_object:
  .if ::BHW                        ; (CPU spelling: the 6502 has no jmp (abs,x); the
        ldx O_TYPE,y               ;  index is the type, into split tables, through jv)
        stx otype
  .else
        lda O_TYPE,y
        sta otype
        asl                        ; X = otype*2, the dispatch index
        tax
  .endif
        objrel spx, O_XL, O_XH, px, rx
        objrel spy, O_YL, O_YH, py, ry
  .if ::BHW                        ; (CPU spelling; A is clobbered: every handler loads
        lda @tlo,x                 ;  it first)
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
        .assert OT_SWITCH = 12, error, "process_object: the table has an entry a type, 0..12"

; ----------------------------------------------------------------------------
; os_vanish: the vanishing block's wrapper (type OT_VANISH)
;   In:    Y = obj; O_EL,y its count
;   Out:   ob_vanish run twice (the frame's two steps); O_EL,y back from fe
;   Uses:  A X Y, fe, ox, oy, ob_vanish's
; ----------------------------------------------------------------------------
os_vanish:
        oin fe, O_EL
        jsr os_oxy
        jsr ob_vanish              ; the frame's two steps: its count's map writes fall
        jsr ob_vanish              ;  on every fourth
        ldy obj
        oout fe, O_EL
        rts

; ----------------------------------------------------------------------------
; os_switch: the switch's wrapper (type OT_SWITCH)
;   In:    Y = obj; O_AL, O_BL, O_CL,y its columns and rows, O_DL,y its state
;   Out:   ob_switch run on fa..fd; O_DL,y back from fd (fa..fc are only read)
;   Uses:  A X Y, fa..fd, ob_switch's
; Falls into ob_none's rts.
; ----------------------------------------------------------------------------
os_switch:
        oin fa, O_AL
        oin fb, O_BL
        oin fc, O_CL
        oin fd, O_DL
        jsr ob_switch
        ldy obj
        oout fd, O_DL
; ---- ob_none: type OT_NONE, nothing to do (and os_switch's rts)
ob_none:
        rts

; ----------------------------------------------------------------------------
; os_oxy: ox, oy = spx, spy -- the object's position, kept while a handler moves
; spx/spy (the red snake draws twice; the vanishing block maps its tiles)
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
os_oxy:
        oxy_set
        rts

; ----------------------------------------------------------------------------
; body_draw: a big enemy's hit on Cleo, by the frames drawn, then its sprite
;   In:    A = the enemy's sprite this frame; spx, spy = where it draws
;   Out:   Cleo hit (player_hit) if she is alive, not invulnerable, and body_hit
;          finds their bodies touching; the sprite added (add_sprite's tail)
;   Uses:  A X, body_hit's, player_hit's;  Y = obj on the way out
; For the enemies that cannot be stomped (the mask, the mummy, the red snake): a
; body is too big to pass in one frame's move, so where they are is tested, not
; the stretch moved (csweep), whose box overstates a diagonal move.
; ----------------------------------------------------------------------------
body_draw:
        pha                        ; the sprite, for add_sprite
        ldx health
        beq @draw                  ; dead: nothing touches her
        ldx hurt
        bne @draw                  ; invulnerable
        jsr body_hit
        bcc @draw
        lda rx+1                   ; knocked back from it: player_hit reads only
        sta hx+1                   ;  hx+1's sign
        jsr player_hit
@draw:  ldy obj
        pla
        jmp add_sprite

; ----------------------------------------------------------------------------
; body_hit: do Cleo's and an enemy's bodies touch, where both were drawn?
;   In:    A = the enemy's sprite; spx, spy = where it draws; cleo_id, px, py
;   Out:   C = 1 if the two frames' boxes, each pulled in on every side --
;          HIT_INSET_GROUND px, or HIT_INSET_AIR while Cleo is drawn in the air --
;          overlap;  rx, ry = the enemy less Cleo;  RNGTAB's RQ_BODY quad
;          written
;   Uses:  A X Y, swd, hit_k
; A frame's box is its shape's (sprgeom: sprg_ix) drawn extent about its
; reference point: across [-rx, 2w - rx), down [-ry, ln - ry) (w in byte columns of
; two pixels; ln stored rows, a pixel each: these shapes are not SPF_FULLRES).
; With each box pulled in k on every side, the enemy's at r and Cleo's at 0
; overlap iff, on each axis, Cleo's near edge < the enemy's far edge and the
; enemy's near edge < Cleo's far edge -- lo < r < hi with
;   lo = (rxE - rxC) - 2wE + 2k        hi = (rxE - rxC) + 2wC - 2k
; and so down (ry, ln for 2w): a quad, which in_range tests.  The sums are bytes,
; biased (RQ_BIAS) as in_range compares: every term is under 64.
; ----------------------------------------------------------------------------
body_hit:
        tax
        lda sprg_ix,x
        tax                        ; X = the enemy's shape
        ldy cleo_id
        lda #RQ_BIAS+2*HIT_INSET_GROUND
        cpy #SPR_CLEO_JUMP         ; her air frames (jump, mid-air, fall, dead) from
        bcc :+                     ;  here: the larger inset
        lda #RQ_BIAS+2*HIT_INSET_AIR
:       sta hit_k
        lda sprg_ix,y
        tay                        ; Y = Cleo's shape
        lda sprg_rx,x              ; ---- across: d = rxE - rxC
        sec
        sbc sprg_rx,y
        sta swd
        sec
        sbc sprg_w,x
        sec
        sbc sprg_w,x
        clc
        adc hit_k
        sta RNGTAB+RQ_BODY         ; lo = d - 2wE + 2k
        lda sprg_w,y
        asl                        ; (C = 0: w < 128)
        adc swd
        sec                        ; - (RQ_BIAS + 2k) = RQ_BIAS - 2k, mod 256
        sbc hit_k
        sta RNGTAB+RQ_BODY+1       ; hi = d + 2wC - 2k
        lda sprg_ry,x              ; ---- down: d = ryE - ryC
        sec
        sbc sprg_ry,y
        sta swd
        sec
        sbc sprg_ln,x
        clc
        adc hit_k
        sta RNGTAB+RQ_BODY+2       ; lo = d - lnE + 2k
        lda sprg_ln,y
        clc
        adc swd
        sec
        sbc hit_k
        sta RNGTAB+RQ_BODY+3       ; hi = d + lnC - 2k
        ldx #2                     ; ---- r = the enemy less Cleo: down, then across
        .assert spy = spx+2 && py = px+2 && ry = rx+2, error, "body_hit: the axes' pairs two bytes apart"
@r:     sec
        lda spx,x
        sbc px,x
        sta rx,x
        lda spx+1,x
        sbc px+1,x
        sta rx+1,x
        dex
        dex
        bpl @r
        ldx #RQ_BODY               ; falls into in_range

; ----------------------------------------------------------------------------
; in_range: is (rx, ry) inside a quad's open box?
;   In:    X = the quad's offset in RNGTAB (RQ_*: lo, hi, lo2, hi2, each + RQ_BIAS);
;          rx, ry (16-bit, signed)
;   Out:   C = 1 if rx > lo and rx < hi and ry > lo2 and ry < hi2
;   Uses:  A
;   Keeps: X Y
;   Cost:  measured 210 (Model B) / 235 (Master) cycles a frame, 5-6 calls (as
;          process_object's)
; The limits are stored + RQ_BIAS ($80) so each test is an unsigned byte compare
; of r ^ $80 -- after checking r fits in -128..127 (its high byte is 0 or $FF
; matching the low byte's sign: hi + (lo's sign bit) = 0 mod 256); anything wider
; is outside every limit anyway.
; ----------------------------------------------------------------------------
in_range:
        .assert RQ_BIAS = $80, error, "in_range biases r by an eor: RQ_BIAS must be $80"
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

; ---- the swept tests.  The collision rule: a mover hits an object by its whole
; last move, and no position between the move's ends is ever computed or tested.
; On each axis the stretch from r (the object less where the mover is) to r + d
; (the object less where it was: d is the move, end less start -- dxl/dyl, Cleo's,
; set by player_update; bdx/bdy, the boomerang's) is tested against the quad's
; open pair (span); a hit needs both axes' stretches to meet theirs -- the box the
; move spans meets the quad's box.  A move of zero is in_range's test.
; ----------------------------------------------------------------------------
; span: does the stretch r .. r + swd meet a quad's pair of limits?
;   In:    A = r low, Y = r high (signed 16-bit); swd = the stretch (signed byte);
;          X = the pair's offset in RNGTAB (lo at X, hi at X+1)
;   Out:   C = 1 if the stretch's high end > lo and its low end < hi (open)
;   Uses:  A Y, swlo, swhi, swa
;   Keeps: X
;   Cost:  measured 255 (Model B) / 280 (Master) cycles a frame, 3-3.5 calls (as
;          process_object's)
; Both ends are clamped and biased as in_range compares (rbias), the lesser kept
; in swa.
; ----------------------------------------------------------------------------
span:
        sta swlo
        sty swhi
        jsr rbias                  ; one end, biased
        sta swa
        lda swd                    ; the other: r + swd (swd sign-extended into Y)
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

; ----------------------------------------------------------------------------
; rbias: a signed 16-bit r clamped to -128..127, then biased by RQ_BIAS
;   In:    A = r low, Y = r high
;   Out:   A = the biased byte (a value past either end stays past every limit, as
;          in_range's test does)
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
rbias:
        cpy #$FF
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

; ----------------------------------------------------------------------------
; csweep: Cleo's test against an object, over her last move
;   In:    X = the quad (RQ_*); rx, ry = the object less Cleo; dxl, dyl = her move
;          this frame (where she was is r + d)
;   Out:   C = 1 if she is inside the quad's box, or the box between where she was
;          and where she is meets it (the corner a diagonal move cuts, the 8-px
;          trampoline band a 12-px fall would cross)
;   Uses:  A, sweep's
;   Keeps: X Y
; The stars, the trampolines, the snake, the bat and the spike: the objects a
; frame's move can pass, or whose stomp is told from the move.  (The box a diagonal
; move spans is bigger than the path: big enemies use body_hit instead.)
; ----------------------------------------------------------------------------
csweep:
        jsr in_range               ; where she is: the hits, and quick
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

; ----------------------------------------------------------------------------
; bsweep: the boomerang's hit test against an object, over its last move
;   In:    X = the quad (RQ_BOOM_*); rx, ry = the object less the boomerang
;          (boom_rel); bdx, bdy = its move this frame (where it was is r + bd)
;   Out:   C = 1 if the box between where it was and where it is meets the quad's
;   Uses:  A, sweep's
;   Keeps: X Y
; Falls into sweep.
; ----------------------------------------------------------------------------
bsweep:
        sty swy
        lda bdy
        sta swe
        lda bdx
; ----------------------------------------------------------------------------
; sweep: the two axes' spans
;   In:    A = the move across, swe = the move down, swy = Y to restore; X = the
;          quad; rx, ry
;   Out:   C = 1 if rx over A meets the quad's x pair and ry over swe its y pair
;   Uses:  A, swd, span's
;   Keeps: X (stepped to the y pair and back), Y (from swy)
; ----------------------------------------------------------------------------
sweep:
        sta swd
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

; ----------------------------------------------------------------------------
; boom_rel: the object less the boomerang: rx = spx - bx, ry = spy - by
;   In:    spx, spy (the object's draw position), bx, by
;   Out:   rx, ry
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
boom_rel:
        dif16 rx, spx, bx
        dif16 ry, spy, by
        rts

; ----------------------------------------------------------------------------
; boom_ready: is the boomerang in flight?
;   Out:   C = 1 if bactive and bcnt < BCNT_HIT
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
boom_ready:
        lda bactive
        beq @no
        lda #BCNT_HIT-1
        cmp bcnt                   ; C = (BCNT_HIT-1 >= bcnt) = (bcnt < BCNT_HIT)
        rts
@no:    clc
        rts

; ----------------------------------------------------------------------------
; add_score: score += A, and the HUD redrawn
;   In:    A = the points, BCD
;   Out:   score (3 bytes BCD, ones first); bar_dirty = 1 (bar_touch); A = 1
;   Uses:  A
;   Keeps: X Y
; Decimal mode for the add: every interrupt clears D for itself (low.s's stub on
; the Model B; the 65C02 by its own), so the mode cannot leak.
; ----------------------------------------------------------------------------
add_score:
        sed
        clc
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

; ---------------------------------------------------------------- the star (0)
; ----------------------------------------------------------------------------
; po_star: the star list's prologue and step (game_frame's @rls: no type read, no
; table)
;   In:    Y = the star; its O_* fields; px, py
;   Out:   spx, spy, rx = its position and it less Cleo; ry when Cleo is near; q2 =
;          1 if she is far, else 0; then ob_star1's
;   Uses:  A X Y, q1, q2, ob_star1's
;   Cost:  measured 265-300 cycles a frame here and 240-280 in ob_star1, 4.3-4.9
;          stars (test/linecyc.mjs, L0/4/8/10, 60 frames, 4 Oct 2026)
; Cleo's two tests on a star -- the collect (RQ_STAR) and box_safe's (RQ_GUARD_STAR,
; grown by a frame's move) -- can only pass with rx in STARBAND_LO..STARBAND_HI (the
; guard's x limits: assets.inc).  So rx is tested against that first, and outside
; it q2 = 1 says Cleo is far: both tests are skipped, and ry, which only they read,
; is not worked out.  The boomerang's tests set rx and ry themselves (boom_rel) and
; clear q2, as does every other way in.
; ----------------------------------------------------------------------------
po_star:
        lda O_YL,y
        sta spy
        lda O_YH,y
        sta spy+1
        objrel spx, O_XL, O_XH, px, rx ; A = rx+1
        beq @pos
        cmp #$FF
        bne @far
        lda rx
        cmp #<STARBAND_LO
        bcs @near                  ; STARBAND_LO..-1
@far:   lda #1
        bne star_q2                ; always
@pos:   lda rx
        cmp #STARBAND_HI+1
        bcs @far                   ; 0..STARBAND_HI fall through
@near:  lda spy
        sec
        sbc py
        sta ry
        lda spy+1
        sbc py+1
        sta ry+1
; ----------------------------------------------------------------------------
; ob_star: the table's entry (a star that overflowed the list: rare)
;   In:    Y = obj; rx, ry = process_object's
;   Out:   q2 = 0 (Cleo may be near); then ob_star1's
; ----------------------------------------------------------------------------
ob_star:
        lda #0
; ---- star_q2: q2 = A (po_star's far flag)
star_q2:
        sta q2
; ---- ob_star1: the star's step.  Fields: A (O_AL) its phase in the spin, then a
; collected star's sparkle count; C (O_CL) 1 = collected; E (O_EL) its baked box id
; (0: none), O_EH "an enemy's range covers it" (box_safe reads it)
ob_star1:
        lda O_CL,y
        beq @live
        lda O_AL,y                 ; collected: the sparkle, its own count SPARKLE0..
        cmp #SPARKLE_END           ;  SPARKLE_END, a step a frame (the original's on even
        bcs @anim                  ;  steps); capped: a wrapped count would show the
        adc #1                     ;  star again (C = 0: the bcs was not taken)
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
        bne @tbr                   ;  (Cleo far: q2 says so already)
        ldx #RQ_GUARD_STAR
        jsr in_range               ; C = 1: she overlaps the box's guard band
        lda #2                     ; q2: 1 safe of her, $81 not (box_safe reads only its
        ror                        ;  sign and zero): C in at the top
        sta q2
@tbr:   jsr boom_rel
        ldx #RQ_BOOM_STAR
        jsr bsweep
        bcc @phase
@collect:
        lda #SCORE_STAR            ; (1: O_CL = 1 says collected, and the score)
        .assert SCORE_STAR = 1, error, "ob_star: one load marks the star collected and scores it"
        sta O_CL,y
        dec stars
        jsr add_score              ; A = SCORE_STAR still; it ends in jmp bar_touch (Y kept)
        lda #SFX_STAR
        sta sfx_req
        lda #SPARKLE0              ; the sparkle's first step: its count, and A for @anim
        sta O_AL,y
        bne @anim                  ; always
@phase: lda O_AL,y                 ; the spin: the level's star clock plus this star's
        clc                        ;  phase (A, the packer's), mod STARCLK -- a star out
        adc star_clk               ;  of the bin window keeps its place in step
        cmp #STARCLK
        bcc @spin                  ; A < STARCLK: the cmp #SPARKLE_END cannot pass
        sbc #STARCLK               ; C = 1: the bcc was not taken
@anim:  cmp #SPARKLE_END
        bcs @done
@spin:  lsr                        ; the frame: the spin's 6 (two steps each), then the
                                   ;  sparkle's 3
        .assert STARCLK = 2*SPR_STAR_N && SPARKLE_END-SPARKLE0 = 2*SPR_SPARKLE_N && SPR_SPARKLE0 = SPR_STAR0+SPR_STAR_N, error, "a star's count halved is its frame, the sparkle's following the spin's"
        ldx O_EL,y                 ; the star's first box id (0: none -- its masked frames):
        beq @regc                  ;  the sky's, black's, or its own baked six (assets.py)
        cmp #SPR_STAR_N            ; (carry unknown on the beq's path: forced there)
        bcs @reg                   ; C = 1 here, so @reg can assume it
        adc O_EL,y                 ; (C = 0: the bcs was not taken) the box id of the frame
        ldx #RQ_GUARD_STAR         ; box_safe: Cleo's RNGTAB quad (the boomerang's is +RQ_BOOMOFF)
        bne box_safe               ; always: Z = 0 from the ldx
@regc:  sec
@reg:   adc #SPR_STAR0-1           ; C = 1: + SPR_STAR0
        jmp add_sprite
@done:  rts

; A box star is an opaque rectangle (the star baked over its backdrop), so if the
; same frame is already on screen in the same place its pixels are still right --
; unless something has been drawn through them.  The converter marks the stars an
; enemy's range covers (O_EH); the rest can still be walked through by Cleo or the
; boomerang, which box_safe tests with a band widened from "close enough to pick
; up" to "the rectangles touch" (RQ_GUARD_*).  Safe ones are drawn under an alias
; id BOXN above the real one (the engine keeps them).  The trampoline's rest box
; and the powerup's are opaque the same way; all go through box_safe.

; ---------------------------------------------------------------- the trampoline (1)
; ----------------------------------------------------------------------------
; ob_tramp: the trampoline's step
;   In:    Y = obj; A (O_AL) its spring's count: 0 at rest, 2, 4 .. TRAMP_TOP-2
;          bouncing, two steps a frame; E (O_EL) its rest state's baked box id (0:
;          none); rx, ry, spx, spy, health, vy
;   Out:   O_AL; Cleo bounced (vy = TRAMP_VY, py set TRAMP_SINK into its band,
;          sfx_req) when she lands on it; its sprite added (box_safe's for the rest
;          box)
;   Uses:  A X Y, q2, box_safe's
; Falls into box_safe for the rest box.
; ----------------------------------------------------------------------------
ob_tramp:
        lda O_AL,y
        beq @test
        cmp #TRAMP_TOP-2           ; 2, 4, 6: + 2; 8: on to TRAMP_TOP, which is 0
        bcc @up
        lda #<(-3)                 ; C = 1: -3 + 2 + 1 wraps to 0
@up:    adc #2                     ; (C = 0 on the bcc's way: + 2)
        sta O_AL,y
@test:  lda health
        beq @draw
        ldx #RQ_TRAMP
        jsr csweep
        bcc @draw
        lda vy+1                   ; falling (vy > 0): bmi16 vy and beq16 vy from one load
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
        bne @bounce                ;  one (assets.py: an id a trampoline; 0 for none)
        lda O_EL,y
        bne @rest
@bounce:                           ; (A = O_AL, or 0: frame 0; A even, so the carry in
                                   ;  cannot change A/4 -- no clc)
        adc #2+4*SPR_TRAMP0        ; (A + 2)/4 + SPR_TRAMP0 as one add: A <= 8, no carry out
        lsr
        lsr                        ; bounce frame 0..2: the masked frames, SPR_TRAMP0 on
        jmp add_sprite
@rest:  stzx q2                    ; (box_safe's Cleo test: rx, ry are hers; A live)
        ldx #RQ_GUARD_TRAMP        ; box_safe: Cleo's RNGTAB quad (the boomerang's is +RQ_BOOMOFF)
                                   ; (no clc: q2 = 0, so box_safe's in_range sets C first)
; ----------------------------------------------------------------------------
; box_safe: add a baked box sprite, as the alias (+BOXN, kept still) if nothing can
; draw through it this frame
;   In:    A = the frame's id; X = Cleo's guard quad (RQ_GUARD_STAR, RQ_GUARD_TRAMP,
;          RQ_GUARD_PW: the boomerang's is X + RQ_BOOMOFF); C = 0; q2: 0 test Cleo
;          (rx, ry are hers), 1 she is clear, $80 she is not (a star's prologue,
;          or its boomerang test, which takes rx, ry); O_EH,y = an enemy's range
;          covers it; spx, spy
;   Out:   the sprite added (add_sprite: its tail call)
;   Uses:  A X Y, q1, rx, ry, in_range's; bx, by set at a launch
;   Cost:  measured 145-165 cycles a frame, 4-5 calls (as po_star's)
; A throw that launches this frame (Cleo's step runs after the objects, anim 2 ->
; 4) starts from her place: the boomerang is tested there, so bx, by are set from
; px, py now (they are dead until the launch writes them).
; ----------------------------------------------------------------------------
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
        lda firing                 ; a throw that launches this frame starts from her
        beq @yes                   ;  place: test it there (eor keeps C clear)
        lda anim
        eor #2
        bne @yes
        mov16 bx, px
        mov16 by, py
@bt:    jsr boom_rel
        txa
        ora #RQ_BOOMOFF            ; (the quads are 4-aligned: ora is the add)
        .assert RQ_BOOMOFF = 4 && (RQ_GUARD_STAR & 4) = 0 && (RQ_GUARD_TRAMP & 4) = 0 && (RQ_GUARD_PW & 4) = 0, error, "box_safe: the boomerang's quad is Cleo's | RQ_BOOMOFF"
        tax
        jsr in_range               ; the boomerang overlaps it
        bcs @no
@yes:   lda q1                     ; both ways in fall through a 'bcs @no' that was not
        adc #BOXN                  ;  taken, so C is already clear here
        bcc @add                   ; always: id + BOXN < 256 (ids < BOXID0+BOXN)
@no:    lda q1
@add:   jmp add_sprite

; ---------------------------------------------------------------- the green snake (2)
; ----------------------------------------------------------------------------
; ob_snake: the green snake's step -- back and forth along its path, two state
; steps a frame; stomped or hit by the boomerang it dies, flying off
;   In:    Y = obj; its fields in place: A (O_AL/AH) the path's far end, B
;          (O_BL/BH) its offset along it, C (O_CL) the state (0 right, 1 left, 2-3
;          still at an end, 4-5 dying: 4 flying right, 5 left), E (O_EL) the
;          counter; rx, ry, spx, spy, health, hurt, vy
;   Out:   its fields; rx, spx += B; Cleo hit (player_hit) or bounced (bounce); the
;          boomerang stopped (bcnt = BCNT_HIT), the score, sfx_req; its sprite
;   Uses:  A X Y (Y = obj again after add_score, player_hit)
;   Cost:  measured 180 cycles a frame, 1.3 snakes (as po_star's)
; ----------------------------------------------------------------------------
ob_snake:
        jsr @adv                   ; the frame's two steps of its state machine (the
        jsr @adv                   ;  turn is an exact B = A)
@coll:  addb_rxspx
        lda health
        beq @boom
        ldx #RQ_SNAKE
        jsr csweep
        bcc @boom
        lda O_CL,y
        cmp #SNK_DEAD
        bcs @boom
        cmp #2                     ; C = C >= 2 for both arms: no op below touches C
        lda ry+1                   ; a stomp: the snake below her (ry > 0) and she falling
        bmi @nostomp
        ora ry
        beq @nostomp
        lda vy+1
        bmi @nostomp
        ora vy
        beq @nostomp
        ldx O_CL,y                 ; stomped: C += 2 through X (C is 0..3 here; inx leaves
        inx                        ;  the carry, still C >= 2)
        inx
        txa
        sta O_CL,y
        lda #1
        sta bounce
        bcs @ks                    ; 2 and 3 (now 4 and 5): the points
        bcc @kz                    ; always: 0 and 1 (now 2 and 3, still): no points
@nostomp:
        bcs @boom                  ; C = C >= 2 still: a still snake does not bite
        hit_cleo @boom
@boom:  boom_test RQ_BOOM_SNAKE, @draw
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
        bne @boom                  ; always: SFX_KILL <> 0
@draw:  snake_bge 1-SNAKE_FLYMAX   ; B <= -SNAKE_FLYMAX (flown off left): not drawn
        bcc @done
        txa                        ; B - A >= SNAKE_FLYMAX (off right): not drawn (C = 1:
        snake_bage SNAKE_FLYMAX    ;  the bcc fell through)
        bcs @done
        lda O_CL,y
        cmp #2
        and #1                     ; and leaves C from the cmp: both arms want C & 1
        bcs @f6
        ldx O_EL,y                 ; E is 0..11 whenever C < 2; the 0..63 ladder @s23
        ora @ftab,x                ;  runs only while C >= 2, and that takes @f6.  A is
        jmp add_sprite             ;  C & 1: cmp/and/bcs/ldx leave it
@f6:    ora #SPR_SNAKE0+6          ; still or dying: the base is even, so ora is the add
        jmp add_sprite
@ftab:  .byte SPR_SNAKE0+0,SPR_SNAKE0+0,SPR_SNAKE0+0,SPR_SNAKE0+2,SPR_SNAKE0+2,SPR_SNAKE0+2
        .byte SPR_SNAKE0+4,SPR_SNAKE0+4,SPR_SNAKE0+4,SPR_SNAKE0+2,SPR_SNAKE0+2,SPR_SNAKE0+2
        .assert (SPR_SNAKE0 & 1) = 0, error, "ob_snake: the frame is added by ora: SPR_SNAKE0 must be even"
        .assert SNAKE_E_WRAP = 12, error, "ob_snake: @ftab has an entry for each count 0..11"
@done:  rts
; ---- @adv: one step of the state machine (two a frame)
@adv:   lda O_EL,y                 ; both arms step the counter
        clc
        adc #1
        sta O_EL,y
        ldx O_CL,y                 ; (X is free here: the handler never reads it before a
        cpx #2                     ;  load)
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
@c0:    lda O_BL,y                 ; walking right: B + 1
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
@c1:    lda O_BL,y                 ; walking left: B - 1 (C = 0): a borrow leaves C = 0
        sbc #0                     ;  and the low byte $FF, so B is not 0
        sta O_BL,y
        bcc @dech                  ; the borrow: @c5's tail takes it from the high byte
        bne @ar                    ; Z from the sbc
        lda O_BH,y                 ; B = 0: back to state 0
        bne @ar
@cset:  sta O_CL,y                 ; A = 0 (the bne above was not taken), or 1 from @c0
@ar:    rts
@s23:   cmp #SNAKE_DEAD_E          ; still (2, 3) or dying (4, 5): at E = 64 back to
        bne @s45                   ;  walking (C & 1: the way it faced)
        txa
        and #1
        sta O_CL,y
@z:     lda #0                     ; E = 0 is a pause frame: neither state steps on it
        sta O_EL,y
@rt:    rts
@s45:   cpx #SNK_DEAD              ; 2 and 3 do nothing more; 4 and 5 fly (X = O_CL)
        bcc @rt
        bne @c5                    ; carry set; Z: the state is 4
@c4:    lda O_BL,y                 ; flying right: if B - A < SNAKE_FLYMAX, B += SNAKE_FLY
        snake_bage SNAKE_FLYMAX    ;  (C = 1 here: cpx / bne @c5)
        bcs @cj
        lda O_BL,y                 ; C = 0: the bcs @cj above was not taken
        adc #SNAKE_FLY
        sta O_BL,y
        bcc @cj
        lda O_BH,y
        adc #0                     ; C = 1: + 1
        sta O_BH,y
        rts
@c5:    snake_bge 1-SNAKE_FLYMAX   ; flying left: if B > -SNAKE_FLYMAX, B -= SNAKE_FLY (X
        bcc @cj                    ;  is dead after @adv, as @c4's tax assumes)
        txa                        ; C = 1: the bcc was not taken
        sbc #SNAKE_FLY
        sta O_BL,y
        bcs @cj
@dech:  lda O_BH,y                 ; (and @c1's borrow, C = 0 there too)
        sbc #0                     ; C = 0: - 1
        sta O_BH,y
@cj:    rts

; ---------------------------------------------------------------- the red snake (3)
; ----------------------------------------------------------------------------
; ob_rsnake: the red snake in its basket -- it rises and sinks on a timer; hit by
; the boomerang the snake and the pot are knocked flying
;   In:    Y = obj; its fields in place: A (O_AL) the dormancy counter, a signed
;          byte -127..RSNAKE_UP; B (O_BL) 0, or knocked: 1 flying right, 2 left; C
;          and D (O_CL/CH, O_DL/DH) the knock's flight (its y and x offsets); rx,
;          spx, spy, health, hurt, px
;   Out:   its fields; Cleo hit while the snake is up (body_draw: the frames
;          drawn); the boomerang stopped (bcnt), the score, sfx_req; its sprites
;          (the snake while up, and the basket)
;   Uses:  A X Y, ox, oy, q1, q6, rise, rx, ry, spx, spy (Y = obj again after the
;          calls that change it)
; A is the original's (CleoApp.run case 3: A++, and at 17 A = -(rnd&63)-64): the
; same idiom as the spike, and a signed byte holds it.  While up the snake's rise
; over the basket is rise_tab[A & 31], the original's parabola; the reference skips
; it when A <= -16 (bipush -16, if_icmple), so it is up for A >= RSNAKE_SHOW.  The
; position is kept in ox/oy: the snake draws at it + the rise, the basket at it.
; ----------------------------------------------------------------------------
ob_rsnake:
        oxy_set
        lda O_BL,y                 ; B: 0, or 1 or 2 knocked (its high byte stays 0)
        beq @up
        jmp @knocked
@up:    lda O_AL,y                 ; two steps a frame: past RSNAKE_UP as well as at it
        clc
        adc #2
        sta O_AL,y
        bmi @norst
        cmp #RSNAKE_UP
        bcc @norst
        dormant_reset
@norst:                            ; A = the counter on both ways in
        eor #$80                   ; biased, so the compare can be unsigned: up from
        cmp #<(RSNAKE_SHOW+$80)    ;  RSNAKE_SHOW (-15 -> 113; at -16 the rise is +4 and
        bcc @nowarm                ;  the tall frame's tail would show 4 px under the
                                   ;  basket; at -15 it is 0, flush with its bottom)
        and #RISE_N-1              ; (the bias is bit 7's: A & 31 is the counter's,
        tax                        ;  -15..16 -> 17..31, 0..16)
        lda rise_tab,x
        sta rise
        ldx #0                     ; its high byte: the sign
        ora #0
        bpl :+
        dex
:       stx rise+1
        lda #1                     ; q6 = 1: the snake is out
        bne @vis                   ; always: A = 1
@nowarm:
        lda #0
@vis:   sta q6
        boom_test RQ_BOOM_RSNAKE, @hitp
        lda #SCORE_RSNAKE
        jsr add_score
        ldy obj
        ldx #1                     ; knocked: B = 1 flying right (the boomerang came from
        bgt16 ox, px, @kx          ;  her left), 2 left
        ldx #2
@kx:    txa                        ; B's high byte is already 0: @up runs only when B =
        sta O_BL,y                 ;  0, and nothing since has written it
        lda q6
        beq @kr
        lda rise                   ; C = the rise: the snake flies from where it was
        sta O_CL,y
        lda rise+1
        sta O_CH,y
@kr:    lda #BCNT_HIT
        sta bcnt
        lda #SFX_KILL
        sta sfx_req
@hitp:
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
        add16 spy, rise            ; the snake at oy + the parabola
        lda q1
        jsr body_draw              ; her body against this frame's, then drawn
@basket:                           ; spx = ox still: ox was copied from it on entry and
        mov16 spy, oy              ;  nothing since writes spx
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
@k1:    lda O_CL,y                 ; C -= RSNAKE_KNOCK: two steps' 16, up
        sec
        sbc #RSNAKE_KNOCK
        sta O_CL,y
        lda O_CH,y
        sbc #0
        sta O_CH,y
        lda O_BL,y
        cmp #1
        bne @kl
        lda O_DL,y                 ; D += RSNAKE_KNOCK: right
        clc
        adc #RSNAKE_KNOCK
        sta O_DL,y
        lda O_DH,y
        adc #0
        sta O_DH,y
        jmp @kf
@kl:    lda O_DL,y                 ; D -= RSNAKE_KNOCK: left
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
        lda ox                     ; spx = ox + D: the pot flies too (@basket draws it at
        adc O_DL,y                 ;  spx, which it otherwise takes to be ox)
        sta spx
        lda ox+1
        adc O_DH,y
        sta spx+1
        jmp @basket

; ---------------------------------------------------------------- the bat (4)
; ----------------------------------------------------------------------------
; ob_bat: the bat -- it chases Cleo, its speed capped; stomped or hit by the
; boomerang it falls
;   In:    Y = obj; its fields: A and B (O_AL/AH, O_BL/BH) the chase's speed limits
;          (x, y; then the fall's vy in A), C and D (O_CL/CH, O_DL/DH) its velocity
;          (staged into fc, fd for the move and the chase, put back after), E
;          (O_EL) the counter: flapping 0..7, BAT_DEAD_E dead; rx, ry, spx, spy,
;          health, hurt, vy, dyl, frame
;   Out:   its fields; rx, ry, spx, spy moved by half the velocity; Cleo hit or
;          bounced; the boomerang stopped, the score, sfx_req; its sprite (wobbled
;          by bat_off while alive)
;   Uses:  A X Y, fc, fd, q1, t16, t16b, the stack (4 bytes); Y = obj again after
;          add_score, player_hit
;   Cost:  measured 170 cycles a frame, 1.7 bats (as po_star's)
; ----------------------------------------------------------------------------
ob_bat:
        lda O_EL,y
        cmp #BAT_DEAD_E
        bcc @alive
        jmp @dead
@alive: adc #2                     ; A = E < 8 and C = 0 from the bcc:
        and #BAT_FLAP_N-1          ;  E = (E + 2) & 7: two steps
        sta O_EL,y
        lda O_DL,y
        sta fd
        lda O_DH,y
        sta fd+1
        lda O_CL,y
        sta fc
        lda O_CH,y
        sta fc+1
        ; the move: rx and spx += C >> 1, ry and spy += D >> 1 (arithmetic; the
        ; halves wait in X:Y)
        cmp #$80                   ; A = fc+1
        ror
        tax
        lda fc
        ror
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
        lda fd+1
        cmp #$80
        ror
        tax
        lda fd
        ror
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
        ; the chase: the frame's two steps of it, each axis a unit toward Cleo (rx,
        ; ry: her side), the speed held within 0..A and 0..B
        ldx #2                     ; the step count in X (the loop leaves X alone)
        ldy obj
@chase: bpl16 rx, @rxpos
        lda fc                     ; she is left (rx < 0): C < A (a signed compare, V
        cmp O_AL,y                 ;  fixed up), no faster
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
        beq16 fc, @ydir            ; (C >= 0 always: it stays in 0..A, so no sign test)
        lda fc
        bne :+
        dec fc+1
:       dec fc
@ydir:  bpl16 ry, @rypos
        lda fd                     ; she is above: D < B, no faster
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
        jsr boom_ready
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
        bne @fall
        cpx #BAT_STOMP_Y+1
        bcc @nostomp
@fall:  lda vy+1                   ; and falling: bmi16 vy, then beq16 vy, from one load
        bmi @nostomp
        ora vy
        beq @nostomp
        lda #1                     ; bounce first: the kill does not read it
        sta bounce
        bne @kill                  ; A = 1
@nostomp:
        lda hurt                   ; invulnerable: no sweep (the other enemies sweep
        bne @draw                  ;  first, then test hurt: hit_cleo)
        ldx #RQ_BAT
        jsr csweep
        bcc @draw
        lda rx+1                   ; knocked back from the bat: player_hit reads
        sta hx+1                   ;  only hx+1's sign
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
        bge16 px, spx, @wob        ; spx > px: one frame on (facing left)
        inc q1
        ; ---- the wobble: x += bat_off[(s + obj*5) & 15],
        ; y += bat_off[((5*s >> 2) + obj*7) & 15], s = 2*frame (the original's step count)
@wob:   lda frame
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
        adds8 spx
        lda t16b
        asl
        asl                        ; A = 5*s, low byte only: the high byte of 5*s is dead
        adc t16b                   ;  (the >> 2 below shifts the low byte alone; no clc:
        lsr                        ;  s and 4s are even, so a carry in only sets bit 0,
        lsr                        ;  which the >> 2 drops)
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
        adds8 spy
        lda q1
        jmp add_sprite
@dead:  lda O_DL,y                 ; falling (in place), until D >= B + 256: D - B's high
        cmp O_BL,y                 ;  byte >= 1, signed (B = 16*q4 <= 4080 and D -6..~4600
        lda O_DH,y                 ;  while falling: no overflow, and the high byte stays
        sbc O_BH,y                 ;  -36..18)
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
        sta O_DH,y                 ; A = O_DH,y
        cmp #$80                   ; spy += D >> 1 (arithmetic)
        ror
        tax                        ; the high half waits in X (dead: add_sprite loads it)
        lda O_DL,y
        ror
        clc
        adc spy
        sta spy
        txa
        adc spy+1
        sta spy+1
        lda O_CH,y                 ; same again for C into spx
        cmp #$80
        ror
        tax
        lda O_CL,y
        ror
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
; the wobble's offsets (ob_bat @wob), a sine of sorts over BATOFF_N steps
bat_off:
        .byte 0,1,1,2,2,2,1,1,0,<-1,<-1,<-2,<-2,<-2,<-1,<-1
        .assert * - bat_off = BATOFF_N, error, "bat_off: BATOFF_N entries"

; ---------------------------------------------------------------- the mask (5) and mummy (6)
; ----------------------------------------------------------------------------
; ob_walker: the mask and the mummy -- a walk back and forth along a path, a stand
; at each end; the boomerang turns them back
;   In:    Y = obj, otype (OT_MASK or OT_MUMMY: the frame set); its fields in
;          place: A (O_AL/AH) the path's far end (48..192), B (O_BL/BH) the offset
;          along it (-2..194), C (O_CL) the direction (0 right, 1 left), E (O_EL)
;          the counter (even, 0..10); spx, health, hurt, bvx
;   Out:   its fields; spx += B; Cleo hit (body_draw: the frames drawn); the
;          boomerang stopped (bcnt); its sprite
;   Uses:  A X Y, rx, ry (Y = obj again after player_hit)
; The step is WALK_STEP a frame (the original's 1 and 2).  B's high byte is only
; ever 0 or $FF (B is -2..194), so most of the compares are on its low byte with
; the sign byte tested first.
; ----------------------------------------------------------------------------
ob_walker:
        lda O_EL,y                 ; E + 2 (two steps), WALK_E_WRAP back to 0
        cmp #WALK_E_WRAP-2
        bcc @e                     ; C = 0: E + 2
        lda #<(-3)                 ; C = 1 (E = 10): -3 + 2 + 1 = 0
@e:     adc #2
        sta O_EL,y
        lda O_CL,y
        bne @left
        lda O_BL,y                 ; walking right: B += WALK_STEP.  B can be -1 coming
        sec                        ;  in (the left path rests one past the near end),
        adc #WALK_STEP-1           ;  and the carry out of the add is what clears its
        sta O_BL,y                 ;  sign byte -- drop that and -1 + 3 becomes -254, not
        bcc @r1                    ;  2.  (sec: the + 1)
        lda #0                     ; the carry: B was -2 or -1 (high byte $FF), now 1 or
        sta O_BH,y                 ;  2.  A = 0 is below A (48..192) as 1 or 2 is
@r1:    cmp O_AL,y                 ; past here B's high byte is 0 and B is 0..194, so the
        bcc @coll                  ;  unsigned compare says what the signed 16-bit did
        lda #1                     ; B >= A: turn (C = 0 here: bne @left fell through;
        bne @cset                  ;  always: the store is @stop's)
@left:  lda O_BL,y
        clc                        ; B -= WALK_STEP (C = 0 is the - 1)
        sbc #WALK_STEP-1
        sta O_BL,y
        beq @stop                  ; B reached 0 (a borrow never leaves zero: >= 254)
        bcs @coll                  ; no borrow, not zero: still walking
        lda #$FF                   ; a borrow: B went negative, the bmi16 test.  B was 1 or
        sta O_BH,y                 ;  2 (high byte 0), so the high byte is $FF
@stop:  lda #0
@cset:  sta O_CL,y
@coll:  clc                        ; spx += B: where it draws (its rx is body_hit's
        lda spx                    ;  and boom_rel's own)
        adc O_BL,y
        sta spx
        lda spx+1
        adc O_BH,y
        sta spx+1
@boom:  boom_test RQ_BOOM_WALKER, @draw
        bit bvx+1                  ; hit: it walks the boomerang's way (C = 0 right if B <
        bmi @bleft                 ;  A, 1 left if B > 0), and the boomerang stops
        lda O_BH,y                 ; bvx > 0: B < A is B negative, or its low byte below
        bmi @bc0                   ;  A's (A is 48..192, high byte 0; B -2..194)
        lda O_BL,y
        cmp O_AL,y
        bcs @bset
@bc0:   lda #0
        beq @bsc                   ; always
@bleft: lda O_BH,y                 ; bvx < 0: B > 0
        bmi @bset
        lda O_BL,y
        beq @bset
        lda #1
@bsc:   sta O_CL,y
@bset:  lda #BCNT_HIT
        sta bcnt
@draw:  lda O_BH,y                 ; the standing frame at either end.  Past the sign test
        bmi @f8                    ;  B's high byte is 0, so the rest is an 8-bit compare
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
        cpx #OT_MUMMY              ; otype is OT_MASK or OT_MUMMY (the two table entries)
        bne @s5                    ; the mask: C = 0 from the cpx
        adc #SPR_MUMMY0-SPR_MASK0-1 ; the mummy: C = 1, so A + 9, and C = 0 again
@s5:    adc #SPR_MASK0
        jmp body_draw              ; her body against this frame's, then drawn
@f0:    lda O_CL,y                 ; C = 0: the bcc
        bcc @sp
@f2:    lda #2                     ; C = 0: the bcc
        bcc @fr
@f8:    lda #WALK_STAND_F
        bne @sp

; ---------------------------------------------------------------- the spike (7)
; ----------------------------------------------------------------------------
; ob_spike: the spike -- out of the ground on a timer, then dormant
;   In:    Y = obj; A (O_AL) the dormancy counter, a signed byte -127..SPIKE_UP, in
;          place; rx, ry, health, hurt
;   Out:   O_AL; RNGTAB's RQ_SPIKE x limit; Cleo hit; its sprite while out
;   Uses:  A X Y (Y = obj again after player_hit)
; The original's (CleoApp.run case 7: A++, and at 24 A = -(rnd&63)-64) fits a
; signed byte exactly, so the byte IS the value and the high half was only ever its
; sign extension.  Its hit box is rx > -8 && rx < (A+1)*2 && ry > -24 && ry < 8: the
; x limit grows with its height, so the quad's hi is written here each time (the
; one quad the game writes).
; ----------------------------------------------------------------------------
ob_spike:
        lda O_AL,y                 ; (two steps a frame: past SPIKE_UP as well as at it)
        clc
        adc #2
        sta O_AL,y
        bmi @nowrap
        cmp #SPIKE_UP
        bcc @nowrap
        dormant_reset
@nowrap:
        ldx health                 ; A = the counter on both ways in, and ldx keeps it
        beq @draw
        cmp #SPIKE_OUT             ; unsigned: a dormant (negative) A is >= 8 too
        bcs @draw
        asl                        ; A < 8 and C = 0 (bcs fell through): 2A, C = 0
        adc #2+RQ_BIAS             ; (A+1)*2 biased: the quad's hi
        sta RNGTAB+RQ_SPIKE+1
        ldx #RQ_SPIKE
        jsr csweep
        bcc @draw
        lda hurt
        bne @draw
        lda rx+1                   ; only hx+1 goes over: player_hit reads just its sign
        sta hx+1                   ;  and hx's low byte is read nowhere.  The original knocks
        ora rx                     ;  Cleo right when rx <= 0 (CleoApp.run case 7: rx > 0 is
        bne @ph                    ;  -768, else +768), player_hit only when hx < 0: level
        dec hx+1                   ;  with the spike (rx = 0), hx = -256 says so
@ph:    jsr player_hit
        ldy obj
@draw:  lda O_AL,y                 ; out: frames 0..7 up, then (23 - A)/2 down
        bmi @done
        cmp #SPIKE_OUT
        bcc @fu
        eor #$FF                   ; A (8..23), C = 1: 255-A+23+1 = 23-A, C = 1
        adc #SPIKE_UP-1
        lsr
        clc                        ; only the lsr can leave C set; bcc arrives with C = 0
@fu:    adc #SPR_SPIKE0
        jmp add_sprite
@done:  rts

; ---------------------------------------------------------------- the flame (9)
; ----------------------------------------------------------------------------
; ob_flame: the flame -- an animation alone, a frame every other game frame (the
; original's every fourth step)
;   In:    Y = obj; E (O_EL) the frame, in place; frame
;   Out:   O_EL; its sprite
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
ob_flame:
        lda frame
        lsr                        ; C = the frame's low bit; the lda keeps it
        lda O_EL,y
        bcs @f                     ; odd frame: C = 1, so the adc is E + SPR_FLAME0
        adc #1                     ; C = 0: the bcs fell through
        and #SPR_FLAME_N-1
        sta O_EL,y
        sec                        ; C = 1 for the shared adc, whatever the step left
@f:     adc #SPR_FLAME0-1
        jmp add_sprite

; ---------------------------------------------------------------- the powerup (10)
; ----------------------------------------------------------------------------
; ob_powerup: the health powerup -- picked up when her health is short, then its
; pickup animation
;   In:    Y = obj; A (O_AL) the pickup's progress (0 at rest, 1..PICKUP_END), E
;          (O_EL) its baked box id, in place; rx, ry, health
;   Out:   O_AL; health = HEALTH_MAX, bar_dirty, sfx_req on a pickup; its sprite
;          (box_safe's at rest)
;   Uses:  A X Y, q2, box_safe's (Y = obj again after bar_touch)
; ----------------------------------------------------------------------------
ob_powerup:
        lda O_AL,y
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
        bne @draw                  ; Z = 0: SFX_POWER <> 0
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

; ---------------------------------------------------------------- the vanishing block (11)
; ----------------------------------------------------------------------------
; ob_vanish: the vanishing block -- one step: standing on it starts its count, and
; every fourth count rewrites its two map tiles with the frame's ids
;   In:    fe = its count (0 at rest), ox, oy = its position (os_vanish's); rx,
;          ry, vy; LV_HDR+HDR_SPECIAL = the frames' tile id pairs
;   Out:   fe; the map's two tiles and their dirty marks (mark_pair), the memo
;          cleared
;   Uses:  A X Y, q1, q5, qx, qy, map_ptr, tilexy's; mark_dirty's (tmp, tmp2)
;   Post:  bank 7 paged
; The frame by the count: fe/2 up to VANISH_GONE (gone), VANISH_SOLID_F held to
; VANISH_BACK, then VANISH_END - fe back, wrapping to 0 at VANISH_END.  The grid
; walk's gx/gy are live across the handlers, so the tile row waits in q5.
; ----------------------------------------------------------------------------
ob_vanish:
        lda fe
        bne @count
        ldx #RQ_VANISH             ; at rest: she stands on it (rx > -16 && rx <= 0 && ry
        jsr csweep                 ;  == 16, the quad's) with vy = 0
        bcc @ret
        lda vy
        ora vy+1
        bne @ret
        inc fe                     ; fe was 0: bne @count fell through
@ret:   rts
@count: inc fe
        lda fe
  .if ::BHW                        ; (CPU spelling: bit # is the 65C02's; A is reloaded,
        and #VANISH_EVERY-1        ;  so bitimm's save and restore are not needed)
        bne @ret
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
        mov16 qx, ox               ; the tiles at (ox>>3, oy>>3) and one right: the frame's
        mov16 qy, oy               ;  ids from the header
        jsr tilexy                 ; X = tile x, A = tile y
        sta q5                     ; tile y (q5: gx/gy are the live grid-walk cursor)
        jsr map_tile               ; sets map_ptr, Y = tx; X kept, bank 7 back
        ldx q1
        lda LV_HDR+HDR_SPECIAL,x
        jsr map_put                ; X and Y kept
        iny
        lda LV_HDR+HDR_SPECIAL+1,x
        jsr map_put
        dey
        lda fe                     ; the count's wrap first (mark_dirty leaves fe alone),
        eor #VANISH_END            ;  so the marks can be the tail
        bne @mk                    ; A = 0 when fe = VANISH_END
        sta fe
@mk:    tya                        ; tile x
        ldx q5                     ; (falls into mark_pair; A, X, Y dead on return)
; ----------------------------------------------------------------------------
; mark_pair: tiles (A, X) and (A+1, X) marked dirty, in that order (the vanishing
; block's and the switch's pairs), and the map memo dropped
;   In:    A = the tile column, X = the tile row
;   Out:   mok = 0; both tiles queued (mark_dirty: tmp = A, tmp2 = X kept across it)
;   Uses:  A X Y, mark_dirty's
; ----------------------------------------------------------------------------
mark_pair:
        ldy #0                     ; the map has changed: no map memo (get_altitude)
        sty mok                    ;  (Y is free: mark_dirty takes A and X)
        jsr mark_dirty
        ldx tmp
        inx
        txa
        ldx tmp2
        jmp mark_dirty

; ---------------------------------------------------------------- the switch (12)
; ----------------------------------------------------------------------------
; ob_switch: the switch -- touched once, it copies two map columns over the two to
; their right for a run of rows (opens a way), and scores
;   In:    fa = its column (the copy is (fa-2, fa-1) -> (fa, fa+1)), fb = the first
;          row, fc = the rows (0: none), fd = its state (0 unthrown) -- os_switch's
;          copies of A..D; rx, ry
;   Out:   fd = 1 once thrown; the map rewritten and marked (mark_pair); the score
;          (SCORE_SWITCH), sfx_req; its sprite by fd
;   Uses:  A X Y, q4, q5, map_ptr, mark_pair's
;   Post:  bank 7 paged
; ----------------------------------------------------------------------------
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
        lda fc                     ; the rows: fc of them from fb (q5: the grid-walk cursor
        beq @set                   ;  gx/gy must stay intact)
        sta q4
        lda fb
        sta q5
@rl:    ldx fa
        dex
        dex
        lda q5
        jsr map_tile               ; map_ptr = the row, Y = X = fa-2, A = (row),fa-2
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

; ---------------------------------------------------------------- the status bar
; The bar is single buffered at a fixed home outside the ring (BARADDR), so it stays
; put however the window scrolls and is only written when its contents change.  Its
; template (icons, labels, blank digit slots) is the BAR file, which the loader puts
; in place with the game's image (ldprog.s) and nothing redraws; the game draws the
; digits straight into it, from bank 7's packed digit art (digits_art, gamedata.s).
; The bar remembers the nine values it was last drawn with (BARCACHE), because
; redraw_hud redraws all nine whenever anything changes and a score tick usually
; moves only one of them -- the other eight were copies for no pixels (the old
; measurement: 5.0K cycles a render on an L0 run, 3.2% of the frame).

; ----------------------------------------------------------------------------
; draw_health: the health digit
;   In:    health
;   Out:   bar_digit's
;   Uses:  A X Y, bar_digit's
; Falls into bar_digit.
; ----------------------------------------------------------------------------
draw_health:
        lda health
        ldx #HUD_X_HEALTH
        ldy #HUD_SLOT_HEALTH
; ----------------------------------------------------------------------------
; bar_digit: one digit into the bar, unless it is there already
;   In:    A = the digit (0..9), X = its bar pixel column (even), Y = its slot
;          (0..HUD_NSLOTS-1: BARCACHE's index)
;   Out:   the digit's DIGIT_PACKED packed bytes expanded to its 64 bytes of the
;          bar (two char rows of four chars); BARCACHE,y = A
;   Uses:  A X Y, tmp4, ptr
;   Keeps: q1 (draw_score's slot); the bank (BANK_LVL on entry and exit: the skip
;          path touches nothing)
;   Cost:  measured 152 cycles a frame, 1.6 digits drawn (test/linecyc.mjs,
;          L0/4/8/10, 60 frames, 4 Oct 2026)
; A packed byte holds two nibbles, a byte column each of the two game rows a char
; row shows; a nibble's screen bytes are digtop (its top scanline) and digbot.
; The bar's address is x * 4 (a char is 2 game pixels wide and 8 bytes), from
; BARADDR, whose low byte is 0.
; ----------------------------------------------------------------------------
bar_digit:
        cmp BARCACHE,y             ; one bar, so one cache: no cur_buf in the index
        beq bd_same
        sta BARCACHE,y
        asl                        ; d * DIGIT_PACKED: the digit's packed bytes
        asl
        asl
        asl
        .assert DIGIT_PACKED = 16, error, "bar_digit: four shifts index the digits"
        sta tmp4
        stx ptr                    ; x is even at every call: x * 4 = char * 8
        lda #0                     ; the high byte, built in A
        asl ptr
        rol
        asl ptr
        rol                        ; C = 0: A was 0 or 1, so this rol shifted a 0 out
        .assert <BARADDR = 0, error, "bar_digit: the low-byte add was dropped"
        adc #>BARADDR              ; (<BARADDR = 0: nothing to add to the low byte)
        sta ptr+1
        jsr @row                   ; the top char row, then the one below it
        add16i ptr, ROWBYTES
@row:   ldy #0                     ; 8 packed bytes -> 32: each byte column's four
@b:     ldx tmp4                   ;  line pairs, top line and bottom from digtop/digbot
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
        and #NIBBLE
        tax
        lda digtop,x
        sta (ptr),y
        iny
        lda digbot,x
        sta (ptr),y
        iny
        cpy #DIGIT_ROWBYTES
        bne @b
; ---- bd_same: bar_digit's skip (the digit is there already), and @row's return
bd_same:
        rts

; ----------------------------------------------------------------------------
; bar_touch: the bar's digits to be redrawn (render_frame calls redraw_hud)
;   Out:   bar_dirty = 1; A = 1
;   Keeps: X Y
; ----------------------------------------------------------------------------
bar_touch:
        lda #1
        sta bar_dirty
        rts

; ----------------------------------------------------------------------------
; redraw_hud: the bar's nine digits (hook_hud: render_frame, with bar_dirty set)
;   In:    lives, health, stars, score
;   Out:   the changed digits drawn (bar_digit); BARCACHE
;   Uses:  A X Y, q1, bar_digit's
;   Pre:   bank 7 paged
; Lives and stars drawn in line (redraw_hud was their one caller); the stars'
; two decimal digits by repeated subtraction (A / 10 in X, A mod 10 in q1).  Falls
; into draw_score.
; ----------------------------------------------------------------------------
redraw_hud:
        lda lives                  ; lives: 1 digit at HUD_X_LIVES
        ldx #HUD_X_LIVES
        ldy #HUD_SLOT_LIVES
        jsr bar_digit
        jsr draw_health
        lda stars                  ; stars remaining: 2 digits at HUD_X_STARS and on
        ldx #0
@div:   cmp #DEC_BASE
        bcc @rem
        sbc #DEC_BASE
        inx
        bcs @div                   ; always: A >= 10 went in, so C = 1
@rem:   sta q1
        txa
        ldx #HUD_X_STARS
        ldy #HUD_SLOT_STARS
        jsr bar_digit
        lda q1
        ldx #HUD_X_STARS+DIGIT_W
        ldy #HUD_SLOT_STARS+1
        jsr bar_digit
; ---- draw_score: the score's 5 digits from HUD_X_SCORE (the BCD score's nibbles,
; slots HUD_NSLOTS-1 down to HUD_SLOT_SCORE0, the ones first); redraw_hud's tail
draw_score:
        ldx #HUD_NSLOTS-1
@d:     stx q1                     ; the slot (bar_digit keeps q1)
        lda #HUD_NSLOTS-1
        sec
        sbc q1                     ; the digit's number, 0..4: its byte, and C = the high
        lsr                        ;  nibble's
        tay
        lda score,y
        bcc @lo
        lsr
        lsr
        lsr
        lsr
@lo:    and #NIBBLE
        pha
        lda q1
        tay                        ; Y = the slot (the cache's)
        asl
        asl
        asl                        ; C = 0: slot*8 < 128
        .assert DIGIT_W = 8, error, "draw_score: three shifts space the digits"
        adc #HUD_X_SCORE-HUD_SLOT_SCORE0*DIGIT_W ; slot*8 + 76 = 108..140
        tax
        pla
        jsr bar_digit
        ldx q1
        dex
        cpx #HUD_SLOT_SCORE0
        bcs @d
        rts

; ----------------------------------------------------------------------------
; bar_bg: the game's image has come in with the bar's template (hook_image:
; ldprog.s): the digit cache reset, as the template buries the digits
;   In:    A = never a digit: blank_palette's last palette byte less one step, $F7
;          ((PCOL_BLACK ^ PAL_INV) - (1 << PAL_SHIFT)), carried through go_game,
;          ld_go and ld_image (menu.s new_game: blank_palette, then jmp go_game)
;   Out:   BARCACHE = A in every slot
;   Uses:  X
;   Keeps: A Y
; ----------------------------------------------------------------------------
bar_bg:
        ldx #HUD_NSLOTS-1
@bci:   sta BARCACHE,x
        dex
        bpl @bci
        rts

; ---------------------------------------------------------------- random
; ----------------------------------------------------------------------------
; rnd: a pseudo-random byte
;   In:    seed (16-bit, never 0: the menus set RND_SEED)
;   Out:   A = seed's low byte after a step of the LFSR (shift right, RND_TAPS into
;          the high byte on a carry)
;   Uses:  A
;   Keeps: X Y
; ----------------------------------------------------------------------------
rnd:
        lsr seed+1
        ror seed
        bcc :+
        lda seed+1
        eor #RND_TAPS
        sta seed+1
:       lda seed
        rts

; ---------------------------------------------------------------- tables
; The red snake's rise above its basket by its counter A & 31 (A = -15..16 while it
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

; ---------------------------------------------------------------- layout
        .assert ry = rx+2 && qy = qx+2 && by = bx+2 && bvy = bvx+2, error, "bstep, bmove: an axis by X = 0 or 2, y two bytes after x"
