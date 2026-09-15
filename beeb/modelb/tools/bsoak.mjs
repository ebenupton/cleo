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
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(24_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const tiles = readFileSync("build/tiles.bin"), mp = readFileSync("build/map.bin");
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
// A sprite the blitter kept (match_sprites said its pixels are already right) is not
// erased, so at pre_spr its rectangle is not map: skip those chars.
const keptRects = () => {
  const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 4);
  const buf = cpu.readmem(lab.curbuf), n = cpu.readmem(lab.RECCNT + buf), out = [];
  for (let i = 0; i < n; i++) {
    if (!cpu.readmem(lab.KEEP + i)) continue;
    const p = lab.SPRREC + buf * 160 + i * 10;
    out.push({ cx: cpu.readmem(p + 5) | (cpu.readmem(p + 6) << 8), cy: cpu.readmem(p + 7),
               w: cpu.readmem(p + 8), h: cpu.readmem(p + 9) & 0x7f });
  }
  cpu.writemem(0xfe30, was); return out;
};
const check = () => {
  const kept = keptRects();
  const inKept = (cx, cy) => kept.some((r) => cx >= r.cx && cx < r.cx + r.w && cy >= r.cy && cy < r.cy + r.h);
  const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
  const curbuf = cpu.readmem(lab.curbuf), base = curbuf ? 0x4680 : 0x0a80;
  const wcx = r16(lab.wcx), wcy = cpu.readmem(lab.wcy);
  let bad = 0;
  for (let r = 0; r < 22; r++) { const cy = wcy + r;
    for (let c = 0; c < 80; c++) { const mx = wcx + c; if ((cy >> 1) >= 32 || (mx >> 2) >= 32) continue;
      const o = mp[(cy >> 1) * 32 + (mx >> 2)] * 64 + (cy & 1) * 32 + (mx & 3) * 8;
      const rc = ((cy % 23) * 80 + mx) % 1840;
      if (inKept(mx, cy)) continue;
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
  if (wcx === 0) { cpu.writemem(0xfe30, was); return 0; }   // no row straddles: the
  let mbad = 0, mc = []; const mb = base - 640, last = base + 1760 * 8;  // mirror is not read
  for (let c = wcx; c < 80; c++) for (let k = 0; k < 8; k++)
    if (cpu.readmem(mb + c * 8 + k) !== cpu.readmem(last + c * 8 + k)) { mbad++; mc.push(c); break; }
  cpu.writemem(0xfe30, was); lastmc = mc; return mbad; };
let lastmc = [];
// a repeatable pseudo-random walk, so a long run visits positions a fixed sequence
// never reaches; the seed is argv[3]
let rng = (parseInt(process.argv[3] ?? "1") >>> 0) || 1;
const nextKey = () => { rng ^= rng << 13; rng >>>= 0; rng ^= rng >> 17; rng ^= rng << 5; rng >>>= 0;
  return [0, 1, 2, 4, 5, 6, 2, 6, 4][rng % 9]; };
let held = 2, heldFor = 0;
let fails = 0;
const span = { px: [999, -1], py: [999, -1], wcx: [999, -1], wcy: [999, -1] };
const note = (k, v) => { if (v < span[k][0]) span[k][0] = v; if (v > span[k][1]) span[k][1] = v; };
for (let f = 0; f < frames; f++) {
  if (heldFor-- <= 0) { held = nextKey(); heldFor = 3 + (rng % 20); }
  cpu.writemem(lab.keys, held);
  let hit = false;
  stopAt = lab.pre_spr;
  for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === 7) { hit = true; break; } }
  if (!hit) { console.log(`frame ${f}: never reached pre_spr -- hung at pc=$${cpu.pc.toString(16)}`); process.exit(1); }
  { const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
    note("px", r16(lab.px)); note("py", r16(lab.py)); note("wcx", r16(lab.wcx)); note("wcy", cpu.readmem(lab.wcy));
    cpu.writemem(0xfe30, was); }
  if (f % 10 === 9) {
    const r = check();
    stopAt = lab.wait_flip;
    for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === 7) break; }
    r.mbad = checkMirror();
    if (r.bad || r.mbad) { fails++; console.log(`frame ${f}: ${JSON.stringify(r)} mchars=${lastmc.slice(0,10)} wcx=${r.wcx} buf=${r.curbuf}`); }
  }
}
console.log(fails ? `${fails} checks failed` : `clean over ${frames} frames`);
console.log("visited: px " + span.px.join("..") + ", py " + span.py.join("..") +
  ", window " + span.wcx.join("..") + " x " + span.wcy.join(".."));
process.exit(0);
