import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
// a name for every label, so an address can be attributed to the routine it is in
const byBank = { 4: [], 5: [], 6: [], 7: [], 0: [] };
for (const [n, a] of Object.entries(lab)) {
  if (a >= 0x8000 && a < 0xc000) { for (const b of [4, 5, 6, 7]) byBank[b].push([a, n]); }
  else if (a >= 0x140 && a < 0x300) byBank[0].push([a, n]);
}
for (const b in byBank) byBank[b].sort((x, y) => x[0] - y[0]);
const known = { 4: ["drawsprite", "sprFN", "sprFM", "draw_sprites", "erase_old", "addsprite", "ringaddr", "init_masks", "sext"],
  5: ["draw_maprect", "draw_tile", "ring_row", "ring_next", "fold0", "fold1", "copy_partial", "bar_draw"],
  6: ["map_strip", "map_col", "alt_row", "map_copy"],
  7: ["player_step", "ground_at", "camera", "scroll_validate", "queue_sprites", "fetch_objs", "calc_ring", "build_sections", "select_backbuf", "mirror_copy", "vsync_tick", "win_px", "scan_keys", "frame_top", "init"],
  0: ["farcall", "mapbyte", "irq_handler"] };
const find = (bank, pc) => { let best = "?";
  for (const n of known[bank] || []) { const a = lab[n]; if (a !== undefined && pc >= a && pc - a < 0x400) { if (best === "?" || a > lab[best]) best = n; } }
  return best; };
const hist = {}; let total = 0;
cpu.debugInstruction.add((pc) => {
  const b = (pc >= 0x8000 && pc < 0xc000) ? cpu.readmem(0xf4) : (pc < 0x300 ? 0 : 9);
  const k = `${b}:${find(b, pc)}`;
  hist[k] = (hist[k] || 0) + 1; total++;
  return false; });
for (let f = 0; f < 20; f++) { cpu.writemem(lab.keys, 6); await s.runFor(40000); }
console.log(`instructions ${total}`);
for (const [k, v] of Object.entries(hist).sort((a, b) => b[1] - a[1]).slice(0, 14))
  console.log(`  ${k.padEnd(22)} ${(100 * v / total).toFixed(1)}%  ${v}`);
process.exit(0);
