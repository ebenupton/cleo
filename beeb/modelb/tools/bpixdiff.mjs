// Model B, build against build: the same level and the same key script on two discs,
// and the whole display RAM ($0300-$7FFF: the bar, both rings, the composed rows)
// compared at every frame_top.  bdiff checks the logic against the Master; this checks
// what the B's own renderer draws.  Run from beeb/modelb.
//   node tools/bpixdiff.mjs <baseDisc> <baseLabels> <disc> <labels> [frames] [seed] [level]
import { openB } from "./bopen.mjs";
const [d0, l0, d1, l1] = process.argv.slice(2, 6);
const frames = parseInt(process.argv[6] ?? "200"), seed0 = parseInt(process.argv[7] ?? "1"), level = parseInt(process.argv[8] ?? "0");
const X = await openB({ level, disc: d0, labels: l0 }), Y = await openB({ level, disc: d1, labels: l1 });
let rng = seed0 >>> 0; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
let keys = 0, hold = 0, bad = 0;
for (let f = 0; f < frames; f++) {
  if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 16, 2|16, 1|16, 8][rnd() % 10]; hold = 4 + rnd() % 40; }
  for (const M of [X, Y]) { M.bank(7, () => { M.cpu.writemem(M.A.keys, keys); M.cpu.writemem(M.A.hurt, 1); M.cpu.writemem(M.A.health, 3); }); await M.runTo(M.A.frame_top, 7); }
  if (f < 2) continue;              // the first two frames are drawn with the palette black and
                                    // can still hold the load's staging bytes in ring rows the
                                    // window has not reached: those are overwritten before use
  let n = 0, first = -1;
  for (let a = 0x0300; a < 0x8000; a++) if (X.cpu.readmem(a) !== Y.cpu.readmem(a)) { n++; if (first < 0) first = a; }
  if (n) { console.log(`frame ${f}: ${n} display bytes differ, first at $${first.toString(16)}`); if (++bad >= 3) break; }
}
console.log(bad ? `B DISPLAY DIFFERS (level ${level})` : `B display identical over ${frames} frames (level ${level})`);
process.exit(bad ? 1 : 0);
