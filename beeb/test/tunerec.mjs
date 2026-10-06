// The title tune as the machine plays it: boots a disc to the title (Master, or the Model B
// with MODEL=modelb) and records every byte the SN76489 is given, with its time in cycles,
// for SECS seconds of the tune; and times each music_tick (entry to return, cycles), the
// interrupt's longest tune step; and the CRTC's writes (register, value, row, scanline,
// char), to compare the chain's timing in the menus between two builds.
//   node test/tunerec.mjs <disc> <out.json> [secs=30]      (MODEL=modelb: the Model B)
// out.json: {rate: cycles a second, writes: [[cycle, byte], ...], ticks, worst, mean}
import { readdirSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const disc = path.resolve(process.argv[2]), outf = process.argv[3], secs = +(process.argv[4] ?? 30);
const master = process.env.MODEL !== "modelb";
const A = {}; for (const m of readFileSync(path.join(path.dirname(disc), master ? "master" : "modelb", "labels.txt"), "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const s = new MachineSession(master ? "Master" : "B-DFS1.2"); await s.initialise(); await s.boot(30); s.loadDisc(disc);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor;
const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
await s.runFor(40_000_000);                              // to the title, the tune playing
const writes = [];
const poke0 = s._soundChip.poke.bind(s._soundChip);
s._soundChip.poke = (v) => { writes.push([cyc(), v]); return poke0(v); };
let t0 = null, ret = null; const d = [];
cpu.debugInstruction.add((pc) => {
  if (pc === A.music_tick && t0 === null) { t0 = cyc(); ret = (cpu.readmem(0x101 + cpu.s) | (cpu.readmem(0x102 + cpu.s) << 8)) + 1; }
  else if (t0 !== null && pc === ret) { d.push(cyc() - t0); t0 = null; }
  return false;
});
// the CRTC's writes (crtctime.mjs's): register, value, the 6845's row, scanline, char
const v = s._video ?? cpu.video;
let idx = 0; const crtc = [];
const wm = cpu.writemem.bind(cpu);
cpu.writemem = function (addr, b) {
  addr &= 0xffff;
  if (addr === 0xfe00) idx = b & 31;
  else if (addr === 0xfe01) crtc.push([idx, b, v.vertCounter, v.scanlineCounter, v.horizCounter]);
  return wm(addr, b);
};
const start = cyc();
await s.runFor(secs * 2_000_000);
const w = writes.map(([c, v]) => [c - start, v]);
const worst = Math.max(...d), mean = d.reduce((a, b) => a + b, 0) / d.length;
writeFileSync(outf, JSON.stringify({ rate: 2_000_000, writes: w, ticks: d.length, worst, mean, crtc }));
console.log(`${master ? "master" : "modelb"}: ${w.length} chip bytes in ${secs} s; music_tick ${d.length} calls, mean ${mean.toFixed(0)} cycles, worst ${worst}`);
process.exit(0);
