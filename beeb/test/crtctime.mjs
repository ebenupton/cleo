// Where every CRTC register write (and, on the Master, every ACCCON write) lands in
// the frame: for each store to $FE01 (or $FE34, or the palette's $FE21: register 21), the register, the value and the
// 6845's position when the store happens -- row, scanline, character -- over N frames
// of the usual key script.  Two builds' logs, compared write by write, show whether
// a change to the interrupt handler moved the chain's timing: the rupture's registers
// have deadlines within the first scanline or two of a section.
//   node test/crtctime.mjs master|modelb <disc> <labels> [level=0] [frames=60] > log
//   node test/crtctime.mjs cmp <logA> <logB>
import { open } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { readFileSync } from "node:fs";

const [mode, a1, a2, lvS = "0", nS = "60"] = process.argv.slice(2);
if (mode === "cmp") {
  const rd = (f) => readFileSync(f, "utf8").trim().split("\n").filter((l) => /^[0-9 ]+$/.test(l)).map((l) => l.split(" ").map(Number));
  const A = rd(a1), B = rd(a2);
  let worst = 0, where = "", diffs = 0;
  const hist = new Map();
  if (A.length !== B.length) console.log(`write counts differ: ${A.length} vs ${B.length}`);
  for (let i = 0; i < Math.min(A.length, B.length); i++) {
    const [fa, ra, va, vca, sca, hca] = A[i], [fb, rb, vb, vcb, scb, hcb] = B[i];
    if (fa !== fb || ra !== rb || va !== vb || vca !== vcb || sca !== scb) {
      if (++diffs <= 5) console.log(`write ${i}: ${A[i].join(" ")}  vs  ${B[i].join(" ")}`);
      continue;
    }
    const d = hcb - hca;
    hist.set(d, (hist.get(d) ?? 0) + 1);
    if (Math.abs(d) > Math.abs(worst)) { worst = d; where = `write ${i} (frame ${fa}, R${ra} row ${vca} line ${sca})`; }
  }
  console.log(`${Math.min(A.length, B.length)} writes; ${diffs} differ in register, value or line; char shift by count: ${[...hist].sort((p, q) => p[0] - q[0]).map(([d, n]) => `${d}:${n}`).join(" ")}; worst ${worst} at ${where}`);
  process.exit(diffs ? 1 : 0);
}
const disc = a1, labels = a2, level = +lvS, frames = +nS;
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KK = (c) => ({ s: 0, r: 2, l: 1, j: 4 })[c] ?? 0;
const M = mode === "master" ? await open({ disc, labels, level }) : await openB({ level, disc, labels });
const cpu = M.cpu, A = M.A, v = (M.s?._video) ?? cpu.video;
const poke = (a, x) => (mode === "master" ? M.wr(a, x) : M.bank(7, () => cpu.writemem(a, x)));
let idx = 0, frame = 0, on = false;
const out = [];
const orig = cpu.writemem.bind(cpu);
cpu.writemem = function (addr, b) {
  addr &= 0xffff;
  if (on) {
    if (addr === 0xfe00) idx = b & 31;
    else if (addr === 0xfe01) out.push(`${frame} ${idx} ${b} ${v.vertCounter} ${v.scanlineCounter} ${v.horizCounter}`);
    else if (mode === "master" && addr === 0xfe34) out.push(`${frame} 99 ${b & 1} ${v.vertCounter} ${v.scanlineCounter} ${v.horizCounter}`);
    else if (addr === 0xfe21) out.push(`${frame} 21 ${b} ${v.vertCounter} ${v.scanlineCounter} ${v.horizCounter}`);
  }
  return orig(addr, b);
};
for (let f = 0; f < frames; f++) {
  poke(A.keys, KK(PAT[f % PAT.length])); poke(A.hurt, 1); poke(A.health, 3);
  on = true; frame = f;
  await (mode === "master" ? M.runTo(A.frame_top) : M.runTo(A.frame_top, 7));
}
console.log(out.join("\n"));
process.exit(0);
