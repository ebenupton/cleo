// Cleo render benchmark.   node test/bench.mjs <level 0-15> [out.json] [disc] [labels]
// (disc: build/cleo.ssd; labels: build/master/labels.txt -- the Master)
//
// Measures render WORK -- the cycles from the instruction after render_frame's flip
// spin to render_done (harness.mjs installMeter: the spin, wait_flip, is idle; the
// interrupt handler's cycles are taken out and reported separately) -- at the fixed
// positions in bench_locations.json ({lv, px, py}) for the level, under a jump
// (keys = UP, 1 + AVG frames, the first dropped) and under a full-speed run (RIGHT then
// LEFT for ACCEL frames each, then AVG frames measured; the direction she got going
// in, the larger |vx|, is kept).  AVG = 4 is even so each buffer is measured twice
// (they cost differently); ACCEL = 48 is past the top speed (KNOCK_VX = 768) at
// ACC_GROUND = 72 a step.  Run all the levels and combine to score.
//
// The machine is harness.mjs open (a jsbeeb Master at the level's first frame_top);
// every wait is a break exactly at frame_top, never a cycle poll.  Polling (20000-cycle
// steps, a frame counter checked afterwards) lets every wait overshoot by a variable
// amount and every key write land at an arbitrary point inside a frame; whether the
// logic sees a key this frame or the next then depends on sub-frame phase, hence on
// absolute timing, hence on code size, and one frame of drift at the first location
// moves the world for every location after it.
//
// Each frame: keys, hurt = 1 and health = 3 are written at the break (hurt = 1 keeps
// her invulnerable -- a hit zeroes 'control', which changes how many frames a run
// takes; health = 3 keeps her alive), then the run to the next frame_top.  A frame with
// 'exiting' set (the level ended) is dropped and counted in 'deaths'.  harness.mjs's
// patchBlink turns the hurt flashing off where its byte pattern matches (open warns
// when it matches no site: quiet = false).
//
// Each sample carries a fingerprint of every piece of state the renderer reads (fp0
// before the jump, fpRun before the measured run).  Two builds are only comparable at
// the locations where those agree -- test/benchcmp.mjs checks that rather than
// assuming it.  Cycle counts are NOT expected to be identical across builds even so: a
// taken 6502 branch costs an extra cycle when its target is on another page, so moving
// code genuinely changes the count by a tenth of a percent.
//
// Output: out.json {lv, deaths, method, samples: [{px, py, f0 (the frame counter at
// the start), fp0, fpRun, vx, jump, jumpIsr, jumpI (instructions), jumpL (logic
// cycles, frame_top..render_frame), jumpLI, run, runIsr, runI, runL, runLI, died?}]}
// (null where every frame was dropped) and one console line: locations and the
// medians of jump and run work.
import { writeFileSync, readFileSync } from "node:fs";
import path from "node:path";
import { open } from "./harness.mjs";

const lv = parseInt(process.argv[2]);
const out = process.argv[3] || `build/bench_L${lv}.json`;
const disc = process.argv[4] || "build/cleo.ssd";
const labels = process.argv[5] || "build/master/labels.txt";
const HERE = path.dirname(new URL(import.meta.url).pathname);
const LOCS = JSON.parse(readFileSync(path.join(HERE, "bench_locations.json"), "utf8")).filter((l) => l.lv === lv);

const AVG = 4;        // even: two frames per buffer
const ACCEL = 48;     // fixed frame count, well past the top speed (768 at 72 a step)
const WARM = 30;      // frames idle after the open before the first location

const H = await open({ disc, labels, level: lv });
const A = H.A, m = H.meter;
let deaths = 0;

async function frame(keys) {
  H.wr(A.keys, keys); H.wr(A.hurt, 1); H.wr(A.health, 3);   // invulnerable and alive: a hit zeroes 'control'
  const before = m.frames;
  await H.runTo(A.frame_top);
  // 'exiting' means the level is ending (died, or reached the exit): the protocol has
  // left the state it was measuring, so drop the frame rather than average the wreckage in
  if (H.rd(A.exiting)) { deaths++; return null; }
  if (m.frames === before) return null;
  return { work: m.work, isr: m.isr, isrCount: m.isrCount, instrs: m.instrs, logic: m.logic, logicI: m.logicI };
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
  let vx = 0, run = null, runIsr = null, runI = null, runL = null, runLI = null, fpRun = null;
  for (const dir of [2, 1]) {
    await frames(dir, ACCEL);
    const v = Math.abs(H.rds16(A.vx)), fp = H.fingerprint().fp;
    const c = await frames(dir, AVG);
    if (v > vx) { vx = v; run = avg(c, "work"); runIsr = avg(c, "isr"); runI = avg(c, "instrs");
                  runL = avg(c, "logic"); runLI = avg(c, "logicI"); fpRun = fp; }
    place(loc.px, loc.py); await frames(0, 3);
  }
  samples.push({ px: loc.px, py: loc.py, f0, fp0, fpRun, vx,
                 jump: avg(jc, "work"), jumpIsr: avg(jc, "isr"), jumpI: avg(jc, "instrs"),
                 jumpL: avg(jc, "logic"), jumpLI: avg(jc, "logicI"), runL, runLI,
                 run, runIsr, runI, ...(deaths > d0 ? { died: deaths - d0 } : {}) });
}
writeFileSync(out, JSON.stringify({ lv, deaths,
  method: "frame-exact (harness.mjs); work=after render_frame's spin..render_done; ISR separated; scene fingerprinted",
  samples }, null, 1));
const med = (a) => { a = a.filter((x) => x != null).sort((x, y) => x - y); return a.length ? a[a.length >> 1] : 0; };
console.log(`L${lv}: ${samples.length} locations; jump med=${med(samples.map((x) => x.jump))} run med=${med(samples.map((x) => x.run))} cy` +
            (deaths ? `  (WARNING: ${deaths} frames with 'exiting' set)` : ""));
