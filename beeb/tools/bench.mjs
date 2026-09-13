// Cleo render benchmark.   node tools/bench.mjs <level 0-7> [out.json] [disc] [labels]
//
// Measures render WORK -- cycles from select_backbuf to render_done, which excludes the
// wait_flip idle spin render_frame opens with -- at the fixed landed positions in
// bench_locations.json, under a jump (vertical scroll) and under a full-speed run
// (horizontal scroll).  Run all eight levels and combine to score.
//
// This is driven by tools/harness.mjs, which breaks exactly at the frame_top label
// rather than polling cycles.  The previous version of this file advanced the machine
// in 20000-cycle steps and checked a frame counter afterwards, so every wait overshot
// by a variable amount and every key write landed at an arbitrary point inside a frame;
// whether the logic saw a key this frame or the next then depended on sub-frame phase,
// hence on absolute timing, hence on code size.  One frame of drift at the first
// location moved the world for every location after it, and the tool reported
// differences of up to 15000 cycles between builds differing only in an 18-byte cold
// path.  See tools/benchrepro.sh for the demonstration that this version does not.
//
// Three measurement traps it also avoids, each of which silently skewed earlier runs:
//   1. wait_flip is a 6-23k idle spin that flips with buffer parity -- not work, so the
//      window starts at select_backbuf.
//   2. The player spawns invulnerable and while hurt is drawn only every 4th frame, so
//      a naive measurement sees a 3/4-absent player.  harness.mjs patches the blink out
//      and holds hurt/health, because a hit zeroes 'control' and changes how many
//      frames a run takes.
//   3. The two buffers cost up to 15% different, so a single frame is a coin flip.
//      Average an even number of frames.
//
// Each sample carries a fingerprint of every piece of state the renderer reads.  Two
// builds are only comparable at the locations where those agree -- tools/benchcmp.mjs
// checks that rather than assuming it.  Cycle counts are NOT expected to be identical
// across builds even so: a taken 6502 branch costs an extra cycle when its target is on
// another page, so moving code genuinely changes the count by a tenth of a percent.
import { writeFileSync, readFileSync } from "node:fs";
import path from "node:path";
import { open } from "./harness.mjs";

const lv = parseInt(process.argv[2]);
const out = process.argv[3] || `build/bench_L${lv}.json`;
const disc = process.argv[4] || "build/cleo.ssd";
const labels = process.argv[5] || "build/labels.txt";
const HERE = path.dirname(new URL(import.meta.url).pathname);
const LOCS = JSON.parse(readFileSync(path.join(HERE, "bench_locations.json"), "utf8")).filter((l) => l.lv === lv);

const AVG = 4;        // even: two frames per buffer
const ACCEL = 48;     // fixed frame count, comfortably past the 766-unit vx cap
const WARM = 30;

const H = await open({ disc, labels, level: lv });
const A = H.A, m = H.meter;
let deaths = 0;

async function frame(keys) {
  H.wr(A.keys, keys); H.wr(A.hurt, 1); H.wr(A.health, 3);   // a hit zeroes 'control'
  const before = m.frames;
  await H.runTo(A.frame_top);
  // 'exiting' means the level is ending (died, or reached the exit): the protocol has
  // left the state it was measuring, so say so rather than average the wreckage in
  if (H.rd(A.exiting)) { deaths++; return null; }
  if (m.frames === before) return null;
  return { work: m.work, isr: m.isr, isrCount: m.isrCount, instrs: m.instrs };
}
async function frames(keys, n) { const r = []; for (let i = 0; i < n; i++) r.push(await frame(keys)); return r; }
function place(px, py) { H.wr16(A.px, px); H.wr16(A.py, py); H.wr16(A.vx, 0); H.wr16(A.vy, 0); }
const avg = (a, k) => { a = a.filter((x) => x); return a.length ? Math.round(a.reduce((x, y) => x + y[k], 0) / a.length) : null; };

await frames(0, WARM);

const samples = [];
for (const loc of LOCS) {
  place(loc.px, loc.py); await frames(0, 3);
  const fp0 = H.fingerprint().fp, f0 = H.rd16(A.frame), d0 = deaths;
  const jc = (await frames(4, 1 + AVG)).slice(1);
  place(loc.px, loc.py); await frames(0, 3);
  // both directions for the same fixed frame count, keep the one she gets going in;
  // "whichever has room" needs a variable-length retry, i.e. exactly the
  // state-dependent wait this protocol exists to remove
  let vx = 0, run = null, runIsr = null, runI = null, fpRun = null;
  for (const dir of [2, 1]) {
    await frames(dir, ACCEL);
    const v = Math.abs(H.rds16(A.vx)), fp = H.fingerprint().fp;
    const c = await frames(dir, AVG);
    if (v > vx) { vx = v; run = avg(c, "work"); runIsr = avg(c, "isr"); runI = avg(c, "instrs"); fpRun = fp; }
    place(loc.px, loc.py); await frames(0, 3);
  }
  samples.push({ px: loc.px, py: loc.py, f0, fp0, fpRun, vx,
                 jump: avg(jc, "work"), jumpIsr: avg(jc, "isr"), jumpI: avg(jc, "instrs"),
                 run, runIsr, runI, ...(deaths > d0 ? { died: deaths - d0 } : {}) });
}
writeFileSync(out, JSON.stringify({ lv, deaths,
  method: "frame-exact (harness.mjs); work=select_backbuf..render_done; ISR separated; scene fingerprinted",
  samples }, null, 1));
const med = (a) => { a = a.filter((x) => x != null).sort((x, y) => x - y); return a.length ? a[a.length >> 1] : 0; };
console.log(`L${lv}: ${samples.length} locations; jump med=${med(samples.map((x) => x.jump))} run med=${med(samples.map((x) => x.run))} cy` +
            (deaths ? `  (WARNING: ${deaths} frames with 'exiting' set)` : ""));
