// Cleo render benchmark, frame-exact.   node tools/bench2.mjs <level 0-7> [out.json] [disc] [labels]
//
// Same measurement as tools/bench.mjs -- render work (select_backbuf..render_done) at
// the fixed landed positions in bench_locations.json, under a jump and under a
// full-speed run -- but driven by tools/harness.mjs, so:
//   * every wait is "run to the next frame_top", never a cycle poll;
//   * keys are written while stopped at frame_top, so a key is held for an exact
//     number of frames instead of "about that many";
//   * the ISR is measured separately and reported, not left inside the figure;
//   * each sample carries a fingerprint of the whole scene the renderer reads, so a
//     comparison between builds can be checked rather than assumed.
import { writeFileSync, readFileSync } from "node:fs";
import path from "node:path";
import { open } from "./harness.mjs";

const lv = parseInt(process.argv[2]);
const out = process.argv[3] || `build/bench2_L${lv}.json`;
const disc = process.argv[4] || "build/cleo.ssd";
const labels = process.argv[5] || "build/labels.txt";
const HERE = path.dirname(new URL(import.meta.url).pathname);
const LOCS = JSON.parse(readFileSync(path.join(HERE, "bench_locations.json"), "utf8")).filter((l) => l.lv === lv);

const AVG = 4;        // even: two frames per buffer, whose costs differ by up to 15%
const ACCEL = 48;     // fixed: comfortably past the 766-unit vx cap
const WARM = 30;

const H = await open({ disc, labels, level: lv });
const A = H.A, m = H.meter;

// one frame with `keys` held, returning the render work for it
async function frame(keys) {
  H.wr(A.keys, keys); H.wr(A.hurt, 1); H.wr(A.health, 3);   // a hit zeroes 'control'
  const before = m.frames;
  await H.runTo(A.frame_top);
  if (m.frames === before) return null;                     // no render (death screen)
  return { work: m.work, isr: m.isr, isrCount: m.isrCount };
}
async function frames(keys, n) { const r = []; for (let i = 0; i < n; i++) r.push(await frame(keys)); return r; }
function place(px, py) { H.wr16(A.px, px); H.wr16(A.py, py); H.wr16(A.vx, 0); H.wr16(A.vy, 0); }
const mean = (a) => { a = a.filter((x) => x); return a.length ? Math.round(a.reduce((x, y) => x + y.work, 0) / a.length) : null; };
const meanIsr = (a) => { a = a.filter((x) => x); return a.length ? Math.round(a.reduce((x, y) => x + y.isr, 0) / a.length) : null; };

await frames(0, WARM);

const samples = [];
for (const loc of LOCS) {
  place(loc.px, loc.py); await frames(0, 3);
  const fp0 = H.fingerprint().fp, f0 = H.rd16(A.frame);
  const jc = await frames(4, 1 + AVG);
  const jump = mean(jc.slice(1)), jumpIsr = meanIsr(jc.slice(1));
  place(loc.px, loc.py); await frames(0, 3);
  // both directions for the same fixed frame count, keep the one she gets going in;
  // "whichever has room" would need a variable-length retry, i.e. the state-dependent
  // wait this protocol exists to remove
  let vx = 0, run = null, runIsr = null, fpRun = null;
  for (const dir of [2, 1]) {
    await frames(dir, ACCEL);
    const v = Math.abs(H.rds16(A.vx)), fp = H.fingerprint().fp;
    const c = await frames(dir, AVG);
    if (v > vx) { vx = v; run = mean(c); runIsr = meanIsr(c); fpRun = fp; }
    place(loc.px, loc.py); await frames(0, 3);
  }
  samples.push({ px: loc.px, py: loc.py, f0, fp0, fpRun, vx, jump, jumpIsr, run, runIsr });
}
writeFileSync(out, JSON.stringify({ lv, method: "frame-exact; work=select_backbuf..render_done; ISR separated; scene fingerprinted", samples }, null, 1));
const med = (a) => { a = a.filter((x) => x != null).sort((x, y) => x - y); return a.length ? a[a.length >> 1] : 0; };
console.log(`L${lv}: ${samples.length} locations; jump med=${med(samples.map((x) => x.jump))} run med=${med(samples.map((x) => x.run))} cy`);
