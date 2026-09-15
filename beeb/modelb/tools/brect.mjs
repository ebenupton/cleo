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
let log = [], last = null;
cpu.debugInstruction.add((pc) => {
  if (cpu.readmem(0xf4) === 5 && pc === lab.draw_maprect && log.length < 40) {
    const k = `buf${cpu.readmem(lab.curbuf)} rect tx=${cpu.readmem(lab.dt_tx)} ty=${cpu.readmem(lab.dt_ty)} nx=${cpu.readmem(lab.dt_nx)} ny=${cpu.readmem(lab.dt_ny)}`;
    if (k !== last) { log.push(k); last = k; } }
  return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(14_000_000);
console.log(log.join("\n"));
process.exit(0);
