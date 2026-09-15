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
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
let log = [], n = 0, rows = [];
cpu.debugInstruction.add((pc) => {
  if (cpu.readmem(0xf4) !== 5) return false;
  if (pc === lab.draw_tile) { n++;
    if (log.length < 26) log.push(`id=${cpu.a} tp=? dst0=$${r16(lab.dst0).toString(16)} dst1=$${r16(lab.dst1).toString(16)} i=${cpu.readmem(lab.dt_i)}`); }
  if (pc === lab.draw_maprect && rows.length < 4) rows.push(`maprect tx=${cpu.readmem(lab.dt_tx)} ty=${cpu.readmem(lab.dt_ty)} nx=${cpu.readmem(lab.dt_nx)} ny=${cpu.readmem(lab.dt_ny)}`);
  return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(14_000_000);
console.log("draw_tile calls in bank 5:", n);
console.log(rows.join("\n"));
console.log(log.join("\n"));
process.exit(0);
