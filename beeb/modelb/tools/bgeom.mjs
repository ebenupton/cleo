// The rupture chain shows up as geometry: capture the framebuffer over many frames and
// report the lit scanline span and any lit pixel outside the picture's columns.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "150"), keys = parseInt(process.argv[3] ?? "6");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const W = 1024, seen = {};
for (let f = 0; f < frames; f++) {
  cpu.writemem(lab.keys, keys);
  await s.runFor(40000);
  const fb = s._completeFb8;
  let top = -1, bot = -1, left = 9999, right = -1;
  for (let y = 0; y < 625; y++) for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    if (fb[i] | fb[i + 1] | fb[i + 2]) { if (top < 0) top = y; bot = y; if (x < left) left = x; if (x > right) right = x; }
  }
  const k = `${top}-${bot} x ${left}-${right}`;
  seen[k] = (seen[k] || 0) + 1;
}
for (const [k, v] of Object.entries(seen).sort((a, b) => b[1] - a[1])) console.log(`${String(v).padStart(4)} frames: lit ${k}`);
process.exit(0);
