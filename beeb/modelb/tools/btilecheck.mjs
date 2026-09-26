// The Model B's two rings against the level's tiles (tools/tilecheck.mjs's check): at
// every frame_top, each buffer's window, every char cell no sprite record comes near.
// MIR=lo,hi counts the cells whose id is in [lo, hi): the mirrored ids, say.
//   node tools/btilecheck.mjs <disc> <labels> <level> <frames> [idsdir=../build/tileids]
import { openB } from "./bopen.mjs";
import fs from "fs";
const [disc, labels, lvS, nS, dir = "../build/tileids"] = process.argv.slice(2);
const lv = +lvS, N = +nS;
const exp = fs.readFileSync(`${dir}/L${lv}.bin`);
const B = await openB({ level: lv, disc, labels });
const { cpu, A, bank } = B;
const rd = a => cpu.readmem(a);
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KEYS = { s: 0, r: 2, l: 1, j: 6 };
const MAXREC = (A.RECCNT - A.SPRREC) / 20;
const RING = [0x0A80, 0x4680], RB = 23 * 640;
let bad = 0, cells = 0, badf = 0, mc = 0; const MR = (process.env.MIR ?? '0,0').split(',').map(Number);
for (let f = 0; f < N; f++) {
  bank(7, () => { cpu.writemem(A.keys, KEYS[PAT[f % PAT.length]]); cpu.writemem(A.hurt, 1); cpu.writemem(A.health, 3); });
  await B.runTo(A.frame_top, 7);
  const lw = rd(A.maplw), stride = 1 << lw;
  let fb = 0;
  for (const bf of [0, 1]) {
    const cx = rd(A.BUF_CX + 2 * bf) | (rd(A.BUF_CX + 2 * bf + 1) << 8);
    if (cx & 0x8000) continue;
    const cy = bank(5, () => rd(A.BUF_CY + bf));
    const recs = bank(7, () => { const r = []; for (const b2 of [0, 1]) for (let i = 0; i < rd(A.RECCNT + b2); i++) { const b = A.SPRREC + (b2 * MAXREC + i) * 10;
      r.push([rd(b + 5) | (rd(b + 6) << 8), rd(b + 7), rd(b + 8), rd(b + 9) & 0x7f]); } return r; });
    const near = (x, y) => recs.some(([rx, ry, w, h]) => x >= rx - 2 && x <= rx + w + 2 && y >= ry - 2 && y <= ry + h + 2);
    const map = bank(6, () => { const m = []; for (let r = 0; r < 12; r++) { const row = []; for (let t = 0; t < 22; t++) row.push(rd(0x8800 + (((cy >> 1) + r) * stride) + (cx >> 2) + t)); m.push(row); } return m; });
    for (let r = 0; r < 21; r++) for (let c = 0; c < 80; c++) {
      const x = cx + c, y = cy + r;
      if (near(x, y)) continue;
      const id = map[(y >> 1) - (cy >> 1)][(x >> 2) - (cx >> 2)];
      const a = RING[bf] + (((y % 23) * 640 + x * 8) % RB);
      const o = id * 64 + (y & 1) * 32 + (x & 3) * 8;
      cells++; if (id >= MR[0] && id < MR[1]) mc++;
      for (let l = 0; l < 8; l++) if (rd(a + l) !== exp[o + l]) { fb++; if (bad + fb <= 5) console.log(`f${f} buf${bf} cell (${x},${y}) id ${id} line ${l}: ${rd(a+l).toString(16)} want ${exp[o+l].toString(16)}`); break; }
    }
  }
  if (fb) badf++; bad += fb;
}
console.log(`B L${lv}: ${bad ? `BAD ${bad} cells on ${badf} frames` : "tiles ok"} (${cells} cells checked, ${mc} mirrored)`);
process.exit(0);
