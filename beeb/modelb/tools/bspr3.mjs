// Hold keys for N frames, then list the queued sprites and the drawn records.
import { findJsbeeb, loadLabels } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
const seq = (process.argv[2] ?? "18").split(",").map(Number), frames = seq.length;
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = loadLabels("build/labels.txt");
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const bank = (b, f) => { const was = cpu.readmem(0xf4); cpu.writemem(0xf4, b); cpu.writemem(0xfe30, b); const r = f(); cpu.writemem(0xf4, was); cpu.writemem(0xfe30, was); return r; };
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
async function runTo(pc, b) { const h = cpu.debugInstruction.add((p) => p === pc && cpu.readmem(0xf4) === b);
  try { for (let i = 0; i < 3000; i++) { await s.runFor(20000); if (cpu.pc === pc && cpu.readmem(0xf4) === b) return; } } finally { h.remove(); } throw new Error("timeout"); }
await runTo(A.level_init, 7); bank(7, () => cpu.writemem(A.scan_keys, 0x60));
for (let f = 0; f < 400; f++) { cpu.writemem(A.keys, seq[f % frames]); await runTo(A.frame_top, 7);
  if (cpu.readmem(A.bactive)) { console.log("boomerang active at frame", f); await runTo(A.frame_top, 7); break; } }
// the list is rebuilt by the two steps: run to render_core's draw_sprites to see it full
await runTo(A.draw_sprites, 5);
const n = cpu.readmem(0xa2), r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
console.log("bactive", cpu.readmem(A.bactive), "bx", r16(A.bx), "by", r16(A.by), "px", r16(A.px), "py", r16(A.py), "NSPR", n);
for (let i = 0; i < n; i++) { const e = A.SPRLIST + i * 5; console.log(`  id ${cpu.readmem(e)} at ${r16(e + 1)},${r16(e + 3)}`); }
await runTo(A.frame_top, 7);
bank(5, () => { const cb = cpu.readmem(A.curbuf) ^ 1, rc = cpu.readmem(A.RECCNT + cb); console.log("records of buffer", cb, ":", rc);
  for (let i = 0; i < rc; i++) { const r = A.SPRREC + (cb * 24 + i) * 10; console.log(`  id ${cpu.readmem(r)} rect cx=${r16(r+5)} cy=${cpu.readmem(r+7)} w=${cpu.readmem(r+8)} h=${cpu.readmem(r+9)}`); } });
// and a screenshot of the frame after that
await s.runFor(200000);
{ const { writeFileSync } = await import("node:fs"); const { deflateSync } = await import("node:zlib");
  const fb = s._completeFb8, W = 1024, X0 = 180, X1 = 860, Y0 = 0, Y1 = 625, w = X1 - X0, h = Y1 - Y0;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; for (let x = 0; x < w; x++) { const i = ((Y0 + y) * W + X0 + x) * 4, o = y * (w * 3 + 1) + 1 + x * 3; raw[o] = fb[i]; raw[o + 1] = fb[i + 1]; raw[o + 2] = fb[i + 2]; } }
  const crc = (b) => { let c = ~0; for (const x of b) { c ^= x; for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (0xEDB88320 & -(c & 1)); } return ~c >>> 0; };
  const chunk = (t, d) => { const b = Buffer.alloc(8 + d.length + 4); b.writeUInt32BE(d.length, 0); b.write(t, 4); d.copy(b, 8); b.writeUInt32BE(crc(Buffer.concat([Buffer.from(t), d])), 8 + d.length); return b; };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  writeFileSync("build/shot.png", Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))])); }
process.exit(0);
