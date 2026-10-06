// What the sound chip is given in play: the SN76489's bytes (snd_write: port A, then the
// addressable latch's SL_SND enable low), frame by frame over N frames of seeded random
// keys (fire and down included: throws, jumps, stomps), then -- with EXIT=1 -- Cleo put in
// the exit's box and the run continued through the next level's load, by cycles, to show
// the exit's fanfare goes on under it.  Prints each frame's bytes decoded per channel
// (a tone's period, a volume's level) and a summary: the effects' starts seen (a voice's
// volume rising from silent).
//   node test/sndplay.mjs master|modelb <disc> <labels> [level=0] [frames=600]
import { open } from "./harness.mjs";
import { openB } from "./bopen.mjs";
const [mode, disc, labels, lvS = "0", nS = "600"] = process.argv.slice(2);
const level = +lvS, N = +nS;
let hooks;
const onSession = (h) => { hooks = h; };
const M = mode === "master" ? await open({ disc, labels, level, onSession }) : await openB({ level, disc, labels, onSession });
const cpu = M.cpu, A = M.A;
const poke = (a, x) => (mode === "master" ? M.wr(a, x) : M.bank(7, () => cpu.writemem(a, x)));
const peek = (a) => (mode === "master" ? M.rd(a) : M.bank(7, () => cpu.readmem(a)));
let porta = 0, out = [];
const orig = cpu.writemem.bind(cpu);
cpu.writemem = function (addr, b) {
  addr &= 0xffff;
  if (addr === 0xfe4f || addr === 0xfe41) porta = b;
  else if (addr === 0xfe40 && (b & 15) === 0) out.push(porta);
  return orig(addr, b);
};
let seed = 7;
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed >> 16; };
const log = [];
let keys = 0;
for (let f = 0; f < N; f++) {
  if (f % 8 === 0) keys = [0, 1, 2, 4, 8, 16, 2, 2 | 4, 1 | 4, 8][rnd() % 10];
  poke(A.keys, keys);
  out = [];
  await (mode === "master" ? M.runTo(A.frame_top) : M.runTo(A.frame_top, 7));
  log.push([f, out]);
}
if (process.env.EXIT) {
  poke(A.px, peek(A.exitx)); poke(A.px + 1, peek(A.exitx + 1));
  poke(A.py, peek(A.exity)); poke(A.py + 1, peek(A.exity + 1));
  for (let t = 0; t < 200; t++) {           // 200 x 40000 cycles: 4 s
    out = [];
    await M.s.runFor(40000);
    log.push([`t${t}`, out]);
  }
}
const vol = [15, 15, 15, 15];
let starts = 0, writes = 0;
for (const [f, bytes] of log) {
  if (!bytes.length) continue;
  writes += bytes.length;
  const d = [];
  for (const b of bytes) {
    if (b & 0x80) {
      const ch = (b >> 5) & 3;
      if (b & 0x10) { const v = b & 15; if (vol[ch] === 15 && v < 15) starts++; vol[ch] = v; d.push(`v${ch}=${15 - v}`); }
      else d.push(`t${ch}:${(b & 15).toString(16)}`);
    } else d.push(`+${b.toString(16)}`);
  }
  if (process.env.V) console.log(f, d.join(" "));
}
console.log(`${mode} L${level}: ${writes} chip bytes, ${starts} voice starts over ${log.length} steps; last volumes ${vol.join(",")}`);
process.exit(0);
