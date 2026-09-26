// Model B title and menus, build against build: boot both discs through the real title
// (no patches) and compare the display RAM every 2M cycles.  Run from beeb/modelb.
//   node tools/btitlediff.mjs <discA> <discB>
import { findJsbeeb } from "../../tools/harness.mjs";
import { pathToFileURL } from "node:url"; import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
async function boot(disc) { const s = new MachineSession("B-DFS1.2"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); return s; }
const [dA, dB] = process.argv.slice(2);
const A = await boot(dA), B = await boot(dB), ca = A._machine.processor, cb = B._machine.processor;
let bad = 0;
for (let step = 0; step < 30; step++) {
  await A.runFor(2_000_000); await B.runFor(2_000_000);
  let n = 0; for (let a = 0x0300; a < 0x8000; a++) if (ca.readmem(a) !== cb.readmem(a)) n++;
  if (n) { bad++; if (bad <= 3) console.log(`  after ${(step + 1) * 2}M cycles: ${n} display bytes differ`); }
}
console.log(bad ? `B title: DIFFERS on ${bad}/30 samples` : "B title: identical on 30 samples");
process.exit(bad ? 1 : 0);
