// Play N frames with fixed keys, stop at frame_top (bank 7), dump main RAM and the
// per-buffer window origins bank 5 keeps, for bring2.py to compare both rings
// against a render of the map.
import { openB } from "./bopen.mjs";
import { readFileSync, writeFileSync } from "node:fs";
const keys = parseInt(process.argv[2] ?? "2"), frames = parseInt(process.argv[3] ?? "60"), LEVEL = parseInt(process.argv[5] ?? "0");
const MAXSPR = parseInt(/MAXSPRDEF = (\d+)/.exec(readFileSync("build/assets.inc", "utf8"))[1]);
const { s, cpu, A: lab, bank: inbank } = await openB({ level: LEVEL });
for (const m of readFileSync("build/defs_ld.inc", "utf8").matchAll(/^(\w+)\s*=\s*\$([0-9A-Fa-f]+)/gm)) if (lab[m[1]] === undefined) lab[m[1]] = parseInt(m[2], 16);   // MENU_BASE, MAP6: constants
if (lab.TILES === undefined) lab.TILES = lab.MENU_BASE;
// the level's tiles and map, as the loader put them in banks 5 and 6, for bring2.py
{ const nt = inbank(7, () => cpu.readmem(lab.LV_HDR + 21)), lw = inbank(7, () => cpu.readmem(lab.LV_HDR)), lh = inbank(7, () => cpu.readmem(lab.LV_HDR + 1));
  const tiles = Buffer.alloc(64 * nt); inbank(5, () => { for (let i = 0; i < tiles.length; i++) tiles[i] = cpu.readmem(lab.TILES + i); });
  const map = Buffer.alloc(1 << (lw + lh)); inbank(6, () => { for (let i = 0; i < map.length; i++) map[i] = cpu.readmem(lab.MAP6 + i); });
  writeFileSync("build/tiles.bin", tiles); writeFileSync("build/map.bin", map);
  const flat = Array.from({ length: 32 }, (_, i) => cpu.readmem(lab.FLATTAB + i));   // main RAM: the flat pairs
  writeFileSync("build/level.json", JSON.stringify({ MAPW: 1 << lw, MAPH: 1 << lh, NTILES: nt, level: LEVEL, flat })); }
// 'pre': stop at draw_sprites (bank 5), where the current buffer's ring is pure map
const pre = (process.argv[4] || "") === "pre";
const stopAt = pre ? lab.draw_sprites : lab.frame_top, stopBank = 7;   // (draw_sprites is bank 7's now)
const h = cpu.debugInstruction.add((p) => p === stopAt && cpu.readmem(0xf4) === stopBank);
for (let f = 0; f < frames; f++) {
  cpu.writemem(lab.keys, keys);
  for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === stopAt && cpu.readmem(0xf4) === stopBank) break; }
}
h.remove();
const b = Buffer.alloc(0x8000); for (let a = 0; a < 0x8000; a++) b[a] = cpu.readmem(a);
writeFileSync("build/ram.bin", b);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
const st = inbank(7, () => ({ wcx: r16(lab.wcx), wcy: cpu.readmem(lab.wcy), wfine: cpu.readmem(lab.wfine), curbuf: cpu.readmem(lab.curbuf),
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
