// jsbeeb's half of the BeebEm lock-step (test/hbeebem): the same frames, the same key
// script and the same per-frame line as the headless BeebEm harness (hbeebem/main.cpp;
// hbeebem/cmpdump.py compares the two) -- the logic state (zero page and the object
// arrays), a hash of main RAM from the bar up, the CRTC registers -- and at chosen
// frames the main RAM and a screenshot.  The Model B, through bopen.mjs openB (the
// title patched to start a game, the level set in level_loop, scan_keys stubbed);
// each frame is a break at frame_top with bank 7 paged, 'keys' written there from the
// seeded script (LCG: one of ten key sets, FIRE and DOWN included, held 4-43 frames).
// hurt/health are not pinned.
//   node test/bdump.mjs [frames=100] [seed=1] [level=0] [shotFrame=-1] [outPrefix=build/jb] [shotEvery=0]
// BDISC / BLABELS: another disc image and its labels.
// Output (stdout, a line a frame): "f=<n> k=<keys> <var>=<value>... O0=<149 bytes>..
// O15=... disp=<fnv1a hex> crtc=R0,R4,R6,R7,R8,R9,R12,R13"; the 16-bit variables as
// one number.  A shot frame writes <outPrefix>_f<n>.dispram (BARADDR..$7FFF) and
// <outPrefix>_f<n>.png, taken at the game's next vsync (its vsyncs counter moves), as
// the BeebEm harness does, so both show the same field.
import { openB } from "./bopen.mjs";
import { writeFileSync } from "node:fs";
const frames = parseInt(process.argv[2] ?? "100"), seed0 = parseInt(process.argv[3] ?? "1"), LEVEL = parseInt(process.argv[4] ?? "0");
const shot = parseInt(process.argv[5] ?? "-1"), out = process.argv[6] ?? "build/jb", every = parseInt(process.argv[7] ?? "0");
// BDISC / BLABELS: another disc image and its labels
const B = await openB({ level: LEVEL, disc: process.env.BDISC ?? "build/cleo.ssd", labels: process.env.BLABELS ?? "build/modelb/labels.txt" }); const { s, cpu, A, bank } = B;
const zp = ["px","py","vx","vy","anim","ev_frame","facing","running","firing","hurt","control","bx","by","bvx","bvy","bcnt","bactive","bounce","stars","exiting","lives","health","score","frame","wx","wy","last_keys","gridsh"];
const two = new Set(["px","py","vx","vy","ev_frame","bx","by","bvx","bvy","score","frame","wx","wy"]);
const NOBJ = cpu.readmem(A.nobj), OBJN = 149;   // OBJ_MAX: an object array's stride (statecmp.mjs derives it)
// the hashed and dumped range: the bar (BARADDR, the build's defs_ld.inc via loadLabels;
// $300 for a build without it) to $8000 -- the rings and everything else in main RAM
const DISP0 = A.BARADDR ?? 0x300, DISPN = 0x8000 - DISP0;
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
  o += ` disp=${fnv(DISP0, DISPN).toString(16)}`;
  const r = cpu.video.regs; o += ` crtc=${r[0]},${r[4]},${r[6]},${r[7]},${r[8]},${r[9]},${r[12]},${r[13]}`;
  lines.push(o);
  if (f === shot || (every && f % every === 0)) {
    // the picture at the game's next vsync (vsyncs moves; at most 400 x 2000 cycles),
    // as the headless BeebEm harness does, so both show the same field
    { const v0 = cpu.readmem(A.vsyncs); for (let n = 0; n < 400 && cpu.readmem(A.vsyncs) === v0; n++) await s.runFor(2000); }
    const d = Buffer.alloc(DISPN); for (let i = 0; i < DISPN; i++) d[i] = cpu.readmem(DISP0 + i);
    writeFileSync(`${out}_f${f}.dispram`, d); writeFileSync(`${out}_f${f}.png`, await s.screenshotActive());
  }
}
console.log(lines.join("\n"));
