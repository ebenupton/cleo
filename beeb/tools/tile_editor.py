#!/usr/bin/env python3
"""Cleo's tile dither editor: a Tk window to repaint a tile's dither by hand.

Shows a level's map zoomed, lets you click a tile to select it, and paint its 16 x 8 grid of
dots (16 scanlines by 8 game pixels; a game pixel is two scanlines) in the eight BBC
colours.  Edits are saved to beeb/tile_edits.json (convert._edits_path: beside tools/, not
under build/), keyed by the original tile id; convert.py reads that file, when present, and
uses the saved arrays in place of its automatic dither for those tiles -- run ./build.sh to
get them on to the disc.

Run from the beeb/ directory:
    python3 tools/tile_editor.py [level=0] [main|A]
The level is 0..7; the second argument picks which of the level file's two maps is shown:
'main' is convert.parse_level's sub 1, 'A' its sub 0.

Level view: middle-button drag scrolls (or the scrollbars).  Click a tile to select it.  In
the editor on the right, pick a palette colour then click or drag over dots to paint them.
"Generalise" extends the selected tile's edits to its other dots with the same source colour
and automatic dither colour.  "Revert tile" restores the automatic dither.  "Save" writes
the file.  Running convert.py takes a while: the window opens once it has finished.
"""
import os
import sys
import json
import numpy as np
import tkinter as tk
from PIL import Image, ImageTk

sys.path.insert(0, os.path.dirname(__file__))
# runs the converter once: the dither, the tiles and the levels come from it
import convert  # noqa: E402

ZOOM = 2
# a tile in the level view: 8 game px doubled to 16 wide, 16 scanlines tall (before ZOOM)
TILE_W, TILE_H = 16, 16
# an editor cell: a dot is one scanline tall and a game pixel wide, so 2:1
CW, CH = 26, 13
PALETTE_NAMES = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white']

# the tiles as convert.py has them (16 scanlines x 8), by original tile id, edits included
compact = convert.compact
tile_cols = {}
for cid, orig in enumerate(compact):
    tile_cols[orig] = np.array(convert.tile_preview[cid], np.uint8).copy()
# the automatic dither of each, for "revert": convert.py applied the saved edits to
# tile_preview, so an edited tile's is dithered again here
auto_cols = {}
_edits = dict(convert.TILE_EDITS)
for cid, orig in enumerate(compact):
    c = np.array(convert.tile_preview[cid], np.uint8)
    if orig in _edits:
        sidx = convert.til_idx[orig * 8:orig * 8 + 8, :]
        img = convert.til_rgb[sidx]
        c = convert.dither(img, np.ones((8, 8), bool), full=True)
    auto_cols[orig] = np.array(c, np.uint8)

edits = {int(k): np.array(v, np.uint8) for k, v in _edits.items()}


def col_to_img(col, sx, sy):
    """A (16, 8) dither array as a PIL image scaled sx by sy (nearest neighbour)."""
    rgb = convert.col_to_rgb(col.astype(np.int64))
    im = Image.fromarray(rgb.astype(np.uint8), 'RGB')
    return im.resize((im.width * sx, im.height * sy), Image.NEAREST)


class Editor:
    """The window: the level view on the left, the palette, tile canvas and buttons on the
    right."""
    def __init__(self, root, lv, sub):
        """Build the widgets for level lv, map sub ('main' or 'A'), and show it."""
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
        # left: the scrollable level canvas
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

        # right: the tile editor
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
        self.tile_canvas = tk.Canvas(rf, width=8 * CW, height=16 * CH, bg='#101010')
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
        """Redraw the level view from the spinbox and menu: the map's tiles from tile_cols,
        each game pixel doubled across, the whole scaled by ZOOM; drops the selection
        rectangle."""
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
                rgb = convert.col_to_rgb(tile_cols[t].astype(np.int64)).astype(np.uint8)
                cell = np.repeat(rgb, 2, axis=1)
                big[ty * TILE_H:ty * TILE_H + 16, tx * TILE_W:tx * TILE_W + 16] = cell
        im = Image.fromarray(big, 'RGB')
        im = im.resize((im.width * ZOOM, im.height * ZOOM), Image.NEAREST)
        self.level_img = ImageTk.PhotoImage(im)
        self.canvas.delete('all')
        self.canvas.create_image(0, 0, anchor=tk.NW, image=self.level_img)
        self.canvas.config(scrollregion=(0, 0, im.width, im.height))
        self.sel_rect = None

    def on_level_click(self, e):
        """Select the tile under the click: report its id, map position and compact id,
        outline it, and show it in the editor."""
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
        """Make palette entry i the paint colour and sink its swatch."""
        self.cur_colour = i
        for j, sw in enumerate(self.swatches):
            sw.config(relief=tk.SUNKEN if j == i else tk.RAISED)

    def draw_tile(self):
        """Draw the selected tile's dots on the editor canvas, a heavier line between game
        pixels (every second scanline)."""
        self.tile_canvas.delete('all')
        if self.sel_orig is None:
            return
        col = tile_cols[self.sel_orig]
        for sy in range(16):
            for sx in range(8):
                c = int(col[sy, sx]) & 7
                r, g, b = convert.BEEB_RGB[c]
                self.tile_canvas.create_rectangle(
                    sx * CW, sy * CH, sx * CW + CW, sy * CH + CH,
                    fill='#%02x%02x%02x' % (r, g, b),
                    outline='#555' if sy % 2 else '#222')

    def on_pixel(self, e):
        """Paint the dot under the pointer (one scanline of one game pixel) in the current
        colour, record the tile as edited and redraw both views."""
        if self.sel_orig is None:
            return
        sx = e.x // CW; sy = e.y // CH
        if not (0 <= sx < 8 and 0 <= sy < 16):
            return
        col = tile_cols[self.sel_orig].copy()
        col[sy, sx] = self.cur_colour
        tile_cols[self.sel_orig] = col
        edits[self.sel_orig] = col
        self.draw_tile()
        self.refresh_tile_in_level(self.sel_orig)
        self.status.config(text='edited (unsaved)')

    def refresh_tile_in_level(self, orig):
        """Show an edited tile in the level view (a full reload: cheap enough) and keep the
        info line on the selection."""
        self.reload_level()
        if self.sel_orig is not None:
            self.info.config(text='tile id %d  [edited]' % self.sel_orig)

    def generalise(self):
        """Extend the selected tile's edits: learn how edited dots were recoloured, keyed by
        (the dot's source palette index, its automatic dither colour), then apply that
        mapping to every unedited dot of the tile with a matching key."""
        if self.sel_orig is None:
            return
        orig = self.sel_orig
        col = tile_cols[orig].copy()
        auto = auto_cols[orig]
        sidx = convert.til_idx[orig * 8:orig * 8 + 8, :]
        remap = {}
        for sy in range(16):
            for sx in range(8):
                a = int(auto[sy, sx]); c = int(col[sy, sx])
                if c != a:
                    remap[(int(sidx[sy // 2, sx]), a)] = c
        if not remap:
            self.status.config(text='no edited pixels to generalise from')
            return
        n = 0
        for sy in range(16):
            for sx in range(8):
                a = int(auto[sy, sx]); c = int(col[sy, sx])
                if c == a:
                    key = (int(sidx[sy // 2, sx]), a)
                    if key in remap:
                        col[sy, sx] = remap[key]
                        n += 1
        tile_cols[orig] = col
        edits[orig] = col
        self.draw_tile(); self.reload_level()
        self.status.config(text='generalised to %d more pixel(s) (unsaved)' % n)

    def revert_tile(self):
        """Put the selected tile's automatic dither back and forget its edit."""
        if self.sel_orig is None:
            return
        tile_cols[self.sel_orig] = auto_cols[self.sel_orig].copy()
        edits.pop(self.sel_orig, None)
        self.draw_tile(); self.reload_level()
        self.status.config(text='reverted (unsaved)')

    def save(self):
        """Write every edit to convert._edits_path (beeb/tile_edits.json) as JSON: the
        original tile id to its 16 x 8 array."""
        out = {str(k): v.tolist() for k, v in edits.items()}
        with open(convert._edits_path, 'w') as f:
            json.dump(out, f)
        self.status.config(text='SAVED %d edits -> build/tile_edits.json' % len(out))


def main():
    """Open the editor on the level and map named on the command line."""
    lv = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    sub = sys.argv[2] if len(sys.argv) > 2 else 'main'
    root = tk.Tk()
    Editor(root, lv, sub)
    root.mainloop()


if __name__ == '__main__':
    main()
