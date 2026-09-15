// Run from boot and stop at the first BRK (or when the PC leaves the game for the
// MOS's error path); print the last 48 (bank, pc, op) with the nearest label.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = []; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab.push([parseInt(m[1], 16), m[2]]);
lab.sort((a, b) => a[0] - b[0]);
const near = (pc) => { let best = null; for (const [a, n] of lab) { if (a <= pc && !n.startsWith("__")) best = [a, n]; else if (a > pc) break; } return best ? `${best[1]}+${pc - best[0]}` : "?"; };
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const hist = []; let started = false, stop = false, n = 0;
const h = cpu.debugInstruction.add((pc, op) => {
  if (pc === 0x8100 && cpu.readmem(0xf4) === 7) started = true;
  if (!started) return false;
  if (hist.length < 120) hist.push([cpu.readmem(0xf4), pc, op]);
  n++;
  if (op === 0x00 || (pc >= 0xc000 && pc < 0xfe00 && !(pc >= 0xdc00 && pc < 0xdd00))) { stop = true; return true; }
  return false;
});
for (let i = 0; i < 4000 && !stop; i++) await s.runFor(20000);
console.log("started", started, "instrs", n, "stop", stop, "pc", cpu.pc.toString(16), "sp", cpu.s.toString(16));
for (const [b, pc, op] of hist) console.log(`  b${b} $${pc.toString(16).padStart(4,"0")} ${op.toString(16).padStart(2,"0")}  ${near(pc)}`);
process.exit(0);
