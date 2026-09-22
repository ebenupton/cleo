// Boot the full game under jsbeeb and bring it to a level's first frame_top, the way
// the Master harness does (harness.mjs open): the title menu is patched out and the
// level is chosen by rewriting level_loop's `ldx level`, so the game's own loader
// gathers the level from the disc.  Returns the session, the CPU, the labels and the
// helpers the tools share.
//   const B = await openB({ level: 0, model: "B-DFS1.2" | "B1770" })
import { findJsbeeb, loadLabels } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";

export async function openB({ level = 0, model = process.env.BMODEL ?? "B-DFS1.2", disc = "build/cleob.ssd", labels = "build/labels.txt", keys = false } = {}) {
  const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
  const A = loadLabels(labels);
  const s = new MachineSession(model);
  await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const cpu = s._machine.processor;
  const bank = (b, f) => { const was = cpu.readmem(0xf4); cpu.writemem(0xf4, b); cpu.writemem(0xfe30, b); const r = f(); cpu.writemem(0xf4, was); cpu.writemem(0xfe30, was); return r; };
  const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
  async function runTo(pc, b, budget = 3000) {
    const h = cpu.debugInstruction.add((p) => p === pc && cpu.readmem(0xf4) === b);
    try { for (let i = 0; i < budget; i++) { await s.runFor(20000); if (cpu.pc === pc && cpu.readmem(0xf4) === b) return; } }
    finally { h.remove(); }
    throw new Error(`B: runTo ${pc.toString(16)} timed out`);
  }
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  await runToB(A.title_loop, 7);
  bank(7, () => {
    for (let i = 0; i < 6; i++) cpu.writemem(A.title_loop + i, 0xea);   // jsr ensure_menu / jsr t_title_menu
    cpu.writemem(A.title_loop + 3, 0xa9); cpu.writemem(A.title_loop + 4, 0);   // "start game"
    let ok = false;
    for (let a = A.level_loop; a < A.level_loop + 24; a++)
      if (cpu.readmem(a) === 0xa6 && cpu.readmem(a + 1) === (A.level & 255)) { cpu.writemem(a, 0xa2); cpu.writemem(a + 1, level); ok = true; break; }
    if (!ok) throw new Error("B: ldx level not found in level_loop");
  });
  await runToB(A.level_init, 7, 60000);          // the disc load: seeks at DFS's step rate
  if (!keys) bank(7, () => cpu.writemem(A.scan_keys, 0x60));   // inputs from the tool only
  await runToB(A.frame_top, 7);
  return { s, cpu, A, bank, cyc, runTo };
  async function runToB(pc, b, budget) { return runTo(pc, b, budget); }
}
