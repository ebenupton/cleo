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
let hits = { drawsprite: 0, ds_rowloop: 0, ds_colloop: 0, sprFN: 0, sprnext: 0, ds_done: 0, ds_rowdone: 0 };
let log = [];
cpu.debugInstruction.add((pc) => { if (cpu.readmem(0xf4) !== 4) return false;
  for (const k of Object.keys(hits)) if (lab[k] !== undefined && pc === lab[k]) hits[k]++;
  if (lab.drawsprite === pc && log.length < 6)
    log.push(`id=${cpu.a} spx=${r16(lab.spx)} spy=${r16(lab.spy)}`);
  return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(14_000_000);
console.log(hits); console.log(log.join(" | "));
console.log("NSPR", cpu.readmem(lab.NSPR), "RECCNT", cpu.readmem(lab.RECCNT), cpu.readmem(lab.RECCNT + 1),
  "wcx", r16(lab.wcx), "wcy", cpu.readmem(lab.wcy));
console.log("SPRTAB[8]:", [...Array(8)].map((_, i) => cpu.readmem(lab.SPRTAB + 64 + i).toString(16)).join(" "));
process.exit(0);
