#!/usr/bin/env python3
"""Hide the music sequence in the top two bits of the bank-5 tile data.

MODE 2 stores each pixel's logical-colour bit 3 in byte bits 7 (left) / 6 (right); the
palette maps logical 8..15 onto the same colours as 0..7 and the tiles never use colour 8,
so those bits are invisible and free.  build/MUSIC (from midi2snd.py) = 144-byte period
table + 4-byte event records; the table is decoded into RAM at start-up (music_init) and
every byte is spread over four consecutive tile bytes, 2 bits each, MSB first.
Run from beeb/ after convert.py and midi2snd.py:  python3 tools/embed_music.py
"""
import os
B = os.path.join(os.path.dirname(__file__), '..', 'build')
mus = open(os.path.join(B, 'MUSIC'), 'rb').read()       # 144-byte period table + sequence
til = bytearray(open(os.path.join(B, 'TIL0'), 'rb').read())
assert len(mus) * 4 <= len(til), 'music does not fit in TIL0'
for i, b in enumerate(mus):
    for k in range(4):
        til[4 * i + k] = (til[4 * i + k] & 0x3F) | (((b >> (6 - 2 * k)) & 3) << 6)
open(os.path.join(B, 'TIL0'), 'wb').write(til)
print('music: %d bytes (table + sequence) hidden in TIL0 (%d of %d tile bytes)' % (len(mus), 4 * len(mus), len(til)))
