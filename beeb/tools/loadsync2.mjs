// The frame period across a real level load: boot through the real title (no patches),
// wait for the menu, press RETURN to start the game, and time every CRTC frame until
// play has run a while.  Reports each frame whose period is not a standard 312 lines
// (39936 cycles, +-64 for the chain's re-phase) and any flyback forced for want of a
// vsync.  Unlike tools/loadsync.mjs the picture is in sync when the load begins.
//   node tools/loadsync2.mjs master|modelb <disc> <labels>
import { findJsbeeb, loadLabels } from "./harness.mjs";
import { pathToFileURL } from "node:url"; import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const [kind, disc, labels] = process.argv.slice(2);
const s = new MachineSession(kind === "master" ? "Master" : "B-DFS1.2"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
const cpu = s._machine.processor, A = loadLabels(labels), v = s._video;
const P = kind === "master" ? null : cpu.model.swram.map((r, i) => (r ? i : -1)).filter((i) => i >= 0).slice(0, 4);
const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
const HV = []; let forced = 0; { const opc = v.paintAndClear.bind(v); v.paintAndClear = function () { if (v.bitmapY >= 768) forced++; HV.push([cyc(), v.bitmapY >= 768]); return opc(); }; }
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
async function to(pc, bank, budget = 6000) {
  const at = () => cpu.pc === pc && (bank === undefined || !P || cpu.readmem(0xf4) === P[bank - 4]);
  const h = cpu.debugInstruction.add(() => at());
  try { for (let i = 0; i < budget; i++) { await s.runFor(20000); if (at()) return; } } finally { h.remove(); }
  throw new Error("not reached: " + pc.toString(16));
}
for (let k = 0; k < 20; k++) { await to(A.menu_keys, 5); await s.runFor(1); }
const t0 = cyc(); const n0 = HV.length; forced = 0;
s.keyDown(13); await s.runFor(200000); s.keyUp(13);
await to(A.frame_top, 7, 60000);
for (let k = 0; k < 60; k++) { await to(A.frame_top, 7); await s.runFor(1); }
const odd = [];
for (let i = n0 + 1; i < HV.length; i++) { const d = HV[i][0] - HV[i - 1][0]; if (Math.abs(d - 39936) > 64) odd.push(`${d}${HV[i][1] ? " (forced)" : ""} at +${HV[i][0] - t0}`); }
console.log(`${kind}: ${HV.length - n0} frames from RETURN into play, ${forced} forced flybacks, ${odd.length} irregular: ${odd.slice(0, 8).join(", ")}`);
process.exit(0);
