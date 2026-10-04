// The Master's drawn window against the level's tiles (the Model B's is
// btilecheck.mjs): at every frame_top, in the buffer the CPU sees (ACCCON X, bit 2 of
// $FE34), every char cell of its VISROWS x 80 window at that buffer's BUF_CXL/BUF_CXH
// and BUF_CY (skipped when the buffer is invalid, bit 15) that no sprite record of
// either buffer comes within two cells of must hold the bytes of the tile its map id
// names: the id from MAP5 in bank 5 at ((cy >> 1) + r) * (1 << maplw) + (cx >> 2) + t,
// the bytes from <idsdir>/L<level>.bin (python3 tools/tileids.py: 256 ids x 64 bytes,
// a tile being 4 chars x 2 rows, at id * 64 + (y & 1) * 32 + (x & 3) * 8), the cell in
// the hardware ring at RINGBASE + ((y * 80 + x) % RINGCHARS) * 8.  The sprite records
// are SPRREC's 10-byte records (column at +5/+6, row +7, width +8, height +9 bit 7
// clipped), MAXREC = (RECCNT - SPRREC) / 20.  Independent of the packer's layout and
// the gather: it reads only the map and the screen.
// Opened by harness.mjs open; each frame is a break at frame_top, with 'keys' from the
// fixed pattern PAT (s idle, r RIGHT, l LEFT, j UP+RIGHT: a running jump) and hurt = 1,
// health = 3 written there.
//   node test/tilecheck.mjs <disc> <labels> <level> <frames> [idsdir=build/tileids]
// Output: the first five bad cells, then "L<n>: tiles ok | BAD <cells> cells on
// <frames> frames (<cells> cells checked)".  The exit status is 0 either way: read
// the line.
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
// the display's layout, from the build's defs_ld.inc (harness loadLabels); the literals
// are for a build from before it carried them (a 32-row ring of 2560 chars from $3000,
// 30 rows visible)
const RINGBASE = A.RINGBASE ?? 0x3000, RINGCHARS = A.RINGCHARS ?? 2560, VISROWS = A.VISROWS ?? 30, MAP5 = A.MAP5 ?? 0x9C00;
let bad = 0, cells = 0, badf = 0;
const bank = (b, f) => { const was = H.rd((A.romsel_cpy ?? 0xf4)); H.wr((A.romsel_cpy ?? 0xf4), b); H.wr(0xfe30, b); const r = f(); H.wr((A.romsel_cpy ?? 0xf4), was); H.wr(0xfe30, was); return r; };
for (let f = 0; f < N; f++) {
  const pc = PAT[f % PAT.length]; const k = pc === "j" ? 6 : KEYS[pc];
  H.wr(A.keys, k); H.wr(A.hurt, 1); H.wr(A.health, 3);
  await H.runTo(A.frame_top);
  const cur = (H.rd(0xfe34) >> 2) & 1;   // the buffer the CPU sees (ACCCON X: 1 = shadow)
  const cx = H.inBank("BUF_CXL", () => (A.BUF_CXH !== undefined ? H.rd(A.BUF_CXL + cur) | (H.rd(A.BUF_CXH + cur) << 8) : H.rd(A.BUF_CXL + 2 * cur) | (H.rd(A.BUF_CXL + 2 * cur + 1) << 8))), cy = H.inBank("BUF_CY", () => H.rd(A.BUF_CY + cur));
  if (cx & 0x8000) continue;
  const lw = H.rd(A.maplw), stride = 1 << lw;
  const recs = [];
  H.inBank("SPRREC", () => { for (const bf of [0, 1]) { const nrec = H.rd(A.RECCNT + bf);
  for (let i = 0; i < nrec; i++) { const b = A.SPRREC + (bf * MAXREC + i) * 10;
    recs.push([H.rd(b + 5) | (H.rd(b + 6) << 8), H.rd(b + 7), H.rd(b + 8), H.rd(b + 9) & 0x7f]); } } });
  const near = (x, y) => recs.some(([rx, ry, w, h]) => x >= rx - 2 && x <= rx + w + 2 && y >= ry - 2 && y <= ry + h + 2);
  let fb = 0;
  const map = bank(5, () => { const m = []; for (let r = 0; r < 16; r++) { const row = []; for (let t = 0; t < 22; t++) row.push(H.rd(MAP5 + (((cy >> 1) + r) * stride) + (cx >> 2) + t)); m.push(row); } return m; });
  for (let r = 0; r < VISROWS; r++) for (let c = 0; c < 80; c++) {
    const x = cx + c, y = cy + r;
    if (near(x, y)) continue;
    const id = map[(y >> 1) - (cy >> 1)][(x >> 2) - (cx >> 2)];
    const a = RINGBASE + (((y * 80 + x) % RINGCHARS) * 8);
    const o = id * 64 + (y & 1) * 32 + (x & 3) * 8;
    cells++;
    for (let l = 0; l < 8; l++) if (H.rd(a + l) !== exp[o + l]) { fb++; if (bad + fb <= 5) console.log(`f${f} cell (${x},${y}) id ${id} line ${l}: ${H.rd(a+l).toString(16)} want ${exp[o+l].toString(16)}`); break; }
  }
  if (fb) badf++; bad += fb;
}
console.log(`L${lv}: ${bad ? `BAD ${bad} cells on ${badf} frames` : "tiles ok"} (${cells} cells checked)`);
