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
// phase boundaries, in the order the loop runs them
const marks = [["player", lab.player_step], ["camera", lab.camera], ["calc", lab.calc_ring], ["scroll", lab.scroll_validate],
  ["erase", lab.pre_erase], ["queue", lab.queue_sprites], ["sprites", lab.pre_spr], ["partial", lab.pre_part],
  ["mirror", lab.pre_mirror], ["sections", lab.build_sections], ["wait", lab.wait_flip], ["frame", lab.frame_top]];
const acc = {}, seen = {};
let lastName = null, lastCyc = 0, frames = 0;
const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
cpu.debugInstruction.add((pc) => {
  if (cpu.readmem(0xf4) !== 7) return false;
  for (const [n, a] of marks) if (pc === a) {
    const c = cyc();
    if (lastName) acc[lastName] = (acc[lastName] || 0) + (c - lastCyc);
    if (n === "frame") frames++;
    lastName = n; lastCyc = c; break; }
  return false; });
for (let f = 0; f < 60; f++) { cpu.writemem(lab.keys, 6); await s.runFor(40000); }
const tot = Object.values(acc).reduce((a, b) => a + b, 0);
console.log(`frames ${frames}, mean cycles each ${Math.round(tot / frames)}`);
for (const [k, v] of Object.entries(acc).sort((a, b) => b[1] - a[1]))
  console.log(`  ${k.padEnd(10)} ${String(Math.round(v / frames)).padStart(6)} cycles`);
process.exit(0);
