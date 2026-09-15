// Drive the Model B build: patch scan_keys to an rts and write the key bits, then
// capture frames.   node tools/bplay.mjs <keys> <frames> <out-prefix>
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import { deflateSync } from "node:zlib";
import path from "node:path";
const keys = parseInt(process.argv[2] ?? "0"), frames = parseInt(process.argv[3] ?? "50"), pre = process.argv[4] ?? "build/play";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(13_000_000);                       // load and init
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }   // rts: the harness drives
const png = (out) => { const fb = s._completeFb8, W = 1024, X0 = 180, X1 = 860, Y0 = 0, Y1 = 624, w = X1 - X0, h = Y1 - Y0;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; for (let x = 0; x < w; x++) { const i = ((Y0 + y) * W + X0 + x) * 4, o = y * (w * 3 + 1) + 1 + x * 3; raw[o] = fb[i]; raw[o + 1] = fb[i + 1]; raw[o + 2] = fb[i + 2]; } }
  const crcT = new Int32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; crcT[n] = c; }
  const crc = (b) => { let c = -1; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
  const chunk = (t, d) => { const tb = Buffer.from(t), len = Buffer.alloc(4); len.writeUInt32BE(d.length); const cb = Buffer.alloc(4); cb.writeUInt32BE(crc(Buffer.concat([tb, d]))); return Buffer.concat([len, tb, d, cb]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  writeFileSync(out, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))])); };
let last = -1, shots = 0;
for (let f = 0; f < frames; f++) {
  cpu.writemem(lab.keys, keys);
  await s.runFor(40000);
  const fr = cpu.readmem(lab.frame);
  if (f % Math.max(1, Math.floor(frames / 4)) === 0 && shots < 4) { png(`${pre}${shots}.png`); shots++; }
  if (f % 10 === 0) console.log(`f${f}: px=${r16(lab.px)} py=${r16(lab.py)} wcx=${r16(lab.wcx)} wcy=${cpu.readmem(lab.wcy)} wfine=${cpu.readmem(lab.wfine)} onground=${cpu.readmem(lab.onground)} frame=${fr}`);
}
png(`${pre}_last.png`);
console.log("done");
process.exit(0);
