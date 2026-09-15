// Play for N frames, then compare both rings with a reference render of the map.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
const keys = parseInt(process.argv[2] ?? "6"), frames = parseInt(process.argv[3] ?? "200");
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
  if (off.includes("nomir")) cpu.writemem(lab.mirror_copy, 0x60);
  if (off.includes("noerase")) { cpu.writemem(0xfe30, 4); cpu.writemem(lab.erase_old, 0x60); cpu.writemem(0xfe30, 7); }
  if (off.includes("nopart")) { cpu.writemem(0xfe30, 5); cpu.writemem(lab.copy_partial, 0x60); cpu.writemem(0xfe30, 7); }
  cpu.writemem(0xfe30, was); }
// Stop exactly at frame_top: bptx/bpty are written at the end of scroll_validate, so a
// sample taken mid-frame can catch a buffer half way through being brought up to date.
const stopAt = (process.argv[4] || "").includes("pre") ? lab.pre_spr : lab.frame_top;
const h = cpu.debugInstruction.add((p) => p === stopAt && cpu.readmem(0xf4) === 7);
for (let f = 0; f < frames; f++) {
  cpu.writemem(lab.keys, keys);
  for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === 7) break; }
}
h.remove();
const b = Buffer.alloc(0x8000); for (let a = 0; a < 0x8000; a++) b[a] = cpu.readmem(a);
writeFileSync("build/ram.bin", b);
const wasb = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
writeFileSync("build/state.json", JSON.stringify({ wcx: r16(lab.wcx), wcy: cpu.readmem(lab.wcy), wfine: cpu.readmem(lab.wfine),
  curbuf: cpu.readmem(lab.curbuf), bptx: [cpu.readmem(lab.bptx), cpu.readmem(lab.bptx+1)], bpty: [cpu.readmem(lab.bpty), cpu.readmem(lab.bpty+1)], px: r16(lab.px), py: r16(lab.py), frame: cpu.readmem(lab.frame) }));
cpu.writemem(0xfe30, wasb);
console.log(readFileSync("build/state.json", "utf8"));
process.exit(0);
