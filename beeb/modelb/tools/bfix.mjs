// Stop at pre_spr, then call draw_maprect by hand over a rectangle and report whether
// that rectangle's chars become correct: it separates "the rect was never issued" from
// "the blitter draws this rect wrong".
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const keys = parseInt(process.argv[2] ?? "6"), frames = parseInt(process.argv[3] ?? "150");
const [cx, ncx, ty, ny] = (process.argv[4] || "68,16,23,2").split(",").map(Number);
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const h = cpu.debugInstruction.add((p) => p === lab.pre_spr && cpu.readmem(0xf4) === 7);
for (let f = 0; f < frames; f++) { cpu.writemem(lab.keys, keys); for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === lab.pre_spr && cpu.readmem(0xf4) === 7) break; } }
h.remove();
const tiles = readFileSync("build/tiles.bin"), mp = readFileSync("build/map.bin");
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
const curbuf = cpu.readmem(lab.curbuf), base = curbuf ? 0x4680 : 0x0a80;
const wcx = r16(lab.wcx), wcy = cpu.readmem(lab.wcy);
const check = () => { let bad = []; for (let r = 0; r < 22; r++) { const cy = wcy + r;
    for (let c = 0; c < 80; c++) { const mx = wcx + c; if ((cy >> 1) >= 32 || (mx >> 2) >= 32) continue;
      const o = mp[(cy >> 1) * 32 + (mx >> 2)] * 64 + (cy & 1) * 32 + (mx & 3) * 8;
      const rc = (((cy % 23) * 80 + mx) % 1840);
      for (let k = 0; k < 8; k++) if (cpu.readmem(base + rc * 8 + k) !== tiles[o + k]) { bad.push([r, c, mx, cy]); break; } } }
  return bad; };
console.log("before:", check().length, JSON.stringify(check().slice(0, 6)));
// hand-call draw_maprect
cpu.writemem(lab.dt_cx, cx); cpu.writemem(lab.dt_ncx, ncx); cpu.writemem(lab.dt_ty, ty); cpu.writemem(lab.dt_ny, ny);
cpu.writemem(0x01ff, 0x00); cpu.writemem(0x01fe, 0xff);   // rts -> $0100
const oldS = cpu.s; cpu.s = 0xfd;
cpu.writemem(0xf4, 5); cpu.writemem(0xfe30, 5);
cpu.pc = lab.draw_maprect;
for (let i = 0; i < 2000; i++) { await s.runFor(200); if (cpu.pc === 0x0100) break; }
console.log("returned at", cpu.pc.toString(16));
cpu.s = oldS;
console.log("after:", check().length, JSON.stringify(check().slice(0, 6)));
process.exit(0);
