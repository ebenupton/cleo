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
const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
let tiles = 0, tcyc = 0, tstart = -1, frames = 0, sprites = 0, scyc = 0, sstart = -1, strips = 0;
cpu.debugInstruction.add((pc) => {
  const b = cpu.readmem(0xf4);
  if (b === 5 && pc === lab.draw_tile) { const c = cyc(); if (tstart >= 0 && c - tstart < 4000) { tcyc += c - tstart; tiles++; } tstart = c; }
  if (b === 5 && pc === lab.map_strip) strips++;
  if (tstart >= 0 && b === 5 && pc === lab.draw_maprect) { tstart = -1; }
  if (b === 4 && pc === lab.drawsprite) { const c = cyc(); if (sstart >= 0 && c - sstart < 30000) { scyc += c - sstart; } sprites++; sstart = c; }
  if (b === 7 && pc === lab.frame_top) frames++;
  return false; });
for (let f = 0; f < 60; f++) { cpu.writemem(lab.keys, 6); await s.runFor(40000); }
console.log(`frames ${frames}: ${tiles} tile gaps, mean ${Math.round(tcyc / Math.max(1, tiles))} cycles each; ${sprites} sprites, mean gap ${Math.round(scyc / Math.max(1, sprites))}; strips ${strips}`);
process.exit(0);
