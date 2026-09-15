import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
const keys = parseInt(process.argv[2] ?? "6"), frames = parseInt(process.argv[3] ?? "150");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const stop = lab[process.argv[5] || "pre_spr"];
const h = cpu.debugInstruction.add((p) => p === stop && cpu.readmem(0xf4) === 7);
for (let f = 0; f < frames; f++) { cpu.writemem(lab.keys, keys); for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === stop && cpu.readmem(0xf4) === 7) break; } }
h.remove();
const b = Buffer.alloc(0x8000); for (let a = 0; a < 0x8000; a++) b[a] = cpu.readmem(a);
writeFileSync("build/ram.bin", b);
let wasb = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
const st = { wcx: r16(lab.wcx), wcy: cpu.readmem(lab.wcy), wfine: cpu.readmem(lab.wfine), curbuf: cpu.readmem(lab.curbuf),
  bptx: [cpu.readmem(lab.bptx), cpu.readmem(lab.bptx+1)], bpty: [cpu.readmem(lab.bpty), cpu.readmem(lab.bpty+1)],
  px: r16(lab.px), py: r16(lab.py), frame: cpu.readmem(lab.frame) };
writeFileSync("build/state.json", JSON.stringify(st));
cpu.writemem(0xfe30, 4);
const recs = [];
for (let buf = 0; buf < 2; buf++) {
  const n = cpu.readmem(lab.RECCNT + buf), base = lab.SPRREC + buf * 10 * 16, out = [];
  for (let i = 0; i < n; i++) { const p = base + i * 10, r = []; for (let k = 0; k < 10; k++) r.push(cpu.readmem(p + k));
    out.push({ id: r[0], cx: r[5] | (r[6] << 8), cy: r[7], w: r[8], h: r[9] & 0x7f, clip: r[9] >> 7 }); }
  recs.push({ buf, n, out });
}
cpu.writemem(0xfe30, wasb);
console.log(JSON.stringify(st));
for (const r of recs) console.log("buf " + r.buf + " n=" + r.n + " " + JSON.stringify(r.out));
process.exit(0);
