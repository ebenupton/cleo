// Where does drawrect's work come from?   node tools/drawcost.mjs [level] [frames]
//
// drawrect is ~46% of a frame, but that is the sum of three unrelated jobs: the columns
// and rows a scroll exposes, the map redrawn under last frame's sprites, and the
// animated tiles.  Which one dominates decides whether there is an algorithmic win left
// or only cycles to shave, so measure it rather than guess.
//
// Attributes each drawrect call (chars = rc_w * rc_h) to whichever of scroll_validate,
// erase_old or draw_dirty is on the stack, and counts the cycles each spends.
import { open } from "./harness.mjs";
const lv = parseInt(process.argv[2] ?? "0"), N = parseInt(process.argv[3] ?? "60");
const H = await open({ disc: "build/cleo.ssd", labels: "build/labels.txt", level: lv });
const A = H.A, cpu = H.cpu;
const PHASES = ["scroll_validate", "erase_old", "draw_dirty", "draw_sprites"];
const stat = {}; for (const p of PHASES) stat[p] = { chars: 0, calls: 0, cy: 0 };
stat.other = { chars: 0, calls: 0, cy: 0 };
let phase = "other", phaseAt = 0, frames = 0, drawrectCy = 0, drIn = 0;
const entry = {}; for (const p of PHASES) if (A[p] !== undefined) entry[A[p]] = p;
cpu.debugInstruction.add((pc, op) => {
  if (entry[pc] !== undefined) { phase = entry[pc]; phaseAt = H.cyc(); }
  else if (pc === A.drawrect) {
    const w = H.rd(A.rc_w), h = H.rd(A.rc_h);
    stat[phase].chars += w * h; stat[phase].calls++; drIn = H.cyc();
  } else if (pc === A.render_done) {
    frames++; phase = "other";
  }
  return false;
});
// cycles per phase: time from the phase entry to the next phase entry is close enough
// for apportioning, and the render is a fixed sequence of them
let last = null, lastAt = 0;
cpu.debugInstruction.add((pc) => {
  if (entry[pc] !== undefined || pc === A.render_done) {
    if (last) stat[last].cy += H.cyc() - lastAt;
    last = entry[pc] ?? null; lastAt = H.cyc();
  }
  return false;
});
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjssllllllllllllllllllllllljljljss";
const K = { s: 0, r: 2, l: 1, j: 4, rj: 6, lj: 5 };
for (let f = 0; f < N; f++) {
  H.wr(A.keys, K[PAT[f % PAT.length]] ?? 0); H.wr(A.hurt, 1); H.wr(A.health, 3);
  await H.runTo(A.frame_top);
}
console.log(`L${lv}: ${frames} renders`);
const tot = Object.values(stat).reduce((n, s) => n + s.chars, 0);
for (const [k, s] of Object.entries(stat)) {
  if (!s.calls && !s.cy) continue;
  console.log(`  ${k.padEnd(16)} ${(s.chars / frames).toFixed(1).padStart(7)} chars/render  ${(100 * s.chars / (tot || 1)).toFixed(1).padStart(5)}%  ${(s.calls / frames).toFixed(1).padStart(5)} calls  ${(s.cy / frames / 1000).toFixed(1).padStart(6)}K cy/render`);
}
console.log(`  total drawrect chars/render: ${(tot / frames).toFixed(1)} (= ${(tot / frames * 8 / 1024).toFixed(1)} KB copied)`);
