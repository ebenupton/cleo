// Play N frames with fixed keys, stop at frame_top (bank 7), dump main RAM and the
// per-buffer window origins bank 5 keeps, for bring2.py to compare both rings
// against a render of the map.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
const keys = parseInt(process.argv[2] ?? "2"), frames = parseInt(process.argv[3] ?? "60");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const MAXSPR = parseInt(/MAXSPRDEF = (\d+)/.exec((await import("node:fs")).readFileSync("build/assets.inc", "utf8"))[1]);
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
const inbank = (b, f) => { const was = cpu.readmem(0xf4); cpu.writemem(0xf4, b); cpu.writemem(0xfe30, b); const r = f(); cpu.writemem(0xf4, was); cpu.writemem(0xfe30, was); return r; };
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(30_000_000);
inbank(7, () => cpu.writemem(lab.scan_keys, 0x60));       // the harness owns 'keys'
// 'pre': stop at draw_sprites (bank 5), where the current buffer's ring is pure map
const pre = (process.argv[4] || "") === "pre";
const stopAt = pre ? lab.draw_sprites : lab.frame_top, stopBank = pre ? 5 : 7;
const h = cpu.debugInstruction.add((p) => p === stopAt && cpu.readmem(0xf4) === stopBank);
for (let f = 0; f < frames; f++) {
  cpu.writemem(lab.keys, keys);
  for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === stopBank) break; }
}
h.remove();
const b = Buffer.alloc(0x8000); for (let a = 0; a < 0x8000; a++) b[a] = cpu.readmem(a);
writeFileSync("build/ram.bin", b);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
const st = inbank(5, () => ({ wcx: r16(lab.wcx), wcy: cpu.readmem(lab.wcy), wfine: cpu.readmem(lab.wfine), curbuf: cpu.readmem(lab.curbuf),
  bufcx: [r16(lab.BUF_CX), r16(lab.BUF_CX + 2)], bufcy: [cpu.readmem(lab.BUF_CY), cpu.readmem(lab.BUF_CY + 1)],
  valid: [cpu.readmem(lab.BUF_VALID), cpu.readmem(lab.BUF_VALID + 1)],
  px: r16(lab.px), py: r16(lab.py), frame: cpu.readmem(lab.frame), wcxm: cpu.readmem(0xe5), mrow: cpu.readmem(0xe4),
  // the records of the buffer being drawn, with KEEP: a kept sprite's pixels stay in the ring
  kept: (() => { const cb = cpu.readmem(lab.curbuf), n = cpu.readmem(lab.RECCNT + cb), out = [];
    for (let i = 0; i < n; i++) { const r = lab.SPRREC + (cb * MAXSPR + i) * 10;
      out.push({ keep: cpu.readmem(lab.KEEP + i), id: cpu.readmem(r), cx: r16(r + 5), cy: cpu.readmem(r + 7), w: cpu.readmem(r + 8), h: cpu.readmem(r + 9) & 0x7f }); }
    return out; })() }));
writeFileSync("build/state.json", JSON.stringify(st));
console.log(JSON.stringify(st));
process.exit(0);
