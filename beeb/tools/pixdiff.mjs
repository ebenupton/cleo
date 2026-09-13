// Pixel-exact A/B of two builds over a scripted run.
//   node tools/pixdiff.mjs <discA> <labelsA> <discB> <labelsB> <level> [frames] [keyscript]
//
// Steps both machines in lockstep on frame boundaries (tools/harness.mjs) and compares
// the whole painted frame -- including the status bar, which the window-only capture in
// fbdiff.mjs leaves out.  Reports the first differing frame and how many pixels differ,
// because "how many" separates a real regression from a one-pixel placement artifact.
//
// The default key script exercises a stand, a run each way, jumps and a landing, which
// between them drive every scroll direction, the partial top row, the mirror line, the
// sprite erase/keep paths and the HUD.
//
// IT REPORTS TWO THINGS, and the difference between them matters more than either.
// BUFFER is the screen RAM the two builds drew: if that differs, one of them draws the
// wrong pixels and the change is broken.  DISPLAY is the painted frame: it can differ
// while the buffers agree, because the CRTC rupture chain is programmed at the end of
// the render and re-phases when the render's duration changes.  Measured: perturbations
// worth up to ~500 cycles never move a pixel over 250 frames on three levels, but a
// change that saved ~5000 on the frames that redraw the HUD moved the display on 2
// frames of 100 with the buffers bit-identical.  So DISPLAY-only differences are a
// re-phasing of a pre-existing real-time race, not a drawing bug -- judge a change on
// BUFFER, and treat a DISPLAY difference as something to understand, not to fear.
import { open } from "./harness.mjs";

const [dA, lA, dB, lB, lvS, nS, script] = process.argv.slice(2);
const lv = parseInt(lvS ?? "0"), N = parseInt(nS ?? "120");
const KEYS = { s: 0, r: 2, l: 1, j: 4, rj: 6, lj: 5 };
// one character per frame, cycled: stand, run right, jump-right, run left, jump-left
const PAT = script ?? "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";

const A = await open({ disc: dA, labels: lA, level: lv });
const B = await open({ disc: dB, labels: lB, level: lv });
const fbA = A.s._completeFb8, fbB = B.s._completeFb8;

const W = 1024;                       // jsbeeb framebuffer width
function diffPixels() {
  let n = 0, x0 = 1e9, x1 = -1, y0 = 1e9, y1 = -1;
  for (let i = 0, p = 0; i < fbA.length; i += 4, p++)
    if (fbA[i] !== fbB[i] || fbA[i + 1] !== fbB[i + 1] || fbA[i + 2] !== fbB[i + 2]) {
      n++; const x = p % W, y = (p / W) | 0;
      if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
    }
  return { n, box: n ? `x ${x0}-${x1}, y ${y0}-${y1}` : "" };
}
async function step(H, keys) {
  H.wr(H.A.keys, keys); H.wr(H.A.hurt, 1); H.wr(H.A.health, 3);
  await H.runTo(H.A.frame_top);
}

// screen RAM as the CPU currently sees it: the buffer just drawn.  Buffers alternate,
// so over any run of frames both are covered.
function diffBuffer() {
  let n = 0;
  for (let a = 0x3000; a < 0x8000; a++) if (A.rd(a) !== B.rd(a)) n++;
  return n;
}
let worst = 0, firstBad = -1, bad = 0, bufBad = 0, bufFirst = -1, bufWorst = 0;
for (let f = 0; f < N; f++) {
  const k = KEYS[PAT[f % PAT.length]] ?? 0;
  await step(A, k); await step(B, k);
  const db = diffBuffer();
  if (db) { bufBad++; if (bufFirst < 0) bufFirst = f; bufWorst = Math.max(bufWorst, db);
            if (bufBad <= 3) console.log(`  frame ${f}: BUFFER differs, ${db} bytes`); }
  const { n: d, box } = diffPixels();
  if (d) { bad++; if (firstBad < 0) firstBad = f; worst = Math.max(worst, d);
           if (bad <= 4) console.log(`  frame ${f}: ${d} px differ (${box})`); }
  // the scene fingerprint should also agree; if it does not, the builds differ in logic
  if (A.fingerprint().fp !== B.fingerprint().fp) {
    console.log(`frame ${f}: SCENE fingerprints differ -- the builds do not behave alike`);
    process.exit(1);
  }
}
const total = fbA.length / 4;
console.log(`L${lv}: BUFFER ${bufBad ? `DIFFERS on ${bufBad}/${N} frames (first ${bufFirst}, worst ${bufWorst} bytes) -- THIS IS A BUG` : `identical over ${N} frames`}`);
console.log(`L${lv}: DISPLAY ${bad ? `differs on ${bad}/${N} frames (first ${firstBad}, worst ${worst}/${total} px)${bufBad ? "" : " -- buffers agree, so this is rupture-chain re-phasing"}` : `identical over ${N} frames`}`);
process.exit(bufBad ? 1 : 0);
