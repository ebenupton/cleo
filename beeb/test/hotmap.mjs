// Where a level misses its vsync peg: drive the window across the map diagonally, 45
// degrees up and to the right at Cleo's top speed (KNOCK_VX = 768: 3 game pixels a
// step, two steps a frame, so 6 each way a frame), starting at regular intervals
// along the left and bottom edges, and record every frame's window, work and whether
// it missed.  Cleo is placed on the path at each frame_top (px, py written, vx/vy
// zeroed; the camera follows her: logic.s game_frame), kept unhurt and alive (hurt = 1,
// health = 3, keys = 0); enemies run as ever.  The first SKIP = 3 frames of a run are
// not recorded (a jump to a new start is a full redraw).  Work is starplan.mjs's: the
// cycles from frame_top to render_done, the interrupt handler's (irq_handler to its
// RTI, plus the RTI's 6) and the flip wait's spin (the five bytes from wait_flip) left
// out.  A frame misses when its work is over three vsyncs' usable cycles, V = 40000 -
// the interrupt's cycles a vsync measured over the run.  tools/hotmap.py draws the
// result over the map.  Opened by harness.mjs open (Master) or bopen.mjs openB (Model
// B); a run ends at the map's edge or when a frame_top is not reached (the level
// ended).
//   node test/hotmap.mjs modelb|master <disc> <labels> <level> <out.json> [step=48]
// Coordinates are game pixels (maxwx/maxwy + the window: 160 wide, VIS = 120 tall on
// the Master's 30 rows, 84 on the Model B's 21).
// Output: out.json {machine, level, mapw, maph, vis, V, speed, step, starts: [[x, y]],
// frames: [[px, py, wx, wy, work]]} and one line: runs, frames, misses (%), V.
import { openB } from "./bopen.mjs";
import { open } from "./harness.mjs";
import { writeFileSync } from "node:fs";

const [machine, disc, labels, lvS, out, stepS = "48"] = process.argv.slice(2);
const level = +lvS, STEP = +stepS, SPEED = 6, SKIP = 3;     // SKIP: frames after a jump to a start (a full redraw)
let cpu, A, step, wr, rd, cyc;
if (machine === "master") { const H = await open({ disc, labels, level }); cpu = H.cpu; A = H.A; step = () => H.runTo(A.frame_top); wr = (a, v) => H.wr(a, v); rd = (a) => cpu.readmem(a); cyc = () => H.cyc(); }
else { const B = await openB({ level, disc, labels }); cpu = B.cpu; A = B.A; step = () => B.runTo(A.frame_top, 7, 400000); wr = (a, v) => B.bank(7, () => cpu.writemem(a, v)); rd = (a) => B.bank(7, () => cpu.readmem(a)); cyc = B.cyc; }
const r16 = (a) => rd(a) | rd(a + 1) << 8;
const mapw = (r16(A.maxwx) + 159) | 0, VIS = machine === "master" ? 120 : 84;   // maxwx = mapw - 160; maxwy = maph - VIS
const maph = (r16(A.maxwy) + VIS) | 0;
// ---- the work of each frame, as starplan.mjs counts it (the spin and the ISR out)
let isrAt = -1, lastC = 0, lastPc = -1, t0 = -1, work = 0, isrTot = 0, done = null;
const c0 = cyc(), WF0 = A.wait_flip, WF1 = A.wait_flip + 4;
cpu.debugInstruction.add((pc, op) => {
  const now = cyc(), d = now - lastC;
  if (isrAt < 0 && lastPc >= 0 && t0 >= 0 && !(lastPc >= WF0 && lastPc <= WF1)) work += d;
  lastPc = pc; lastC = now;
  if (pc === A.irq_handler) { isrAt = now; lastPc = -1; return false; }
  if (isrAt >= 0) { if (op === 0x40) { isrTot += now + 6 - isrAt; isrAt = -1; lastPc = -1; } return false; }
  if (pc === A.frame_top) { t0 = now; work = 0; }
  else if (pc === A.render_done && t0 >= 0) { done = work; t0 = -1; }
  return false;
});
// ---- the runs: from the left edge every STEP px down, from the bottom edge every STEP
// px across; each goes up and right SPEED a frame until the right or top edge
const starts = [];
for (let y = maph - 8; y >= 24; y -= STEP) starts.push([16, y]);
for (let x = 16 + STEP; x < mapw - 16; x += STEP) starts.push([x, maph - 8]);
const frames = [];
for (const [x0, y0] of starts) {
  for (let t = 0; ; t++) {
    const px = x0 + SPEED * t, py = y0 - SPEED * t;
    if (px > mapw - 8 || py < 8) break;
    wr(A.px, px & 255); wr(A.px + 1, px >> 8); wr(A.py, py & 255); wr(A.py + 1, py >> 8);
    wr(A.keys, 0); wr(A.health, 3); wr(A.hurt, 1); wr(A.vx, 0); wr(A.vx + 1, 0); wr(A.vy, 0); wr(A.vy + 1, 0);
    done = null;
    try { await step(); } catch (e) { break; }
    if (t >= SKIP && done !== null) frames.push([px, py, r16(A.wx), r16(A.wy), done]);
  }
}
const isrV = isrTot / ((cyc() - c0) / 40000), V = 40000 - isrV;
const miss = frames.filter((f) => f[4] > 3 * V).length;
writeFileSync(out, JSON.stringify({ machine, level, mapw, maph, vis: VIS, V: Math.round(V), speed: SPEED, step: STEP, starts, frames }));
console.log(`${machine} L${level}: ${starts.length} runs, ${frames.length} frames, ${miss} miss the peg (${(100 * miss / frames.length).toFixed(1)}%); V ${V.toFixed(0)}`);
process.exit(0);
