// Two Master-hardware builds' DISPLAYABLE screen, frame by frame: the window's 30 rows
// (and the partial rows above and below when the fine scroll is not 0) in the buffer
// the CPU sees, and the bar -- plus the scene fingerprint.  pixdiff compares all 40K of
// screen RAM; this ignores the ring's one hidden slot, which builds may fill
// differently (the rows past a map's end are read there, and what lies past the map is
// a layout's choice).  For the converged Master (modelb/build.sh TARGET=master) against
// the Master:
//   node tools/wincmp.mjs <discA> <labelsA> <discB> <labelsB> <level> [frames]
import { open } from "./harness.mjs";
const [dA, lA, dB, lB, lvS, nS] = process.argv.slice(2);
const lv = +lvS, N = +(nS ?? 300);
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KK = c => ({ s: 0, r: 2, l: 1, j: 4 })[c] ?? 0;
const M = await open({ disc: dA, labels: lA, level: lv });
const C = await open({ disc: dB, labels: lB, level: lv });
let bad = 0, badf = 0, sceneBad = 0;
for (let f = 0; f < N; f++) {
  for (const H of [M, C]) { H.wr(H.A.keys, KK(PAT[f % PAT.length])); H.wr(H.A.hurt, 1); H.wr(H.A.health, 3); await H.runTo(H.A.frame_top); }
  if (M.fingerprint().fp !== C.fingerprint().fp) sceneBad++;
  const wcx = M.rd16(M.A.wcx), wcy = M.rd(M.A.wcy), wfine = M.rd(M.A.wfine);
  const S = (wcy * 80 + wcx) % 2560;
  const r0 = wfine ? -1 : 0, r1 = wfine ? 31 : 30;
  let fb = 0;
  for (let r = r0; r < r1; r++) for (let c = 0; c < 80; c++) {
    const a = 0x3000 + (((S + r * 80 + c) % 2560 + 2560) % 2560) * 8;
    for (let l = 0; l < 8; l++) if (M.rd(a + l) !== C.rd(a + l)) { fb++; if (bad + fb <= 3) console.log(`f${f} row ${r} col ${c}`); break; }
  }
  for (let a = 0x2B00; a < 0x3000; a++) if (M.rd(a) !== C.rd(a)) { fb++; if (bad + fb <= 3) console.log(`f${f} bar ${a.toString(16)}`); break; }
  if (fb) badf++; bad += fb;
}
console.log(`L${lv}: window ${bad ? `DIFFERS: ${bad} cells on ${badf} frames` : "identical"}; scene ${sceneBad ? `differs on ${sceneBad} frames` : "identical"} over ${N} frames`);
process.exit(bad || sceneBad ? 1 : 0);
