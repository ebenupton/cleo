// Two Master builds' DISPLAYABLE screen, frame by frame: the window's 30 rows (and the
// partial rows above and below when the fine scroll is not 0) in the buffer the CPU
// sees, and the bar -- plus the scene fingerprint.  Not all 40K of screen RAM: the
// ring's hidden rows may be filled differently by builds (the rows past a map's end
// are read there, and what lies past the map is a layout's choice).  bwincmp.mjs is
// the Model B's.
//   node test/wincmp.mjs <discA> <labelsA> <discB> <labelsB> <level> [frames=300]
import { open } from "./harness.mjs";
const [dA, lA, dB, lB, lvS, nS] = process.argv.slice(2);
const lv = +lvS, N = +(nS ?? 300);
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
// SEED=n: seeded random keys instead of the pattern -- with throws (DOWN) and fire, which
// the pattern never presses (a boomerang-only path once got past the sweep that way)
let _rng = (+(process.env.SEED ?? 0)) >>> 0, _k = 0, _hold = 0, _kf = -1;
const RK = (f) => { if (f !== _kf) { _kf = f; if (_hold-- <= 0) { _rng = (_rng * 1103515245 + 12345) >>> 0; const r = _rng >>> 16; _k = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8, 16][r % 10]; _hold = 2 + (r >> 4) % 25; } } return _k; };
const KEYAT = (f) => process.env.SEED ? RK(f) : KK(PAT[f % PAT.length]);
const KK = c => ({ s: 0, r: 2, l: 1, j: 4 })[c] ?? 0;
const M = await open({ disc: dA, labels: lA, level: lv });
const C = await open({ disc: dB, labels: lB, level: lv });
// RELOAD=1: end the level once and compare after it loads again (the loader's second
// path: the resident SPRC and SPRX, the main-RAM entry state)
if (process.env.RELOAD) for (const H of [M, C]) { H.wr(H.A.exiting, 1); await H.runTo(H.A.level_init, 400_000_000); await H.runTo(H.A.frame_top, 40_000_000); }
// the display's layout, from the reference build's defs_ld.inc (harness loadLabels);
// the literals are for a build from before it carried them
const L = M.A, RINGBASE = L.RINGBASE ?? 0x3000, RINGCHARS = L.RINGCHARS ?? 2560, VISROWS = L.VISROWS ?? 30;
const BAR0 = L.BARADDR ?? 0x2B00, BAR1 = BAR0 + (L.BARROWS ?? 2) * (L.ROWBYTES ?? 640);
let bad = 0, badf = 0, sceneBad = 0;
for (let f = 0; f < N; f++) {
  for (const H of [M, C]) { H.wr(H.A.keys, KEYAT(f)); H.wr(H.A.hurt, 1); H.wr(H.A.health, 3); await H.runTo(H.A.frame_top); }
  if (M.fingerprint().fp !== C.fingerprint().fp) sceneBad++;
  const wcx = M.rd16(M.A.wcx), wcy = M.rd(M.A.wcy), wfine = M.rd(M.A.wfine);
  const S = (wcy * 80 + wcx) % RINGCHARS;
  const r0 = wfine ? -1 : 0, r1 = wfine ? VISROWS + 1 : VISROWS;
  let fb = 0;
  for (let r = r0; r < r1; r++) for (let c = 0; c < 80; c++) {
    const a = RINGBASE + (((S + r * 80 + c) % RINGCHARS + RINGCHARS) % RINGCHARS) * 8;
    // the lines shown: the composed row above (-1) its first 8 - f, the partial below its first f
    const l0 = 0, l1 = r === -1 ? 8 - wfine : r === VISROWS ? wfine : 8;
    for (let l = l0; l < l1; l++) if (M.rd(a + l) !== C.rd(a + l)) { fb++; if (bad + fb <= 3) console.log(`f${f} row ${r} col ${c}`); break; }
  }
  for (let a = BAR0; a < BAR1; a++) if (M.rd(a) !== C.rd(a)) { fb++; if (bad + fb <= 3) console.log(`f${f} bar ${a.toString(16)}`); break; }
  if (fb) badf++; bad += fb;
}
console.log(`L${lv}: window ${bad ? `DIFFERS: ${bad} cells on ${badf} frames` : "identical"}; scene ${sceneBad ? `differs on ${sceneBad} frames` : "identical"} over ${N} frames`);
process.exit(bad || sceneBad ? 1 : 0);
