#!/usr/bin/env python3
"""Hide the music sequence in bit 6 of the bank-5 tile data (bit 7 flags periodic cells).

MODE 2 stores each pixel's logical-colour bit 3 in byte bits 7 (left) / 6 (right); the
palette maps logical 8..15 onto the same colours as 0..7 and the tiles never use colour 8,
so those bits are invisible and free.  build/MUSIC (from midi2snd.py) = 144-byte period
table + 4-byte event records; the table is decoded into RAM at start-up (music_init) and
every byte is spread over eight consecutive tile bytes, one bit each, MSB first.
Run from beeb/ after convert.py and midi2snd.py:  python3 tools/embed_music.py
"""
import os
B = os.path.join(os.path.dirname(__file__), '..', 'build')
mus = open(os.path.join(B, 'MUSIC'), 'rb').read()       # 144-byte period table + sequence
til = bytearray(open(os.path.join(B, 'TIL0'), 'rb').read())
assert len(mus) * 8 <= len(til), 'music does not fit in TIL0'
for i, b in enumerate(mus):
    for k in range(8):
        til[8 * i + k] = (til[8 * i + k] & 0xBF) | (((b >> (7 - k)) & 1) << 6)
open(os.path.join(B, 'TIL0'), 'wb').write(til)
print('music: %d bytes (table + sequence) hidden in bit 6 of TIL0 (%d of %d tile bytes)' % (len(mus), 8 * len(mus), len(til)))
