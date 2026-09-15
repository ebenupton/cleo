// Where did the sprite actually land?  Compare the ring against a pure-map render at
// wait_flip and report the drawn footprint in game pixels, next to where the logic
// says Cleo is.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const keys = parseInt(process.argv[2] ?? "0"), frames = parseInt(process.argv[3] ?? "60");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
let stopAt = 0;
cpu.debugInstruction.add((p) => p === stopAt && cpu.readmem(0xf4) === 7);
const step = async (to) => { stopAt = to; for (let i = 0; i < 600; i++) { await s.runFor(2000); if (cpu.pc === to && cpu.readmem(0xf4) === 7) return true; } return false; };
for (let f = 0; f < frames; f++) { cpu.writemem(lab.keys, keys); await s.runFor(40000); }
await step(lab.wait_flip);
const tiles = readFileSync("build/tiles.bin"), mp = readFileSync("build/map.bin");
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
const buf = cpu.readmem(lab.curbuf) ^ 1;            // the buffer just finished
const base = buf ? 0x4680 : 0x0a80;
const st = { px: r16(lab.px), py: r16(lab.py), wx: r16(lab.wx), wy: r16(lab.wy), wcx: r16(lab.wcx),
  wcy: cpu.readmem(lab.wcy), wfine: cpu.readmem(lab.wfine), onground: cpu.readmem(lab.onground), floor: cpu.readmem(lab.floor) };
// the records say where each sprite was put; the ring says where its pixels landed
cpu.writemem(0xfe30, 4);
const recs = []; const nrec = cpu.readmem(lab.RECCNT + buf);
for (let i = 0; i < nrec; i++) { const p = lab.SPRREC + buf * 160 + i * 10, v = [];
  for (let k = 0; k < 10; k++) v.push(cpu.readmem(p + k));
  recs.push({ id: v[0], spx: v[1] | (v[2] << 8), spy: v[3] | (v[4] << 8), cx: v[5] | (v[6] << 8), cy: v[7], w: v[8], h: v[9] & 0x7f }); }
cpu.writemem(0xfe30, 7);
for (const rec of recs) {
let minx = 999, maxx = -1, miny = 9999, maxy = -1;
for (let r = 0; r < rec.h; r++) { const cy = rec.cy + r;
  for (let c = 0; c < rec.w; c++) { const mx = rec.cx + c; if ((cy >> 1) >= 32 || (mx >> 2) >= 32) continue;
    const o = mp[(cy >> 1) * 32 + (mx >> 2)] * 64 + (cy & 1) * 32 + (mx & 3) * 8;
    const rc = ((cy % 23) * 80 + mx) % 1840;
    for (let k = 0; k < 8; k++) {                  // k = scanline in the char
      if (cpu.readmem(base + rc * 8 + k) !== tiles[o + k]) {
        const gx = mx * 2, gy = cy * 4 + (k >> 1); // a char is 2 game px across, a scanline half a game px down
        if (gx < minx) minx = gx; if (gx + 1 > maxx) maxx = gx + 1;
        if (gy < miny) miny = gy; if (gy > maxy) maxy = gy;
      } } } }
console.log(`sprite ${rec.id} at (${rec.spx}, ${rec.spy}): pixels land in x ${minx}..${maxx}, y ${miny}..${maxy}` +
  `   (dx ${minx - rec.spx}..${maxx - rec.spx}, dy ${miny - rec.spy}..${maxy - rec.spy})`);
}
cpu.writemem(0xfe30, was);
console.log(JSON.stringify(st));
console.log(`Cleo says: feet (${st.px}, ${st.py}); the floor under her is ${st.floor}`);
process.exit(0);
