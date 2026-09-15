// Model B sprite oracle: after a frame, every opaque pixel of every sprite on the
// list must equal its data in the ring; masked-out pixels are not this sprite's to
// answer for, nor are bytes a later sprite covers.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(16_000_000);
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
const wcx = r16(lab.wcx), wcy = cpu.readmem(lab.wcy), wfine = cpu.readmem(lab.wfine);
const wx = r16(lab.wx), wy = r16(lab.wy), curbuf = cpu.readmem(lab.curbuf);
const ringbase = r16(lab.ringbase);
// the records say what was drawn into the buffer just finished
cpu.writemem(0xfe30, 4);
const n = cpu.readmem(lab.RECCNT + (curbuf ^ 1));
const recbase = lab.SPRREC + (curbuf ^ 1) * 10 * 16;
const tab = (i) => [...Array(8)].map((_, k) => cpu.readmem(lab.SPRTAB + i * 8 + k));
const bank4 = (a) => cpu.readmem(a);
const swap = (b) => ((b & 0x80) >> 3) | ((b & 0x40) >> 1) | ((b & 0x20) << 1) | ((b & 0x10) << 3) | ((b & 8) >> 3) | ((b & 4) >> 1) | ((b & 2) << 1) | ((b & 1) << 3);
// the ring of the buffer that was just drawn: it is the one NOT being displayed
const ringA = 0x0a80, ringB = 0x4680;
const base = (curbuf ^ 1) ? ringB : ringA;   // curbuf has already flipped by now
let checked = 0, bad = 0, msg = [];
for (let i = 0; i < n; i++) {
  const rec = [...Array(10)].map((_, k) => cpu.readmem(recbase + i * 10 + k));
  const id = rec[0], cx = rec[5] | (rec[6] << 8), cy = rec[7];
  const t = tab(id);
  if (i < 4) console.log(`rec ${i}: id ${id} list(${rec[1] | (rec[2] << 8)},${rec[3] | (rec[4] << 8)}) cx ${cx} cy ${cy} w ${rec[8]} h ${rec[9]} tab W ${t[2]} lines ${t[7]}`);
  if (!t[2]) continue;
  const ptr = t[0] | (t[1] << 8), W = t[2], hpx = t[3], flags = t[6], lines = t[7];
  const mask = r16(lab.SPRMSKTAB + id * 2);
  const refx = t[4] << 24 >> 24, refy = t[5] << 24 >> 24;
  // this sprite's own geometry, recomputed
  const listx = rec[1] | (rec[2] << 8), listy = rec[3] | (rec[4] << 8);
  const sx = listx - refx - wx, sy = listy - refy - wy;
  const c0 = sx >> 1, lb0 = 2 * sy + wfine;
  const mirror = flags & 1;
  for (let ic = 0; ic < W; ic++) {
    const sc = mirror ? c0 + (W - 1 - ic) : c0 + ic;
    if (sc < 0 || sc >= 80) continue;
    for (let l = 0; l < lines; l++) {
      const line = lb0 + l; if (line < 0 || line >= 22 * 8) continue;
      const row = line >> 3, ra = line & 7;
      const slot = (wcy + row) % 23;
      const ch = slot * 80 + ((wcx + sc) % 80) + (((wcx + sc) >= 80) ? 0 : 0);
      const rc = (slot * 80 + wcx + sc) % 1840;
      const addr = base + rc * 8 + ra;
      let data = bank4(ptr + ic * lines + l);
      const pr = l >> 1, mb = bank4(mask + (ic >> 2) * hpx + pr);
      const pair = (mb >> (6 - 2 * (ic & 3))) & 3;
      let m = (pair & 2 ? 0 : 0xCC) | (pair & 1 ? 0 : 0x33);
      if (mirror) { data = swap(data); m = swap(m); }
      if (m === 0xFF) continue;
      const got = cpu.readmem(addr);
      checked++;
      if (((got ^ data) & ~m & 0xFF) !== 0 && bad < 6) msg.push(`id ${id} col ${ic} line ${l} @$${addr.toString(16)}: ring $${got.toString(16)} data $${data.toString(16)} mask $${m.toString(16)}`);
      if (((got ^ data) & ~m & 0xFF) !== 0) bad++;
    }
  }
}
console.log(`curbuf ${curbuf} base $${base.toString(16)} wcx ${wcx} wcy ${wcy} wx ${wx} wy ${wy}\nrecords ${n}, opaque byte-pixels checked ${checked}, wrong ${bad}`);
console.log(msg.join("\n"));
process.exit(0);
