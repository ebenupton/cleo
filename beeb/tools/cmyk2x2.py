#!/usr/bin/env python3
"""Render an image into the MODE 1 CMYK style the Cleo converter's way: for each pixel the
4-ink combination (of K/C/M/Y) whose average is nearest its colour, in the converter's
gamma space, laid as a 2x2 block of dots in the converter's kernel order.
   python3 cmyk2x2.py in.png out.png [--1to1]
--1to1: one dot per source pixel instead, the pixel's kernel position choosing which of its
four inks it shows (a flat area is still the game's pattern; edges are per pixel)."""
import sys
import numpy as np
from PIL import Image
GAMMA = 1.35
PAL_RGB = np.array([[0, 0, 0], [0, 255, 255], [255, 0, 255], [255, 255, 0]], np.uint8)   # K C M Y
cs = [(k, c, m, 4 - k - c - m) for k in range(5) for c in range(5 - k) for m in range(5 - k - c)]
crgb = np.array([(m + y, c + y, c + m) for k, c, m, y in cs], np.float32) / 4
seq = np.array([[1] * c + [2] * m + [3] * y + [0] * k for k, c, m, y in cs], np.uint8)
SLOT = np.array([[0, 2], [3, 1]])          # kernel position (y&1, x&1) -> ink index in seq
args = [a for a in sys.argv[1:] if not a.startswith('--')]
src, out = args[0], args[1]
one = '--1to1' in sys.argv
rgb = np.array(Image.open(src).convert('RGB'))
h, w, _ = rgb.shape
v = (rgb.astype(np.float32) / 255.0) ** GAMMA
d = ((v[:, :, None, :] - crgb[None, None, :, :]) ** 2).sum(axis=3)
inks = seq[d.argmin(axis=2)]                                    # (h, w, 4)
if one:
    slot = SLOT[np.arange(h)[:, None] & 1, np.arange(w)[None, :] & 1]
    dots = np.take_along_axis(inks, slot[:, :, None], axis=2)[:, :, 0]
else:
    dots = np.zeros((2 * h, 2 * w), np.uint8)
    for (dy, dx), k in np.ndenumerate(SLOT):
        dots[dy::2, dx::2] = inks[:, :, k]
im = Image.fromarray(PAL_RGB[dots])
im.save(out)
print(out, im.size, 'ink counts K/C/M/Y:', [int((dots == k).sum()) for k in range(4)])
