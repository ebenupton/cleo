// Long run with the keys changing, checking both the ring and the mirror at intervals.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "2000");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const tiles = readFileSync("build/tiles.bin"), mp = readFileSync("build/map.bin");
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
const check = () => {
  const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
  const curbuf = cpu.readmem(lab.curbuf), base = curbuf ? 0x4680 : 0x0a80;
  const wcx = r16(lab.wcx), wcy = cpu.readmem(lab.wcy);
  let bad = 0;
  for (let r = 0; r < 22; r++) { const cy = wcy + r;
    for (let c = 0; c < 80; c++) { const mx = wcx + c; if ((cy >> 1) >= 32 || (mx >> 2) >= 32) continue;
      const o = mp[(cy >> 1) * 32 + (mx >> 2)] * 64 + (cy & 1) * 32 + (mx & 3) * 8;
      const rc = ((cy % 23) * 80 + mx) % 1840;
      for (let k = 0; k < 8; k++) if (cpu.readmem(base + rc * 8 + k) !== tiles[o + k]) { bad++; break; } } }
  let mbad = 0, mchars = [];
  cpu.writemem(0xfe30, was);
  return { bad, mbad, mchars, wcx, wcy, px: r16(lab.px), py: r16(lab.py), curbuf, mrow: cpu.readmem(lab.mrow) };
};
let stopAt = 0;
cpu.debugInstruction.add((p) => p === stopAt && cpu.readmem(0xf4) === 7);
// the mirror is only up to date once mirror_copy has run, which is after the sprites:
// the ring is checked at pre_spr, where it is pure map, and the mirror at wait_flip.
const checkMirror = () => { const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
  const base = cpu.readmem(lab.curbuf) ? 0x4680 : 0x0a80, wcx = r16(lab.wcx);
  let mbad = 0; const mb = base - 640, last = base + 1760 * 8;
  for (let c = wcx; c < 80; c++) for (let k = 0; k < 8; k++)
    if (cpu.readmem(mb + c * 8 + k) !== cpu.readmem(last + c * 8 + k)) { mbad++; break; }
  cpu.writemem(0xfe30, was); return mbad; };
const seq = [2, 2, 6, 6, 1, 1, 5, 4, 2, 6, 0, 1, 3, 2, 4, 6];
let fails = 0;
for (let f = 0; f < frames; f++) {
  cpu.writemem(lab.keys, seq[(f >> 5) % seq.length]);
  let hit = false;
  stopAt = lab.pre_spr;
  for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === 7) { hit = true; break; } }
  if (!hit) { console.log(`frame ${f}: never reached pre_spr -- hung at pc=$${cpu.pc.toString(16)}`); process.exit(1); }
  if (f % 10 === 9) {
    const r = check();
    stopAt = lab.wait_flip;
    for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === 7) break; }
    r.mbad = checkMirror();
    if (r.bad || r.mbad) { fails++; console.log(`frame ${f}: ${JSON.stringify(r)}`); }
  }
}
console.log(fails ? `${fails} checks failed` : `clean over ${frames} frames`);
process.exit(0);
