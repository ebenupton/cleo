#!/usr/bin/env python3
"""Cleo tile dither editor.

Shows a level zoomed 2x, lets you click a tile to select it, view its dithered
MODE 2 state and paint the pixels by hand.  Hand edits are saved to
build/tile_edits.json, which convert.py reads and uses in place of the automatic
dither for those tiles (re-run ./build.sh to bake them into the disc).

Run from the beeb/ directory:   python3 tools/tile_editor.py [level] [main|A]

Level view: left-drag scrolls (or use the scrollbars / trackpad).  Click a tile
to select it.  In the editor on the right, pick a palette colour then click (or
drag) pixels to paint.  "Revert tile" restores the automatic dither for the
selected tile.  "Save" writes build/tile_edits.json.
"""
import os
import sys
import json
import numpy as np
import tkinter as tk
from PIL import Image, ImageTk

sys.path.insert(0, os.path.dirname(__file__))
import convert  # noqa: E402  (runs the converter once; gives us dither + level data)

ZOOM = 2
TILE_W, TILE_H = 16, 16          # a tile shown as 16x16 px (8 MODE2 px * 2 wide, 16 scanlines)
CELL = 22                        # editor pixel size (px), width; height is CELL//2*... kept square-ish
PALETTE_NAMES = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white']

# --- tile colour arrays (16 scanlines x 8), keyed by original tile id ---
compact = convert.compact
tile_cols = {}
for cid, orig in enumerate(compact):
    tile_cols[orig] = np.array(convert.tile_preview[cid], np.uint8).copy()
# the automatic (un-edited) version, for "revert"
auto_cols = {}
_edits = dict(convert.TILE_EDITS)
for cid, orig in enumerate(compact):
    c = np.array(convert.tile_preview[cid], np.uint8)
    if orig in _edits:
        # tile_preview already had the edit applied; recompute the auto version
        sidx = convert.til_idx[orig * 8:orig * 8 + 8, :]
        img = convert.til_rgb[sidx]
        c = convert.dither(img, np.ones((8, 8), bool), full=True)
    auto_cols[orig] = np.array(c, np.uint8)

edits = {int(k): np.array(v, np.uint8) for k, v in _edits.items()}


def col_to_img(col, sx, sy):
    """col (16,8) -> PIL image scaled sx,sy (nearest)."""
    rgb = convert.col_to_rgb(col.astype(np.int64))
    im = Image.fromarray(rgb.astype(np.uint8), 'RGB')
    return im.resize((im.width * sx, im.height * sy), Image.NEAREST)


class Editor:
    def __init__(self, root, lv, sub):
        self.root = root
        self.lv, self.sub = lv, sub
        self.sel_orig = None
        self.cur_colour = 3
        root.title('Cleo tile editor')

        top = tk.Frame(root); top.pack(side=tk.TOP, fill=tk.X)
        tk.Label(top, text='Level:').pack(side=tk.LEFT)
        self.lvvar = tk.StringVar(value=str(lv))
        tk.Spinbox(top, from_=0, to=7, width=3, textvariable=self.lvvar,
                   command=self.reload_level).pack(side=tk.LEFT)
        self.subvar = tk.StringVar(value=sub)
        tk.OptionMenu(top, self.subvar, 'main', 'A', command=lambda *_: self.reload_level()).pack(side=tk.LEFT)
        self.info = tk.Label(top, text='click a tile'); self.info.pack(side=tk.LEFT, padx=12)

        body = tk.Frame(root); body.pack(side=tk.TOP, fill=tk.BOTH, expand=True)
        # left: scrollable level canvas
        lf = tk.Frame(body); lf.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.canvas = tk.Canvas(lf, bg='#202020', width=900, height=640)
        hb = tk.Scrollbar(lf, orient=tk.HORIZONTAL, command=self.canvas.xview)
        vb = tk.Scrollbar(lf, orient=tk.VERTICAL, command=self.canvas.yview)
        self.canvas.configure(xscrollcommand=hb.set, yscrollcommand=vb.set)
        hb.pack(side=tk.BOTTOM, fill=tk.X); vb.pack(side=tk.RIGHT, fill=tk.Y)
        self.canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.canvas.bind('<Button-1>', self.on_level_click)
        self.canvas.bind('<ButtonPress-2>', lambda e: self.canvas.scan_mark(e.x, e.y))
        self.canvas.bind('<B2-Motion>', lambda e: self.canvas.scan_dragto(e.x, e.y, gain=1))

        # right: tile editor
        rf = tk.Frame(body, padx=8); rf.pack(side=tk.RIGHT, fill=tk.Y)
        pal = tk.Frame(rf); pal.pack(side=tk.TOP, pady=4)
        self.swatches = []
        for i in range(8):
            r, g, b = convert.BEEB_RGB[i]
            sw = tk.Label(pal, width=2, height=1, bg='#%02x%02x%02x' % (r, g, b),
                          relief=tk.RAISED, bd=3)
            sw.grid(row=0, column=i, padx=1)
            sw.bind('<Button-1>', lambda e, i=i: self.pick_colour(i))
            self.swatches.append(sw)
        self.tile_canvas = tk.Canvas(rf, width=8 * CELL, height=8 * CELL, bg='#101010')
        self.tile_canvas.pack(side=tk.TOP, pady=6)
        self.tile_canvas.bind('<Button-1>', self.on_pixel)
        self.tile_canvas.bind('<B1-Motion>', self.on_pixel)
        btns = tk.Frame(rf); btns.pack(side=tk.TOP)
        tk.Button(btns, text='Generalise', command=self.generalise).pack(side=tk.LEFT)
        tk.Button(btns, text='Revert tile', command=self.revert_tile).pack(side=tk.LEFT, padx=6)
        tk.Button(btns, text='Save', command=self.save).pack(side=tk.LEFT, padx=6)
        self.status = tk.Label(rf, text='', fg='#080'); self.status.pack(side=tk.TOP)

        self.pick_colour(3)
        self.reload_level()

    # ---- level view ----
    def reload_level(self):
        self.lv = int(self.lvvar.get())
        self.sub = self.subvar.get()
        L = convert.parse_level(self.lv, 1 if self.sub == 'main' else 0)
        self.L = L
        m = L['map']; h, w = m.shape
        big = np.zeros((h * TILE_H, w * TILE_W, 3), np.uint8) + 32
        for ty in range(h):
            for tx in range(w):
                t = int(m[ty, tx])
                if t < 0 or t not in tile_cols:
                    continue
                rgb = convert.col_to_rgb(tile_cols[t].astype(np.int64)).astype(np.uint8)  # (16,8,3)
                cell = np.repeat(rgb, 2, axis=1)                                          # (16,16,3)
                big[ty * TILE_H:ty * TILE_H + 16, tx * TILE_W:tx * TILE_W + 16] = cell
        im = Image.fromarray(big, 'RGB')
        im = im.resize((im.width * ZOOM, im.height * ZOOM), Image.NEAREST)
        self.level_img = ImageTk.PhotoImage(im)
        self.canvas.delete('all')
        self.canvas.create_image(0, 0, anchor=tk.NW, image=self.level_img)
        self.canvas.config(scrollregion=(0, 0, im.width, im.height))
        self.sel_rect = None

    def on_level_click(self, e):
        x = int(self.canvas.canvasx(e.x)); y = int(self.canvas.canvasy(e.y))
        tx = x // (TILE_W * ZOOM); ty = y // (TILE_H * ZOOM)
        m = self.L['map']; h, w = m.shape
        if not (0 <= tx < w and 0 <= ty < h):
            return
        t = int(m[ty, tx])
        if t < 0 or t not in tile_cols:
            self.info.config(text='empty / unused tile'); return
        self.sel_orig = t
        self.info.config(text='tile id %d  at (%d,%d)  compact %d%s'
                         % (t, tx, ty, convert.orig2compact.get(t, -1),
                            '  [edited]' if t in edits else ''))
        if self.sel_rect:
            self.canvas.delete(self.sel_rect)
        self.sel_rect = self.canvas.create_rectangle(
            tx * TILE_W * ZOOM, ty * TILE_H * ZOOM,
            (tx + 1) * TILE_W * ZOOM, (ty + 1) * TILE_H * ZOOM, outline='#0f0', width=2)
        self.draw_tile()

    # ---- tile editor ----
    def pick_colour(self, i):
        self.cur_colour = i
        for j, sw in enumerate(self.swatches):
            sw.config(relief=tk.SUNKEN if j == i else tk.RAISED)

    def draw_tile(self):
        self.tile_canvas.delete('all')
        if self.sel_orig is None:
            return
        col = tile_cols[self.sel_orig]     # (16,8)
        # show as 8x8 game pixels: each game px = two scanlines (rows 2k,2k+1)
        for gy in range(8):
            for gx in range(8):
                c = int(col[gy * 2, gx]) & 7
                r, g, b = convert.BEEB_RGB[c]
                self.tile_canvas.create_rectangle(
                    gx * CELL, gy * CELL, gx * CELL + CELL, gy * CELL + CELL,
                    fill='#%02x%02x%02x' % (r, g, b), outline='#333')

    def on_pixel(self, e):
        if self.sel_orig is None:
            return
        gx = e.x // CELL; gy = e.y // CELL
        if not (0 <= gx < 8 and 0 <= gy < 8):
            return
        col = tile_cols[self.sel_orig].copy()
        col[gy * 2, gx] = self.cur_colour       # set both scanlines of the game pixel
        col[gy * 2 + 1, gx] = self.cur_colour
        tile_cols[self.sel_orig] = col
        edits[self.sel_orig] = col
        self.draw_tile()
        self.refresh_tile_in_level(self.sel_orig)
        self.status.config(text='edited (unsaved)')

    def refresh_tile_in_level(self, orig):
        # redraw only the cells of the level using this tile (cheap: full reload)
        self.reload_level()
        # keep selection highlight
        if self.sel_orig is not None:
            self.info.config(text='tile id %d  [edited]' % self.sel_orig)

    def generalise(self):
        # Learn how edited pixels were recoloured, keyed by (source colour, the
        # pixel's automatic dither colour), then apply that mapping to every
        # not-yet-edited pixel of the tile with a matching (source, auto) pair.
        if self.sel_orig is None:
            return
        orig = self.sel_orig
        col = tile_cols[orig].copy()
        auto = auto_cols[orig]
        sidx = convert.til_idx[orig * 8:orig * 8 + 8, :]     # (8,8) source indices
        remap = {}
        for gy in range(8):
            for gx in range(8):
                a = int(auto[gy * 2, gx]); c = int(col[gy * 2, gx])
                if c != a:                                    # edited pixel
                    remap[(int(sidx[gy, gx]), a)] = c
        if not remap:
            self.status.config(text='no edited pixels to generalise from')
            return
        n = 0
        for gy in range(8):
            for gx in range(8):
                a = int(auto[gy * 2, gx]); c = int(col[gy * 2, gx])
                if c == a:                                    # not yet edited
                    key = (int(sidx[gy, gx]), a)
                    if key in remap:
                        col[gy * 2, gx] = remap[key]
                        col[gy * 2 + 1, gx] = remap[key]
                        n += 1
        tile_cols[orig] = col
        edits[orig] = col
        self.draw_tile(); self.reload_level()
        self.status.config(text='generalised to %d more pixel(s) (unsaved)' % n)

    def revert_tile(self):
        if self.sel_orig is None:
            return
        tile_cols[self.sel_orig] = auto_cols[self.sel_orig].copy()
        edits.pop(self.sel_orig, None)
        self.draw_tile(); self.reload_level()
        self.status.config(text='reverted (unsaved)')

    def save(self):
        out = {str(k): v.tolist() for k, v in edits.items()}
        with open(convert._edits_path, 'w') as f:
            json.dump(out, f)
        self.status.config(text='saved %d edits -> build/tile_edits.json' % len(out))


def main():
    lv = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    sub = sys.argv[2] if len(sys.argv) > 2 else 'main'
    root = tk.Tk()
    Editor(root, lv, sub)
    root.mainloop()


if __name__ == '__main__':
    main()
