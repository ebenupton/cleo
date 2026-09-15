// Play the game and report what happens: stars collected, score, damage, deaths.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "600"), seed0 = parseInt(process.argv[3] ?? "1");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(24_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
let stopAt = lab.frame_top;
cpu.debugInstruction.add((p) => p === stopAt && cpu.readmem(0xf4) === 7);
const rd = (n) => { const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); const v = cpu.readmem(lab[n]); cpu.writemem(0xfe30, was); return v; };
const rd16 = (n) => { const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
  const v = cpu.readmem(lab[n]) | (cpu.readmem(lab[n] + 1) << 8); cpu.writemem(0xfe30, was); return v; };
let rng = seed0 >>> 0 || 1;
const rnd = () => { rng ^= rng << 13; rng >>>= 0; rng ^= rng >> 17; rng ^= rng << 5; rng >>>= 0; return rng; };
let held = 2, hold = 0;
let prev = { stars: rd("stars"), score: rd16("score"), health: rd("health"), lives: rd("lives"), exiting: rd("exiting") };
const events = [];
for (let f = 0; f < frames; f++) {
  if (hold-- <= 0) { held = [2, 2, 6, 6, 4, 1, 5, 0, 18][rnd() % 9]; hold = 4 + (rnd() % 24); }
  cpu.writemem(lab.keys, held);
  for (let i = 0; i < 900; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === 7) break; }
  const now = { stars: rd("stars"), score: rd16("score"), health: rd("health"), lives: rd("lives"), exiting: rd("exiting") };
  for (const k of Object.keys(now)) if (now[k] !== prev[k]) events.push(`f${f} ${k}: ${prev[k]} -> ${now[k]}  (px=${rd16("px")} py=${rd16("py")})`);
  prev = now;
}
console.log(events.length ? events.join("\n") : "nothing happened");
console.log(`final: ${JSON.stringify(prev)} px=${rd16("px")} py=${rd16("py")}`);
process.exit(0);
