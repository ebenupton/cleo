import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync } from "node:fs";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(parseInt(process.argv[2] ?? "6000000"));
const cpu = s._machine.processor;
const b = Buffer.alloc(0x8000);
for (let a = 0; a < 0x8000; a++) b[a] = cpu.readmem(a);
writeFileSync(process.argv[3] ?? "build/ram.bin", b);
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
console.log(JSON.stringify({ wcy: cpu.readmem(lab.wcy), wcx: r16(lab.wcx), wfine: cpu.readmem(lab.wfine),
  curbuf: cpu.readmem(lab.curbuf), ringS: r16(lab.ringS), barq: cpu.readmem(lab.barq), frame: cpu.readmem(lab.frame) }));
process.exit(0);
