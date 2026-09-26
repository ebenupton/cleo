// The Master's drawn window against the level's tiles: at every frame_top, every char
// cell of the buffer the CPU sees (ACCCON X) that no sprite record comes near must hold
// the bytes of the tile its map id names (tools/tileids.py).  Independent of the
// packer's layout and the gather: it reads only the map and the screen.
//   node tools/tilecheck.mjs <disc> <labels> <level> <frames> [idsdir=build/tileids]
import { open } from "./harness.mjs";
import fs from "fs";
const [disc, labels, lvS, nS, dir = "build/tileids"] = process.argv.slice(2);
const lv = +lvS, N = +nS;
const exp = fs.readFileSync(`${dir}/L${lv}.bin`);
const H = await open({ disc, labels, level: lv });
const A = H.A;
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KEYS = { s: 0, r: 2, l: 1, j: 4 };
const MAXREC = (A.RECCNT - A.SPRREC) / 20;
let bad = 0, cells = 0, badf = 0;
const bank = (b, f) => { const was = H.rd(0xf4); H.wr(0xf4, b); H.wr(0xfe30, b); const r = f(); H.wr(0xf4, was); H.wr(0xfe30, was); return r; };
for (let f = 0; f < N; f++) {
  const pc = PAT[f % PAT.length]; const k = pc === "j" ? 6 : KEYS[pc];
  H.wr(A.keys, k); H.wr(A.hurt, 1); H.wr(A.health, 3);
  await H.runTo(A.frame_top);
  const cur = (H.rd(0xfe34) >> 2) & 1;   // the buffer the CPU sees (ACCCON X)
  const cx = H.inBank("BUF_CX", () => H.rd(A.BUF_CX + 2 * cur) | (H.rd(A.BUF_CX + 2 * cur + 1) << 8)), cy = H.inBank("BUF_CY", () => H.rd(A.BUF_CY + cur));
  if (cx & 0x8000) continue;
  const lw = H.rd(A.maplw), stride = 1 << lw;
  const recs = [];
  H.inBank("SPRREC", () => { for (const bf of [0, 1]) { const nrec = H.rd(A.RECCNT + bf);
  for (let i = 0; i < nrec; i++) { const b = A.SPRREC + (bf * MAXREC + i) * 10;
    recs.push([H.rd(b + 5) | (H.rd(b + 6) << 8), H.rd(b + 7), H.rd(b + 8), H.rd(b + 9) & 0x7f]); } } });
  const near = (x, y) => recs.some(([rx, ry, w, h]) => x >= rx - 2 && x <= rx + w + 2 && y >= ry - 2 && y <= ry + h + 2);
  let fb = 0;
  const MAP = H.banks ? 0x8800 : 0x8900;   // (a banked build: the Model B's layout, MAP6)
  const map = bank(6, () => { const m = []; for (let r = 0; r < 16; r++) { const row = []; for (let t = 0; t < 22; t++) row.push(H.rd(MAP + (((cy >> 1) + r) * stride) + (cx >> 2) + t)); m.push(row); } return m; });
  for (let r = 0; r < 27; r++) for (let c = 0; c < 80; c++) {
    const x = cx + c, y = cy + r;
    if (near(x, y)) continue;
    const id = map[(y >> 1) - (cy >> 1)][(x >> 2) - (cx >> 2)];
    const a = 0x3000 + (((y * 80 + x) % 2560) * 8);
    const o = id * 64 + (y & 1) * 32 + (x & 3) * 8;
    cells++;
    for (let l = 0; l < 8; l++) if (H.rd(a + l) !== exp[o + l]) { fb++; if (bad + fb <= 5) console.log(`f${f} cell (${x},${y}) id ${id} line ${l}: ${H.rd(a+l).toString(16)} want ${exp[o+l].toString(16)}`); break; }
  }
  if (fb) badf++; bad += fb;
}
console.log(`L${lv}: ${bad ? `BAD ${bad} cells on ${badf} frames` : "tiles ok"} (${cells} cells checked)`);
