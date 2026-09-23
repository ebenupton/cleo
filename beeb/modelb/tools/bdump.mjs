// jsbeeb's half of the BeebEm lock-step: the same frames, the same key script, the same
// per-frame line as the headless BeebEm harness (scratchpad hb/main.cpp) -- the logic
// state as bdiff reads it, a hash of the display RAM, the CRTC registers -- and at one
// frame the display RAM and a screenshot.
//   node tools/bdump.mjs [frames] [seed] [level] [shotFrame] [outPrefix] [shotEvery]
import { openB } from "./bopen.mjs";
import { writeFileSync } from "node:fs";
const frames = parseInt(process.argv[2] ?? "100"), seed0 = parseInt(process.argv[3] ?? "1"), LEVEL = parseInt(process.argv[4] ?? "0");
const shot = parseInt(process.argv[5] ?? "-1"), out = process.argv[6] ?? "build/jb", every = parseInt(process.argv[7] ?? "0");
// BDISC / BLABELS: another disc image and its labels
const B = await openB({ level: LEVEL, disc: process.env.BDISC ?? "build/cleob.ssd", labels: process.env.BLABELS ?? "build/labels.txt" }); const { s, cpu, A, bank } = B;
const zp = ["px","py","vx","vy","anim","evframe","facing","running","firing","hurt","control","bx","by","bvx","bvy","bcnt","bactive","bounce","stars","exiting","lives","health","score","frame","wx","wy","lastkeys","gridsh"];
const two = new Set(["px","py","vx","vy","evframe","bx","by","bvx","bvy","score","frame","wx","wy"]);
const NOBJ = cpu.readmem(A.nobj), OBJN = 149;
const fnv = (a, n) => { let h = 2166136261; for (let i = 0; i < n; i++) { h ^= cpu.readmem(a + i); h = Math.imul(h, 16777619) >>> 0; } return h >>> 0; };
let rng = seed0 >>> 0; const rnd = () => (rng = (Math.imul(rng, 1103515245) + 12345) >>> 0, rng >>> 16);
let keys = 0, hold = 0; const keyset = [0, 1, 2, 2|4, 1|4, 4, 16, 2|16, 1|16, 8];
const lines = [];
for (let f = 0; f < frames; f++) {
  if (hold-- <= 0) { keys = keyset[rnd() % 10]; hold = 4 + rnd() % 40; }
  cpu.writemem(A.keys, keys); await B.runTo(A.frame_top, 7);
  let o = `f=${f} k=${keys}`;
  for (const n of zp) { const a = A[n]; o += ` ${n}=${two.has(n) ? cpu.readmem(a) | (cpu.readmem(a + 1) << 8) : cpu.readmem(a)}`; }
  bank(7, () => { for (let k = 0; k < 16; k++) { const arr = []; for (let i = 0; i < NOBJ; i++) arr.push(cpu.readmem(A.LV_OBJST + k * OBJN + i)); o += ` O${k}=${arr.join(",")}`; } });
  o += ` disp=${fnv(0x300, 0x7d00).toString(16)}`;
  const r = cpu.video.regs; o += ` crtc=${r[0]},${r[4]},${r[6]},${r[7]},${r[8]},${r[9]},${r[12]},${r[13]}`;
  lines.push(o);
  if (f === shot || (every && f % every === 0)) {
    // the picture: at the game's next vsync interrupt (its vsyncs counter moves), as the
    // headless BeebEm harness does, so both show the same field
    { const v0 = cpu.readmem(A.vsyncs); for (let n = 0; n < 400 && cpu.readmem(A.vsyncs) === v0; n++) await s.runFor(2000); }
    const d = Buffer.alloc(0x7d00); for (let i = 0; i < 0x7d00; i++) d[i] = cpu.readmem(0x300 + i);
    writeFileSync(`${out}_f${f}.dispram`, d); writeFileSync(`${out}_f${f}.png`, await s.screenshotActive());
  }
}
console.log(lines.join("\n"));
