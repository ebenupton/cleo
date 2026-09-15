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
let trace = [], armed = false, done = false;
cpu.debugInstruction.add((pc) => {
  if (done) return false;
  if (cpu.readmem(0xf4) === 4 && pc === lab.drawsprite && cpu.a === 8) armed = true;
  if (armed) { trace.push(pc); if (trace.length > 120) { done = true; } }
  return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(14_000_000);
// compress
let out = [], last = -9, run = 0;
for (const p of trace) { if (p === last + 1 || p === last + 2 || p === last + 3) { run++; last = p; continue; } if (run) out.push(`..${run}`); out.push("$" + p.toString(16)); last = p; run = 0; }
if (run) out.push(`..${run}`);
console.log(out.join(" "));
// paged-in reads of the directory
cpu.writemem(0xfe30, 4);
console.log("SPRTAB[8]:", [...Array(8)].map((_, i) => cpu.readmem(lab.SPRTAB + 64 + i).toString(16)).join(" "));
console.log("sp_w", cpu.readmem(lab.sp_w), "sp_lines", cpu.readmem(lab.sp_lines), "sp_c0", cpu.readmem(lab.sp_c0), "sp_c1", cpu.readmem(lab.sp_c1), "sp_lb0", r16(lab.sp_lb0), "sp_r0", cpu.readmem(lab.sp_r0), "sp_r1", cpu.readmem(lab.sp_r1));
process.exit(0);
