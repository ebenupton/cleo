import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
let counts = {};
cpu.debugInstruction.add((pc) => { const k = pc === lab.init ? "init" : pc === lab.draw_window ? "draw_window" : pc === lab.frame_top ? "frame_top" : pc === lab.take_over ? "take_over" : pc === lab.mirror_copy ? "mirror_copy" : null; if (k) counts[k] = (counts[k] || 0) + 1; return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
for (let i = 0; i < 8; i++) { await s.runFor(1_000_000);
  console.log(`t=${i + 1}M pc=$${cpu.pc.toString(16)} romsel=${cpu.readmem(0xf4)} wcy=${cpu.readmem(lab.wcy)} curbuf=${cpu.readmem(lab.curbuf)} dt_ty=${cpu.readmem(lab.dt_ty)} dt_ny=${cpu.readmem(lab.dt_ny)} frame=${cpu.readmem(lab.frame)}`); }
console.log("counts:", counts);
process.exit(0);
