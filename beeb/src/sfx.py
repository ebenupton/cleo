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
    # the boomerang thrown: a whoosh, noise clocked by a falling (silent) tone 2
    ('throw', 3, [
        (2, [S(10, 24, 0, 0, 5, 0)]),
        (3, [S(10, NW_T2, 210, -20, 0, 0)]),
    ]),
    # she is hurt: a harsh, falling buzz over a thud
    ('hit', 7, [
        (1, [S(10, 500, 254, -22, 8, 31)]),
        (3, [S(6, NP_LO, 200, -30, 0, 0)]),
    ]),
    # the boomerang caught: a light pluck (id 4: bit 2 set, see the docstring)
    ('catch', 2, [
        (0, [S(2, 150, 220, -60, 0, 0), S(4, 100, 200, -48, 0, 0)]),
    ]),
    # an enemy killed: a falling two-step cry with a puff of noise
    ('kill', 6, [
        (0, [S(6, 180, 240, -10, 8, 0), S(10, 260, KEEP, -18, 14, 0)]),
        (3, [S(8, NW_MID, 180, -22, 0, 0)]),
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
    # a trampoline: a boing, a fast rise then a slow sag
    ('bounce', 4, [
        (1, [S(4, 420, 240, -8, -45, 0), S(12, KEEP, KEEP, -18, 6, 0)]),
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
