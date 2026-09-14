// Boot the Model B disc in jsbeeb and dump the screen.
//   node tools/bshot.mjs <cycles> <out.png> [disc]
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
import { deflateSync } from "node:zlib";
import path from "node:path";
const cycles = parseInt(process.argv[2] ?? "8000000");
const out = process.argv[3] ?? "build/shot.png";
const disc = process.argv[4] ?? "build/cleob.ssd";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve(disc));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(cycles);
const cpu = s._machine.processor;
console.log(`pc=$${cpu.pc.toString(16)} romsel=$${(cpu.readmem(0xf4)).toString(16)} s=$${cpu.s.toString(16)}`);
const fb = s._completeFb8, W = 1024, X0 = 180, X1 = 860, Y0 = 0, Y1 = 624, w = X1 - X0, h = Y1 - Y0;
const raw = Buffer.alloc((w * 3 + 1) * h);
for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0;
  for (let x = 0; x < w; x++) { const i = ((Y0 + y) * W + X0 + x) * 4, o = y * (w * 3 + 1) + 1 + x * 3;
    raw[o] = fb[i]; raw[o + 1] = fb[i + 1]; raw[o + 2] = fb[i + 2]; } }
const crcT = new Int32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; crcT[n] = c; }
const crc = (b) => { let c = -1; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
const chunk = (t, d) => { const tb = Buffer.from(t), len = Buffer.alloc(4); len.writeUInt32BE(d.length); const cb = Buffer.alloc(4); cb.writeUInt32BE(crc(Buffer.concat([tb, d]))); return Buffer.concat([len, tb, d, cb]); };
const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
writeFileSync(out, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]));
console.log("wrote", out);
process.exit(0);
