#!/usr/bin/env python3
"""Convert thm.mid into a 50Hz 3-voice note stream for the SN76489 music player.

Output format (build/MUSIC): records of 4 bytes: frames, note0, note1, note2 (0 = rest,
else MIDI note 24..95 -> index into the period table in the player); terminated by frames=0.
Voice 0 = melody, voices 1/2 = backing (lowest two notes of any chord).
"""
import struct, os

SRC = os.path.join(os.path.dirname(__file__), '..', '..', 'v500', 'thm.mid')
OUT = os.path.join(os.path.dirname(__file__), '..', 'build', 'MUSIC')

d = open(SRC, 'rb').read()

def rd_var(d, p):
    v = 0
    while True:
        b = d[p]; p += 1; v = (v << 7) | (b & 0x7f)
        if not b & 0x80:
            return v, p

hl = struct.unpack('>I', d[4:8])[0]
fmt, ntrk, div = struct.unpack('>HHH', d[8:14])
p = 8 + hl
tempo = 500000
events = []   # (tick, channel, note, on)
for t in range(ntrk):
    ln = struct.unpack('>I', d[p + 4:p + 8])[0]; q = p + 8; end = q + ln
    tm = 0; status = 0
    while q < end:
        dt, q = rd_var(d, q); tm += dt
        b = d[q]
        if b & 0x80:
            status = b; q += 1
        if status == 0xFF:
            typ = d[q]; l, q = rd_var(d, q + 1); data = d[q:q + l]; q += l
            if typ == 0x51:
                tempo = int.from_bytes(data, 'big')
        elif status in (0xF0, 0xF7):
            l, q = rd_var(d, q); q += l
        else:
            hi = status & 0xF0; ch = status & 0xF
            if hi in (0x80, 0x90, 0xA0, 0xB0, 0xE0):
                a, b2 = d[q], d[q + 1]; q += 2
            else:
                a = d[q]; q += 1; b2 = None
            if hi == 0x90 and b2 > 0:
                events.append((tm, ch, a, True))
            elif hi == 0x80 or (hi == 0x90 and b2 == 0):
                events.append((tm, ch, a, False))
    p = end

ticks_per_frame = 1e6 / 50 / (tempo / div)     # ticks per 20ms
events.sort(key=lambda e: (e[0], e[3]))
last_tick = max(e[0] for e in events)
nframes = int(last_tick / ticks_per_frame) + 1
# per frame active notes per channel
active = {0: set(), 1: set()}
frames = []
ei = 0
for f in range(nframes):
    tick_end = (f + 1) * ticks_per_frame
    while ei < len(events) and events[ei][0] < tick_end:
        tm, ch, note, on = events[ei]; ei += 1
        if on:
            active[ch].add(note)
        else:
            active[ch].discard(note)
    mel = max(active[1]) if active[1] else 0
    back = sorted(active[0])[:2]
    v1 = back[0] if len(back) > 0 else 0
    v2 = back[1] if len(back) > 1 else 0
    frames.append((mel, v1, v2))

# run-length encode
records = []
cur = None; run = 0
for fr in frames:
    if fr == cur and run < 255:
        run += 1
    else:
        if cur is not None:
            records.append((run, cur))
        cur = fr; run = 1
records.append((run, cur))
out = bytearray()
# period table for MIDI notes 24..95 (notes below 47 transposed up an octave to fit 10 bits)
for n in range(24, 96):
    nn = n
    while nn < 47:
        nn += 12
    f = 440.0 * 2 ** ((nn - 69) / 12.0)
    per = int(round(125000.0 / f))
    per = min(per, 1023)
    out += bytes([per & 255, per >> 8])
for run, (a, b, c) in records:
    out += bytes([run, a, b, c])
out += bytes([0, 0, 0, 0])
open(OUT, 'wb').write(out)
print('music: %d frames, %d records, %d bytes' % (nframes, len(records), len(out)))
