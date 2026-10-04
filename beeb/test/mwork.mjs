// Frame cost on the Master, frame-matched (bwork2.mjs's Model B measure on the
// Master): the cycles from frame_top to render_done, less the interrupts (irq_handler
// to its RTI), over N frames of the same seeded key script (nine key sets, no FIRE,
// held 4-43 frames; hurt/health not pinned), so two builds whose logic agrees see the
// same frames even when their sprite lists differ (the bench's scene fingerprints
// would not match).  Opened by harness.mjs open; each frame is a break at frame_top
// with 'keys' written there.  The flip wait at the top of render_frame is inside the
// window.
//   MDISC=disc MLABELS=labels MDUMP=file node test/mwork.mjs [frames=300] [seed=1] [level=0]
// (defaults build/cleo.ssd, build/master/labels.txt; MDUMP writes each frame's work
// as a JSON array, for a frame-by-frame comparison)
// Output: "<n> frames: work median <n> p90 <n> max <n> cycles".
import { open } from "./harness.mjs";
import { writeFileSync } from "node:fs";
const frames = parseInt(process.argv[2] ?? "300"), seed0 = parseInt(process.argv[3] ?? "1"), LEVEL = parseInt(process.argv[4] ?? "0");
const H = await open({ disc: process.env.MDISC ?? "build/cleo.ssd", labels: process.env.MLABELS ?? "build/master/labels.txt", level: LEVEL });
const cpu = H.cpu, A = H.A, cyc = () => H.cyc();
let t0 = -1, work = [], isr = 0, isrAt = -1;
const irq = A.irq_handler ?? A.mirq;   // (mirq: the handler's name in an older build)
const meter = cpu.debugInstruction.add((pc, op) => {
  if (pc === A.frame_top) { t0 = cyc(); isr = 0; }
  else if (pc === A.render_done && t0 >= 0) { work.push(cyc() - t0 - isr); t0 = -1; }
  else if (pc === irq) isrAt = cyc();
  else if (isrAt >= 0 && op === 0x40) { isr += cyc() - isrAt; isrAt = -1; }
  return false;
});
let rng = seed0 >>> 0; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
let keys = 0, hold = 0;
for (let f = 0; f < frames; f++) {
  if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8][rnd() % 9]; hold = 4 + rnd() % 40; }
  H.wr(A.keys, keys); await H.runTo(A.frame_top);
}
meter.remove();
if (process.env.MDUMP) writeFileSync(process.env.MDUMP, JSON.stringify(work));
const so = [...work].sort((a, b) => a - b), q = (p) => so[Math.floor(p * (so.length - 1))];
console.log(`${so.length} frames: work median ${q(0.5)} p90 ${q(0.9)} max ${so[so.length - 1]} cycles`);
process.exit(0);
