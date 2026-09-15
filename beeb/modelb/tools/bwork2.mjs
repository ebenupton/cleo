// Frame cost: cycles from one frame_top (bank 7) to the next, less the wait for the
// vsync peg, over N frames of a key script; prints the distribution and the far-call
// count per frame.
import { findJsbeeb, loadLabels } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "300"), seed0 = parseInt(process.argv[3] ?? "1");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = loadLabels("build/labels.txt");
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const bank = (b, f) => { const was = cpu.readmem(0xf4); cpu.writemem(0xf4, b); cpu.writemem(0xfe30, b); const r = f(); cpu.writemem(0xf4, was); cpu.writemem(0xfe30, was); return r; };
const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
async function runTo(pc, b) { const h = cpu.debugInstruction.add((p) => p === pc && cpu.readmem(0xf4) === b);
  try { for (let i = 0; i < 3000; i++) { await s.runFor(20000); if (cpu.pc === pc && cpu.readmem(0xf4) === b) return; } } finally { h.remove(); } throw new Error("timeout"); }
await runTo(A.level_init, 7); bank(7, () => cpu.writemem(A.scan_keys, 0x60));
await runTo(A.frame_top, 7);
// work = frame_top .. the flip request (render_frame's end): everything but the peg wait
let t0 = -1, work = [], far = 0, fars = [], isr = 0, isrs = [], isrAt = -1;
const meter = cpu.debugInstruction.add((pc, op) => {
  if (pc === A.frame_top && cpu.readmem(0xf4) === 7) { if (t0 >= 0) {} t0 = cyc(); far = 0; isr = 0; }
  else if (pc === A.render_done && cpu.readmem(0xf4) === 7 && t0 >= 0) { work.push(cyc() - t0 - isr); fars.push(far); isrs.push(isr); t0 = -1; }
  else if (pc === A.farcall) far++;
  else if (pc === A.irq_handler) isrAt = cyc();
  else if (isrAt >= 0 && op === 0x40) { isr += cyc() - isrAt; isrAt = -1; }
  return false;
});
let rng = seed0 >>> 0; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
let keys = 0, hold = 0;
for (let f = 0; f < frames; f++) {
  if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8][rnd() % 9]; hold = 4 + rnd() % 40; }
  cpu.writemem(A.keys, keys); await runTo(A.frame_top, 7);
}
meter.remove();
const so = [...work].sort((a, b) => a - b), q = (p) => so[Math.floor(p * (so.length - 1))];
console.log(`${so.length} frames: work median ${q(0.5)} p90 ${q(0.9)} max ${so[so.length-1]} min ${so[0]} cycles (ISR excluded); far calls/frame median ${[...fars].sort((a,b)=>a-b)[fars.length>>1]} max ${Math.max(...fars)}; ISR/frame median ${[...isrs].sort((a,b)=>a-b)[isrs.length>>1]}`);
console.log(`vsyncs a frame at 40000 cycles each: median ${(q(0.5)/40000).toFixed(2)}, p90 ${(q(0.9)/40000).toFixed(2)}, max ${(so[so.length-1]/40000).toFixed(2)}`);
process.exit(0);
