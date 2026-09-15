// Teleport Cleo around the map and check the ring settles: this is the path a fixed
// key sequence never reaches -- the full-window redraw, and every ring phase.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const hops = parseInt(process.argv[2] ?? "40");
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
let stopAt = 0;
cpu.debugInstruction.add((p) => p === stopAt && cpu.readmem(0xf4) === 7);
const step = async (to) => { stopAt = to; for (let i = 0; i < 600; i++) { await s.runFor(2000); if (cpu.pc === to && cpu.readmem(0xf4) === 7) return true; } return false; };
const check = () => { const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
  const buf = cpu.readmem(lab.curbuf), base = buf ? 0x4680 : 0x0a80, wcx = r16(lab.wcx), wcy = cpu.readmem(lab.wcy);
  let bad = 0;
  for (let r = 0; r < 22; r++) { const cy = wcy + r;
    for (let c = 0; c < 80; c++) { const mx = wcx + c; if ((cy >> 1) >= 32 || (mx >> 2) >= 32) continue;
      const o = mp[(cy >> 1) * 32 + (mx >> 2)] * 64 + (cy & 1) * 32 + (mx & 3) * 8;
      const rc = ((cy % 23) * 80 + mx) % 1840;
      for (let k = 0; k < 8; k++) if (cpu.readmem(base + rc * 8 + k) !== tiles[o + k]) { bad++; break; } } }
  cpu.writemem(0xfe30, was); return { bad, wcx, wcy, buf }; };
let rng = 2463534242, fails = 0;
const rnd = (n) => { rng ^= rng << 13; rng >>>= 0; rng ^= rng >> 17; rng ^= rng << 5; rng >>>= 0; return rng % n; };
for (let h = 0; h < hops; h++) {
  const px = 16 + rnd(224), py = 16 + rnd(224);
  { const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7);
    cpu.writemem(lab.px, px); cpu.writemem(lab.px + 1, 0); cpu.writemem(lab.py, py); cpu.writemem(lab.py + 1, 0);
    cpu.writemem(lab.vy, 0); cpu.writemem(lab.vy + 1, 0); cpu.writemem(0xfe30, was); }
  cpu.writemem(lab.keys, 0);
  for (let f = 0; f < 6; f++) if (!await step(lab.pre_spr)) { console.log("hung"); process.exit(1); }
  const r = check();
  if (r.bad) { fails++; console.log(`hop ${h} to (${px},${py}): ${JSON.stringify(r)}`); }
}
console.log(fails ? `${fails} of ${hops} hops left the ring wrong` : `clean over ${hops} teleports`);
process.exit(0);
