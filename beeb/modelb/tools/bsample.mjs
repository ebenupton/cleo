// Sampling profiler: every instruction is too slow, so sample the PC and the paged
// bank every N cycles and bucket by the nearest label in the segment that bank holds.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const keys = parseInt(process.argv[2] ?? "6"), frames = parseInt(process.argv[3] ?? "60");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = []; const labByName = {};
for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm))
  { lab.push([parseInt(m[1], 16), m[2]]); labByName[m[2]] = parseInt(m[1], 16); }
// which bank owns which segment
const segBank = { TAB4: 4, SPRCODE: 4, SPRDATA: 4, SPRBSS: 4, TAB5: 5, TILCODE: 5, TILDATA: 5, TILBSS: 5,
  TAB6: 6, MAPCODE: 6, MAPDATA: 6, MAPBSS: 6, TAB7: 7, LGCCODE: 7, LGCDATA: 7, LGCBSS: 7 };
const segs = [];
for (const m of readFileSync("build/map.txt", "utf8").matchAll(/^(\w+) +([0-9A-F]{6})  ([0-9A-F]{6})/gm)) {
  const [_, name, st, en] = m; if (segBank[name]) segs.push({ name, bank: segBank[name], st: parseInt(st, 16), en: parseInt(en, 16) });
}
// a label's bank is the bank of the file it was written in: labels.txt has no
// segment, and every bank has code at $8100.
const fileBank = { "bank4.s": 4, "bank5.s": 5, "bank6.s": 6, "bank7.s": 7, "logicb.s": 7, "low.s": 0 };
const ownBank = {};
for (const [f, b] of Object.entries(fileBank))
  for (const m of readFileSync("src/" + f, "utf8").matchAll(/^(\w+):/gm)) ownBank[m[1]] = b;
const byBank = {};
for (const [a, n] of lab) { const b = ownBank[n]; if (b === undefined) continue; (byBank[b] = byBank[b] || []).push([a, n]); }
for (const b of Object.keys(byBank)) byBank[b].sort((x, y) => x[0] - y[0]);
const labOf = (pc, bank) => {
  const list = byBank[pc < 0x8000 ? 0 : bank] || [];
  let best = null; for (const [a, n] of list) if (a <= pc && (!best || a > best[0])) best = [a, n];
  return (pc < 0x8000 ? "low:" : "b" + bank + ":") + (best ? best[1] : pc.toString(16));
};
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const hist = {};
let n = 0;
for (let f = 0; f < frames * 60; f++) { cpu.writemem(labByName.keys, keys); await s.runFor(200);
  const k = labOf(cpu.pc, cpu.readmem(0xf4)); hist[k] = (hist[k] || 0) + 1; n++; }
const rows = Object.entries(hist).sort((a, b) => b[1] - a[1]).slice(0, 22);
for (const [k, v] of rows) console.log((100 * v / n).toFixed(1).padStart(5) + "%  " + k);
process.exit(0);
