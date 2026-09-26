// Title and menus, build against build, FRAME-SYNCHRONISED: both machines boot through
// the real title and are compared at the same arrival at menu_keys -- the menus' once-a-
// frame wait, where the page is drawn and settled -- so a build that draws faster is not
// a difference (titlediff.mjs samples at fixed cycle counts, which it would be).  DOWN
// and RETURN are pressed at fixed arrivals to walk into a second page.
//   node tools/menusync.mjs master <discA> <labelsA> <discB> <labelsB>
//   node tools/menusync.mjs modelb <discA> <labelsA> <discB> <labelsB>
import { findJsbeeb, loadLabels } from "./harness.mjs";
import { pathToFileURL } from "node:url"; import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const [kind, dA, lA, dB, lB] = process.argv.slice(2);
const N = 40;
async function boot(disc, labels) {
  const s = new MachineSession(kind === "master" ? "Master" : "B-DFS1.2"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const cpu = s._machine.processor, A = loadLabels(labels);
  const P = kind === "master" ? null : cpu.model.swram.map((r, i) => (r ? i : -1)).filter((i) => i >= 0).slice(0, 4);
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  const at = () => cpu.pc === A.menu_keys && (!P || cpu.readmem(0xf4) === P[1]);
  async function next() {
    const h = cpu.debugInstruction.add(() => at());
    try { for (let i = 0; i < 4000; i++) { await s.runFor(20000); if (at()) return; } } finally { h.remove(); }
    throw new Error("menu_keys not reached");
  }
  return { s, cpu, next };
}
const X = await boot(dA, lA), Y = await boot(dB, lB);
let bad = 0;
for (let k = 0; k < N; k++) {
  for (const M of [X, Y]) {
    if (k === 12) M.s.keyDown(40); if (k === 15) M.s.keyUp(40);
    if (k === 24) M.s.keyDown(13); if (k === 27) M.s.keyUp(13);
    await M.next(); await M.s.runFor(1);            // step past the break
  }
  if (k < 2) continue;               // the first page may still be settling: a changed file
                                     // size moves the disc load, and with it that frame's timing
  let n = 0;
  if (kind === "master") {           // the bar ($2B00) and both screens, main and shadow --
    for (const shadow of [0, 4]) {   // not the code, which lives in main RAM below them
      const was = [X, Y].map((M) => M.cpu.readmem(0xfe34));
      [X, Y].forEach((M, i) => M.cpu.writemem(0xfe34, (was[i] & ~4) | shadow));
      for (let a = shadow ? 0x3000 : 0x2b00; a < 0x8000; a++) if (X.cpu.readmem(a) !== Y.cpu.readmem(a)) n++;
      [X, Y].forEach((M, i) => M.cpu.writemem(0xfe34, was[i]));
    }
  } else for (let a = 0x0300; a < 0x8000; a++) if (X.cpu.readmem(a) !== Y.cpu.readmem(a)) n++;   // the B: all display
  if (n) { bad++; if (bad <= 3) console.log(`  menu frame ${k}: ${n} display bytes differ`); }
}
console.log(bad ? `${kind} menus: DIFFER on ${bad}/${N} frames` : `${kind} menus: identical on ${N} frames`);
process.exit(bad ? 1 : 0);
