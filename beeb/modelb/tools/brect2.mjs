// Log every draw_maprect call (args before clipping) with the phase it came from.
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
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60);
  const off = (process.argv[4] || "").split(",");
  if (off.includes("nospr")) cpu.writemem(lab.queue_sprites, 0x60);
  if (off.includes("nopart")) { cpu.writemem(0xfe30, 5); cpu.writemem(lab.copy_partial, 0x60); cpu.writemem(0xfe30, 7); }
  cpu.writemem(0xfe30, was); }
let phase = "?", log = [];
cpu.debugInstruction.add((p) => {
  if (p === lab.frame_top && cpu.readmem(0xf4) === 7) { phase = "scroll"; log.push({ f: cpu.readmem(lab.frame), phase: "FRAME", wcx: cpu.readmem(lab.wcx), wcy: cpu.readmem(lab.wcy) }); }
  else if (p === lab.erase_old && cpu.readmem(0xf4) === 4) phase = "erase";
  else if (p === lab.draw_maprect && cpu.readmem(0xf4) === 5)
    log.push({ f: cpu.readmem(lab.frame), ret: ((cpu.readmem(0x101+cpu.s) | (cpu.readmem(0x102+cpu.s)<<8))+1).toString(16), phase, cx: cpu.readmem(lab.dt_cx), n: cpu.readmem(lab.dt_ncx), cy: cpu.readmem(lab.dt_cy), ncy: cpu.readmem(lab.dt_ncy) });
  return p === lab.frame_top && cpu.readmem(0xf4) === 7;
});
for (let f = 0; f < frames; f++) { cpu.writemem(lab.keys, keys); for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === lab.frame_top && cpu.readmem(0xf4) === 7) break; } }
const b = Buffer.alloc(0x8000); for (let a = 0; a < 0x8000; a++) b[a] = cpu.readmem(a);
writeFileSync("build/ram.bin", b);
const wasb = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
writeFileSync("build/state.json", JSON.stringify({ wcx: r16(lab.wcx), wcy: cpu.readmem(lab.wcy), wfine: cpu.readmem(lab.wfine),
  curbuf: cpu.readmem(lab.curbuf), bptx: [cpu.readmem(lab.bptx), cpu.readmem(lab.bptx+1)], bpty: [cpu.readmem(lab.bpty), cpu.readmem(lab.bpty+1)],
  px: r16(lab.px), py: r16(lab.py), frame: cpu.readmem(lab.frame) }));
cpu.writemem(0xfe30, wasb);
console.log(readFileSync("build/state.json", "utf8"));
console.log(log.slice(-400).map(e => JSON.stringify(e)).join("\n"));
process.exit(0);
