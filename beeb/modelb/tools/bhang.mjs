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
for (let f = 0; f < 90; f++) { cpu.writemem(lab.keys, 2); await s.runFor(40000);
  if (f % 20 === 0 || f > 60) console.log(`f${f} pc=$${cpu.pc.toString(16)} bank=${cpu.readmem(0xf4)} frame=${cpu.readmem(lab.frame)} wcx=${cpu.readmem(lab.wcx)} flipreq=${cpu.readmem(lab.flipreq)} vsyncs=${cpu.readmem(lab.vsyncs)} s=$${cpu.s.toString(16)}`); }
process.exit(0);
