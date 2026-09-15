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
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(24_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(lab.queue_sprites, 0x60); cpu.writemem(0xfe30, was); }
// per buffer: when a tile column/row was last drawn
const drawn = [new Map(), new Map()];
let win = [];
cpu.debugInstruction.add((pc) => {
  const b = cpu.readmem(0xf4);
  if (b === 5 && pc === lab.draw_maprect) {
    const buf = cpu.readmem(lab.curbuf), tx = cpu.readmem(lab.dt_tx), ty = cpu.readmem(lab.dt_ty), nx = cpu.readmem(lab.dt_nx), ny = cpu.readmem(lab.dt_ny);
    // this fires once per row of the rect; record the row it is about to draw
    for (let i = 0; i < nx; i++) drawn[buf].set(`${tx + i},${ty}`, cpu.readmem(lab.frame));
  }
  if (b === 7 && pc === lab.scroll_validate) win.push([cpu.readmem(lab.tx0), cpu.readmem(lab.ty0), cpu.readmem(lab.curbuf)]);
  return false; });
for (let f = 0; f < 200; f++) { cpu.writemem(lab.keys, 6); await s.runFor(40000); }
const tx0 = cpu.readmem(lab.tx0), ty0 = cpu.readmem(lab.ty0);
console.log(`window now tx ${tx0} ty ${ty0}; last few windows:`, win.slice(-6).map(w => w.join("/")).join(" "));
for (const buf of [0, 1]) {
  const missing = [];
  for (let ty = ty0; ty < ty0 + 12; ty++) for (let tx = tx0; tx < tx0 + 21; tx++) if (!drawn[buf].has(`${tx},${ty}`)) missing.push(`${tx},${ty}`);
  console.log(`buffer ${buf}: ${missing.length} window tiles never drawn during play; ${missing.slice(0, 10).join(" ")}`);
}
process.exit(0);
