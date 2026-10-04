// Two Model B builds, frame by frame: each buffer's 21 visible rows at its own window
// (BUF_CXL/BUF_CY) in its ring, and the bar -- what the player can see.  The same key
// script as wincmp.mjs (the Master's), with the player held unhurt.
//   node test/bwincmp.mjs <discA> <labelsA> <discB> <labelsB> <level> [frames=300]
// Each build's debug file (beside its labels) says which bank BUF_CY is in.
import { openB } from "./bopen.mjs";
import { loadBanks, dbgPath } from "./harness.mjs";
import path from "node:path";
const [dA, lA, dB, lB, lvS, nS = "300"] = process.argv.slice(2);
const builds = [[dA, lA], [dB, lB]];
const M = await Promise.all(builds.map(([disc, labels]) => openB({ level: +lvS, disc, labels })));
M.forEach((m, i) => { m.cyBank = loadBanks(dbgPath(builds[i][1]))?.byName.get("BUF_CY") ?? 6; });
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
// SEED=n: seeded random keys instead of the pattern -- with throws (DOWN) and fire, which
// the pattern never presses (a boomerang-only path once got past the sweep that way)
let _rng = (+(process.env.SEED ?? 0)) >>> 0, _k = 0, _hold = 0, _kf = -1;
const RK = (f) => { if (f !== _kf) { _kf = f; if (_hold-- <= 0) { _rng = (_rng * 1103515245 + 12345) >>> 0; const r = _rng >>> 16; _k = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8, 16][r % 10]; _hold = 2 + (r >> 4) % 25; } } return _k; };
const KEYAT = (f) => process.env.SEED ? RK(f) : KK(PAT[f % PAT.length]);
const KK = (c) => ({ s: 0, r: 2, l: 1, j: 4 })[c] ?? 0;
const RING = [0x0A80, 0x4680], RINGBYTES = 23 * 640, BAR = [0x0300, 0x0800];
const window = (m, bf) => [m.A.BUF_CXH !== undefined ? m.cpu.readmem(m.A.BUF_CXL + bf) | (m.cpu.readmem(m.A.BUF_CXH + bf) << 8)
                                                     : m.cpu.readmem(m.A.BUF_CXL + 2 * bf) | (m.cpu.readmem(m.A.BUF_CXL + 2 * bf + 1) << 8),
                           m.bank(m.cyBank, () => m.cpu.readmem(m.A.BUF_CY + bf))];
let bad = 0, badFrames = 0;
for (let f = 0; f < +nS; f++) {
  for (const m of M) {
    m.bank(7, () => { m.cpu.writemem(m.A.keys, KEYAT(f)); m.cpu.writemem(m.A.hurt, 1); m.cpu.writemem(m.A.health, 3); });
    await m.runTo(m.A.frame_top, 7);
  }
  let fb = 0;
  for (const bf of [0, 1]) {
    const [cx, cy] = window(M[0], bf), [cx2, cy2] = window(M[1], bf);
    if (cx !== cx2 || cy !== cy2) { fb++; continue; }
    if (cx & 0x8000) continue;                          // an invalid buffer: nothing shown
    for (let r = 0; r < 21; r++) for (let c = 0; c < 80; c++) {
      const a = RING[bf] + ((((cy + r) % 23) * 640 + (cx + c) * 8) % RINGBYTES);
      for (let l = 0; l < 8; l++) if (M[0].cpu.readmem(a + l) !== M[1].cpu.readmem(a + l)) {
        fb++; if (bad + fb <= 3) console.log(`f${f} buf${bf} row ${r} col ${c}`); break;
      }
    }
  }
  for (let a = BAR[0]; a < BAR[1]; a++) if (M[0].cpu.readmem(a) !== M[1].cpu.readmem(a)) { fb++; break; }
  if (fb) badFrames++;
  bad += fb;
}
console.log(`B L${lvS}: windows ${bad ? `DIFFER: ${bad} cells on ${badFrames} frames` : "identical"} over ${nS} frames`);
process.exit(bad ? 1 : 0);
