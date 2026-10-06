// The Model B's two rings against the level's tiles (the Master's is tilecheck.mjs):
// at every frame_top, for each valid buffer (BUF_CXH bit 7 clear), every char cell of
// its VISROWS x 80 window that no sprite record of either buffer comes within two cells
// of must hold the bytes of the tile its map id names: the id from MAP5 in bank 5 at
// ((cy >> 1) + r) * (1 << maplw) + (cx >> 2) + t, the bytes from <idsdir>/L<level>.bin
// (python3 tools/tileids.py: 256 ids x 64 bytes, a tile being 4 chars x 2 rows, at
// id * 64 + (y & 1) * 32 + (x & 3) * 8), the cell in the ring at RING[buffer] +
// ((y % RINGROWS) * ROWBYTES + x * 8) % RINGBYTES.  The sprite records are SPRREC's
// 10-byte records (column at +5/+6, row +7, width +8, height +9 bit 7 clipped), MAXREC
// = (RECCNT - SPRREC) / 20.  Independent of the packer's layout and the gather: it
// reads only the map and the screen.
// Opened by bopen.mjs openB; each frame is a break at frame_top, with 'keys' from the
// fixed pattern PAT (s idle, r RIGHT, l LEFT, j UP+RIGHT: a running jump) and hurt = 1,
// health = 3 written there.
//   node test/btilecheck.mjs <disc> <labels> <level> <frames> [idsdir=build/tileids]
// MIR=lo,hi also counts the cells whose id is in [lo, hi) (e.g. the mirror kind's ids).
// Output: the first five bad cells, then "B L<n>: tiles ok | BAD <cells> cells on
// <frames> frames (<cells> cells checked, <n> mirrored)".  The exit status is 0 either
// way: read the line.
import { openB } from "./bopen.mjs";
import fs from "fs";
const [disc, labels, lvS, nS, dir = "build/tileids"] = process.argv.slice(2);
const lv = +lvS, N = +nS;
// TP="x,y;x,y;...": Cleo put at each (game pixels) in turn, TPF frames each (20), the
// camera following her -- to bring chosen map cells into the window
const TP = (process.env.TP ?? '').split(';').filter(Boolean).map(p => p.split(',').map(Number)), TPF = +(process.env.TPF ?? 20);
const exp = fs.readFileSync(`${dir}/L${lv}.bin`);
const B = await openB({ level: lv, disc, labels });
const { cpu, A, bank } = B;
const rd = a => cpu.readmem(a);
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KEYS = { s: 0, r: 2, l: 1, j: 6 };
const MAXREC = (A.RECCNT - A.SPRREC) / 20;
// the display's layout, from the build's defs_ld.inc (harness loadLabels); the literals
// are for a build from before it carried them (23 rows of 640 bytes, 21 visible)
const RINGROWS = A.RINGROWS ?? 23, ROWBYTES = A.ROWBYTES ?? 640, VISROWS = A.VISROWS ?? 21, MAP5 = A.MAP5 ?? 0x9C00;
const RING = [A.RING_A ?? 0x0A80, A.RING_B ?? 0x4680], RB = A.RINGBYTES ?? RINGROWS * ROWBYTES;
let bad = 0, cells = 0, badf = 0, mc = 0; const MR = (process.env.MIR ?? '0,0').split(',').map(Number);
for (let f = 0; f < N; f++) {
  bank(7, () => { cpu.writemem(A.keys, KEYS[PAT[f % PAT.length]]); cpu.writemem(A.hurt, 1); cpu.writemem(A.health, 3); });
  if (TP.length) bank(7, () => { const [x, y] = TP[Math.floor(f / TPF) % TP.length]; cpu.writemem(A.px, x & 255); cpu.writemem(A.px + 1, x >> 8); cpu.writemem(A.py, y & 255); cpu.writemem(A.py + 1, y >> 8); });
  await B.runTo(A.frame_top, 7);
  const lw = rd(A.maplw), stride = 1 << lw;
  let fb = 0;
  for (const bf of [0, 1]) {
    const cx = (A.BUF_CXH !== undefined ? rd(A.BUF_CXL + bf) | (rd(A.BUF_CXH + bf) << 8) : rd(A.BUF_CXL + 2 * bf) | (rd(A.BUF_CXL + 2 * bf + 1) << 8));
    if (cx & 0x8000) continue;
    const cy = bank(6, () => rd(A.BUF_CY + bf));
    const recs = bank(7, () => { const r = []; for (const b2 of [0, 1]) for (let i = 0; i < rd(A.RECCNT + b2); i++) { const b = A.SPRREC + (b2 * MAXREC + i) * 10;
      r.push([rd(b + 5) | (rd(b + 6) << 8), rd(b + 7), rd(b + 8), rd(b + 9) & 0x7f]); } return r; });
    const near = (x, y) => recs.some(([rx, ry, w, h]) => x >= rx - 2 && x <= rx + w + 2 && y >= ry - 2 && y <= ry + h + 2);
    const map = bank(5, () => { const m = []; for (let r = 0; r < 12; r++) { const row = []; for (let t = 0; t < 22; t++) row.push(rd(MAP5 + (((cy >> 1) + r) * stride) + (cx >> 2) + t)); m.push(row); } return m; });
    for (let r = 0; r < VISROWS; r++) for (let c = 0; c < 80; c++) {
      const x = cx + c, y = cy + r;
      if (near(x, y)) continue;
      const id = map[(y >> 1) - (cy >> 1)][(x >> 2) - (cx >> 2)];
      const a = RING[bf] + (((y % RINGROWS) * ROWBYTES + x * 8) % RB);
      const o = id * 64 + (y & 1) * 32 + (x & 3) * 8;
      cells++; if (id >= MR[0] && id < MR[1]) mc++;
      for (let l = 0; l < 8; l++) if (rd(a + l) !== exp[o + l]) { fb++; if (bad + fb <= 5) console.log(`f${f} buf${bf} cell (${x},${y}) id ${id} line ${l}: ${rd(a+l).toString(16)} want ${exp[o+l].toString(16)}`); break; }
    }
  }
  if (fb) badf++; bad += fb;
}
console.log(`B L${lv}: ${bad ? `BAD ${bad} cells on ${badf} frames` : "tiles ok"} (${cells} cells checked, ${mc} mirrored)`);
process.exit(0);
