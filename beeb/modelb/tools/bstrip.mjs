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
let log = [], inStrip = false;
cpu.debugInstruction.add((pc) => {
  const bank = cpu.readmem(0xf4);
  if (bank === 6 && pc === lab.map_strip && log.length < 8) {
    log.push({ ty: cpu.readmem(lab.dt_ty), cnt: cpu.readmem(lab.cnt), enter: true });
  }
  if (bank === 5 && pc === lab.draw_maprect && log.length && log.length < 9 && !log[log.length - 1].after) {
    log[log.length - 1].after = [...Array(20)].map((_, i) => cpu.readmem(lab.MAPBUF + i)).join(",");
    log[log.length - 1].cntAfter = cpu.readmem(lab.cnt);
  }
  return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(14_000_000);
for (const l of log) console.log(JSON.stringify(l));
process.exit(0);
