import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
let out = [];
cpu.debugInstruction.add((pc) => {
  if (cpu.readmem(0xf4) === 5 && pc === lab.draw_tile && out.length < 460)
    out.push([cpu.a, r16(lab.dst0), r16(lab.dst1), cpu.readmem(lab.dt_ty), cpu.readmem(lab.dt_i)]);
  return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(14_000_000);
writeFileSync("build/tilelog.json", JSON.stringify(out));
console.log("logged", out.length);
process.exit(0);
