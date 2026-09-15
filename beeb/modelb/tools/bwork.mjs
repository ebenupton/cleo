// Per-frame work (frame_top to wait_flip) and the vsyncs the flip then waits for.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "200"), keys = parseInt(process.argv[3] ?? "6");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
const work = [], period = [];
let t0 = -1, f0 = -1;
cpu.debugInstruction.add((p) => {
  const bank = cpu.readmem(0xf4);
  if (p === lab.frame_top && bank === 7) { const c = cyc(); if (f0 >= 0) period.push(c - f0); f0 = c; t0 = c; }
  else if (p === lab.wait_flip && bank === 7 && t0 >= 0) { work.push(cyc() - t0); t0 = -1; }
  return false; });
for (let f = 0; f < frames; f++) { cpu.writemem(lab.keys, keys); await s.runFor(40000); }
const stat = (a) => { a = a.slice(2).sort((x, y) => x - y); return { n: a.length, min: a[0], p50: a[a.length >> 1], p90: a[Math.floor(a.length * 0.9)], max: a[a.length - 1] }; };
console.log("work  ", JSON.stringify(stat(work)));
console.log("period", JSON.stringify(stat(period)));
const buckets = {}; for (const p of period.slice(2)) { const k = Math.round(p / 40000); buckets[k] = (buckets[k] || 0) + 1; }
console.log("vsyncs a frame:", JSON.stringify(buckets));
process.exit(0);
