// Read the ported logic's state after N frames.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "30"), keys = parseInt(process.argv[3] ?? "0");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(24_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
let stopAt = lab.pre_spr;
cpu.debugInstruction.add((p) => p === stopAt && cpu.readmem(0xf4) === 7);
for (let f = 0; f < frames; f++) { cpu.writemem(lab.keys, keys);
  for (let i = 0; i < 600; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === 7) break; } }
const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
const r8 = (n) => cpu.readmem(lab[n]), r16 = (n) => cpu.readmem(lab[n]) | (cpu.readmem(lab[n] + 1) << 8);
const out = {};
for (const n of ["px","py","vx","vy","wx","wy","frame","nobj","stars","health","lives","score","level","gridsh","control","hurt","anim","facing","firing","bactive","exiting","pausing","maplw"])
  if (lab[n] !== undefined) out[n] = ["px","py","vx","vy","wx","wy","frame","score"].includes(n) ? r16(n) : r8(n);
out.BINOK = r8("BINOK"); out.NSTARL = r8("NSTARL"); out.NOTHL = r8("NOTHL");
out.mapw = r16("mapw"); out.maph = r16("maph");
cpu.writemem(0xfe30, 4);
out.NSPR = cpu.readmem(lab.NSPR);
cpu.writemem(0xfe30, 7);
const OBJN = 32, OBJST = lab.LV_GRID - 16 * OBJN;
const O = (n, i) => cpu.readmem(OBJST + n * OBJN + i);
const objs = [];
for (let i = 0; i < out.nobj; i++)
  objs.push({ i, t: O(1, i), x: O(2, i) | (O(3, i) << 8), y: O(4, i) | (O(5, i) << 8), st: O(0, i) });
const grid = []; for (let g = 0; g < 16; g++) grid.push(cpu.readmem(lab.LV_GRID + g));
cpu.writemem(0xfe30, was);
console.log(JSON.stringify(out));
console.log("objects:", JSON.stringify(objs));
console.log("grid heads:", grid.join(" "));
process.exit(0);
