#!/usr/bin/env python3
"""Render an image 1:1 into the MODE 1 CMYK style with a 2x2 kernel, the game's way: for
each pixel the 4-ink combination (of K/C/M/Y) whose average is nearest its colour, in the
converter's gamma space; the pixel's position in the 2x2 kernel picks which of the four
inks it shows.  A flat area is exactly the game's dot pattern; an edge is per pixel.
   python3 cmyk2x2.py in.png out.png"""
import sys
import numpy as np
from PIL import Image
GAMMA = 1.35
PAL_RGB = np.array([[0, 0, 0], [0, 255, 255], [255, 0, 255], [255, 255, 0]], np.uint8)   # K C M Y
cs = [(k, c, m, 4 - k - c - m) for k in range(5) for c in range(5 - k) for m in range(5 - k - c)]
crgb = np.array([(m + y, c + y, c + m) for k, c, m, y in cs], np.float32) / 4
seq = np.array([[1] * c + [2] * m + [3] * y + [0] * k for k, c, m, y in cs], np.uint8)
SLOT = np.array([[0, 2], [3, 1]])          # kernel position (y&1, x&1) -> ink index in seq:
                                            # two inks of two make a checker, as in the game
src, out = sys.argv[1], sys.argv[2]
rgb = np.array(Image.open(src).convert('RGB'))
h, w, _ = rgb.shape
v = (rgb.astype(np.float32) / 255.0) ** GAMMA
d = ((v[:, :, None, :] - crgb[None, None, :, :]) ** 2).sum(axis=3)
inks = seq[d.argmin(axis=2)]                                    # (h, w, 4)
slot = SLOT[np.arange(h)[:, None] & 1, np.arange(w)[None, :] & 1]
dots = np.take_along_axis(inks, slot[:, :, None], axis=2)[:, :, 0]
im = Image.fromarray(PAL_RGB[dots])
im.save(out)
print(out, im.size, 'ink counts K/C/M/Y:', [int((dots == k).sum()) for k in range(4)])
