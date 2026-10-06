"""Cleo's sound effects, for beebgame's player (SOUND6): beebgame/tools/sfx.py packs them into
sfxdata.inc, whose SFX_<NAME> = id (the place in EFFECTS) the game passes to sfx_request.
The format: beebgame/tools/sfx.py's docstring; S, KEEP and the noise nibbles NW_*/NP_* are
the packer's.  A period is the SN76489's, 125000 / Hz (C4 477, E5 190, G5 159, C6 119, E6 95,
G6 80, B6 63); a level 0..254, 16 a 2 dB step.  Voices 0-2 are the tone channels, 3 the
noise; a noise clocked by tone 2 (NW_T2, NP_T2) takes its pitch from voice 2, kept silent.
The original game had no effects (its `snd` is a ringtone of the title tune): these are the
port's.  The code relies on one id: SFX_CATCH's bit 2 set (logic.s @bgone takes sfx_request's
C = 1 from it, asserted there).
"""
EFFECTS = [
    # her jump: a quick chirp up an octave
    ('jump', 3, [
        (1, [S(8, 300, 230, -18, -20, 0)]),
    ]),
    # a star taken: a bright ding, E6 to B6, over a soft fifth
    ('star', 4, [
        (0, [S(3, 95, 240, -10, 0, 0), S(12, 63, 240, -16, 0, 0)]),
        (1, [S(15, 127, 140, -9, 0, 0)]),
    ]),
    # the boomerang thrown: a soft whoosh -- noise alone, swelling gently and fading, its rate
    # drifting down (clocked by the silent tone 2); never loud
    ('throw', 3, [
        (2, [S(12, 40, 0, 0, 3, 0)]),
        (3, [S(5, NW_T2, 40, 18, 0, 0), S(7, KEEP, KEEP, -16, 0, 0)]),
    ]),
    # she is hurt: the port's original effect, three falling tones
    ('hit', 7, [
        (2, [S(4, 640, 240, 0, 0, 0), S(4, 768, 208, 0, 0, 0), S(5, 960, 160, 0, 0, 0)]),
    ]),
    # the boomerang caught: a light pluck (id 4: bit 2 set, see the docstring)
    ('catch', 2, [
        (0, [S(2, 150, 220, -60, 0, 0), S(4, 100, 200, -48, 0, 0)]),
    ]),
    # an enemy killed: the port's original effect, four tones falling and fading
    ('kill', 6, [
        (2, [S(2, 96, 240, 0, 0, 0), S(2, 144, 224, 0, 0, 0), S(3, 192, 192, 0, 0, 0), S(3, 256, 144, 0, 0, 0)]),
    ]),
    # a powerup or a switch: an arpeggio up, C5 E5 G5 C6 E6
    ('power', 6, [
        (0, [S(3, 239, 240, -6, 0, 0), S(3, 190, KEEP, -6, 0, 0), S(3, 159, KEEP, -6, 0, 0),
             S(3, 119, KEEP, -6, 0, 0), S(12, 95, KEEP, -18, 0, 0)]),
    ]),
    # she dies: two tones falling away under a long hiss
    ('die', 9, [
        (0, [S(30, 200, 254, -4, 10, 0), S(20, KEEP, KEEP, -10, 14, 0)]),
        (1, [S(30, 300, 220, -4, 14, 0), S(20, KEEP, KEEP, -10, 18, 0)]),
        (3, [S(40, NW_LO, 200, -5, 0, 0)]),
    ]),
    # a trampoline: a short, sharp boing -- struck hard, dropping, then a fast wobble
    # (~12 Hz) dying in 0.2 s
    ('bounce', 4, [
        (1, [S(2, 200, 254, -20, 100, 0), S(2, KEEP, KEEP, -36, -60, 0), S(2, KEEP, KEEP, -44, 44, 0),
             S(2, KEEP, KEEP, -52, -30, 0), S(2, KEEP, KEEP, -60, 20, 0)]),
    ]),
    # a switch thrown: a clunk
    ('switch', 5, [
        (3, [S(4, NP_HI, 220, -50, 0, 0)]),
        (1, [S(6, 600, 200, -30, 20, 0)]),
    ]),
    # the exit reached: a fanfare, G5 C6 E6 G6 over a third below and a held C
    ('exit', 10, [
        (0, [S(5, 159, 240, -8, 0, 0), S(5, 119, 240, -8, 0, 0), S(5, 95, 240, -8, 0, 0), S(24, 80, 254, -9, 0, 0)]),
        (1, [S(5, 190, 180, -8, 0, 0), S(5, 159, 180, -8, 0, 0), S(5, 119, 180, -8, 0, 0), S(24, 95, 190, -7, 0, 0)]),
        (2, [S(39, 477, 200, -5, 0, 0)]),
    ]),
    # the menus (on the noise: the title tune has the tone channels): a move, a choice
    ('move', 1, [
        (3, [S(2, NW_HI, 140, -60, 0, 0)]),
    ]),
    ('select', 2, [
        (3, [S(5, NW_MID, 200, -40, 0, 0)]),
    ]),
]
