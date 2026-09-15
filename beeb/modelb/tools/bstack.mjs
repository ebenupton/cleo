// The stack is 64 bytes: watch S over a long run and report the deepest it got.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "300");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(24_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
let low = 0xff, lowPc = 0; const trace = [];
cpu.debugInstruction.add((p) => { if (cpu.s < low) { low = cpu.s; lowPc = p; trace.push(`S=$${cpu.s.toString(16)} pc=$${p.toString(16)} bank=${cpu.readmem(0xf4)}`); } return false; });
const seq = [2, 6, 1, 5, 4, 2, 6, 0, 3];
for (let f = 0; f < frames; f++) { await s.runFor(40000); }
console.log(`deepest S = $${low.toString(16)}: ${0x3f - low} of the 64 bytes at $0100-$013F, at pc=$${lowPc.toString(16)}`);
process.exit(0);
