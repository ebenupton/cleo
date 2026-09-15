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
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const snap = () => [...Array(0x1c0)].map((_, i) => cpu.readmem(0x140 + i));
let good = snap(), lastFrame = -1;
for (let f = 0; f < 90; f++) {
  cpu.writemem(lab.keys, 2); await s.runFor(40000);
  const now = snap();
  const diff = [];
  for (let i = 0; i < now.length; i++) { const a = 0x140 + i; if (a === 0x222 || a === 0x223) continue; if (now[i] !== good[i]) diff.push(a); }
  const fr = cpu.readmem(lab.frame);
  if (diff.length) { console.log(`f${f} frame=${fr} wcx=${cpu.readmem(lab.wcx)}: low RAM changed at ${diff.slice(0, 12).map(a => "$" + a.toString(16)).join(" ")}${diff.length > 12 ? " ..." + diff.length : ""}`);
    good = now; }
  if (fr === lastFrame && f > 3) { console.log(`stalled at f${f}, frame=${fr}, pc=$${cpu.pc.toString(16)} bank=${cpu.readmem(0xf4)} sp=$${cpu.s.toString(16)} wcx=${cpu.readmem(lab.wcx)} wcy=${cpu.readmem(lab.wcy)} curbuf=${cpu.readmem(lab.curbuf)}`);
    const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 5);
    console.log("  bank5 $8100:", [...Array(12)].map((_, i) => cpu.readmem(0x8100 + i).toString(16)).join(" "));
    cpu.writemem(0xfe30, 7);
    console.log("  bank7 $8100:", [...Array(12)].map((_, i) => cpu.readmem(0x8100 + i).toString(16)).join(" "));
    cpu.writemem(0xfe30, was); break; }
  lastFrame = fr;
}
console.log("IRQ1V", (cpu.readmem(0x204) | (cpu.readmem(0x205) << 8)).toString(16), "expected", lab.irq_handler.toString(16));
process.exit(0);
