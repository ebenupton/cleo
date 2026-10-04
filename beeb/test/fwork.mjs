// A frame's work on either machine, split: logic (frame_top to render_frame, the two
// logic steps) and render (render_frame to render_done), the interrupts (irq_handler
// to its RTI) and the flip wait's spin (the five bytes from wait_flip = render_frame:
// idle) taken out, over N frames of bwork2.mjs's seeded key script; also the scroll
// fill (validate's call, from its jsr to the return address, ISR excluded) and the
// interrupts' cycles a vsync over the whole run.  For budgets: a peg of p vsyncs
// leaves p x (40,000 - ISR a vsync) for the work.  Opened by harness.mjs open (Master)
// or bopen.mjs openB (Model B); each frame is a break at frame_top with 'keys' written
// there (LCG from the seed: nine key sets, no FIRE, held 4-43 frames); hurt/health are
// not pinned.
//   node test/fwork.mjs master|modelb <disc> <labels> [frames=300] [seed=1] [level=0] [dump.json]
// Output: "<machine> L<n>: logic <med> render <med> work <med> (median); flip wait
// <med>; scroll <med>; ISR <n> a vsync"; dump.json = {rows: [[logic, render, wait,
// scroll] a frame], isrPerVsync}.
import { open } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { writeFileSync } from "node:fs";
const [machine, disc, labels, fr = "300", sd = "1", lv = "0", dump] = process.argv.slice(2);
const frames = +fr, LEVEL = +lv;
let cpu, A, cyc, step, inB7;
if (machine === "master") {
  const H = await open({ disc, labels, level: LEVEL });
  cpu = H.cpu; A = H.A; cyc = () => H.cyc(); step = () => H.runTo(A.frame_top); inB7 = () => true;
  var wr = (a, v) => H.wr(a, v);
} else {
  const B = await openB({ level: LEVEL, disc, labels });
  cpu = B.cpu; A = B.A; cyc = B.cyc; const B7 = B.PB(7);
  step = () => B.runTo(A.frame_top, 7); inB7 = () => cpu.readmem((A.romsel_cpy ?? 0xf4)) === B7;
  var wr = (a, v) => B.bank(7, () => cpu.writemem(a, v));
}
let t0 = -1, t1 = -1, isr = 0, isrAt = -1, isrAll = 0, wait = 0, lastPc = -1, lastC = 0;
const WF0 = A.wait_flip, WF1 = A.wait_flip + 4;     // the flip wait's spin (lda / bne, 4 bytes): idle, not work
let vret = -1, vAt = 0, vIsr0 = 0, scroll = 0;        // the scroll fill: validate's call to its return, ISR excluded
const rows = [];
const meter = cpu.debugInstruction.add((pc, op) => {
  const now = cyc();
  if (isrAt < 0 && lastPc >= WF0 && lastPc <= WF1 && t1 >= 0) wait += now - lastC;
  lastPc = pc; lastC = now;
  if (pc === A.frame_top && inB7()) { t0 = cyc(); isr = 0; t1 = -1; wait = 0; }
  else if (pc === A.render_frame && t0 >= 0 && t1 < 0 && inB7()) { t1 = cyc(); rows.push([0, 0]); rows[rows.length - 1][0] = t1 - t0 - isr; isr = 0; }
  else if (pc === A.render_done && t1 >= 0 && inB7()) { rows[rows.length - 1][1] = cyc() - t1 - isr - wait; rows[rows.length - 1][2] = wait; rows[rows.length - 1][3] = scroll; wait = 0; scroll = 0; t0 = t1 = -1; }
  else if (pc === A.validate && vret < 0 && t1 >= 0) { const sp = cpu.s; vret = (cpu.readmem(0x101 + sp) | cpu.readmem(0x102 + sp) << 8) + 1; vAt = now; vIsr0 = isr; }
  else if (pc === vret && isrAt < 0) { scroll += now - vAt - (isr - vIsr0); vret = -1; }
  if (pc === A.irq_handler) isrAt = cyc();
  else if (isrAt >= 0 && op === 0x40) { const d = cyc() - isrAt; isr += d; isrAll += d; isrAt = -1; }
  return false;
});
const vs0 = cpu.readmem(A.vsyncs), c0 = cyc();
let vsn = 0, last = vs0;
let rng = +sd >>> 0; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
let keys = 0, hold = 0;
for (let f = 0; f < frames; f++) {
  if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8][rnd() % 9]; hold = 4 + rnd() % 40; }
  wr(A.keys, keys); await step();
}
meter.remove();
const isrPerVsync = isrAll / ((cyc() - c0) / 40000);
if (dump) writeFileSync(dump, JSON.stringify({ rows, isrPerVsync }));
const med = (a) => { a = [...a].sort((x, y) => x - y); return a[a.length >> 1]; };
const w = rows.filter((r) => r[1]).map((r) => r[0] + r[1]);
console.log(`${machine} L${LEVEL}: logic ${med(rows.map((r) => r[0]))} render ${med(rows.map((r) => r[1]))} work ${med(w)} (median); flip wait ${med(rows.map((r) => r[2] || 0))}; scroll ${med(rows.map((r) => r[3] || 0))}; ISR ${Math.round(isrPerVsync)} a vsync`);
process.exit(0);
