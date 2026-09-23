// Lock-step differential test: the Master (a 21-row MODE 1 build, build/ref_mode1_21)
// and the Model B run the same level with the same keys at every frame_top, and the
// whole logic state -- the player, the level counters and all 16 object arrays -- is
// compared after every frame.  The first difference is reported with its frame.
//   node tools/bdiff.mjs [frames] [seed] [level 0..15]
import { findJsbeeb, loadLabels, open as openMaster } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { boardEmu } from "./bopen.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "300"), seed0 = parseInt(process.argv[3] ?? "1"), LEVEL = parseInt(process.argv[4] ?? "2");
const BEEB = "/Users/ebenupton/cleo/beeb";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));

// ---- the Master
const M = await openMaster({ disc: `${BEEB}/build/ref_mode1_21/cleo.ssd`, labels: `${BEEB}/build/ref_mode1_21/labels.txt`, level: LEVEL });
const MA = M.A, mcpu = M.cpu;
if (MA.LV_OBJST === undefined) MA.LV_OBJST = 0xb000;   // a constant on the Master (engine.s)
// ---- the Model B: booted from its disc, the title skipped and the level chosen by the
// same patches the Master harness applies (harness.mjs open), so the game's own loader
// gathers the level from the disc
const BA = loadLabels("build/labels.txt");
const bs = new MachineSession(process.env.BMODEL ?? "B-DFS1.2");
await bs.initialise(); await bs.boot(30); bs.loadDisc(path.resolve("build/cleob.ssd"));
const bcpu = bs._machine.processor;
if (process.env.BBOARD) boardEmu(bcpu, process.env.BBOARD);   // a Watford or Solidisk board (bopen.mjs)
// the Model B's banks are the lowest four sockets the boot loader finds RAM in (jsbeeb:
// 0-3, or BSWRAM="a,b,c,d" -- see bopen.mjs); bank() maps the code's 4..7 to them.
// The Master's banks are its own (the harness pages 7 itself).
const SW = process.env.BSWRAM ? process.env.BSWRAM.split(",").map(Number) : null;
if (SW) bcpu.model.swram = Array.from({ length: 16 }, (_, i) => SW.includes(i));
const P = bcpu.model.swram.map((r, i) => (r ? i : -1)).filter((i) => i >= 0).slice(0, 4);
const PB = (cpu, b) => (cpu === bcpu && b >= 4 && b <= 7 ? P[b - 4] : b);
const bank = (cpu, b, f) => { b = PB(cpu, b); const was = cpu.readmem(0xf4); cpu.writemem(0xf4, b); cpu.writemem(0xfe30, b); const r = f(); cpu.writemem(0xf4, was); cpu.writemem(0xfe30, was); return r; };
bs.keyDown(16); bs.reset(true); await bs.runFor(2_000_000); bs.keyUp(16);
async function runToB(pc, b, budget = 6000) {
  b = PB(bcpu, b);
  const h = bcpu.debugInstruction.add((p) => p === pc && bcpu.readmem(0xf4) === b);
  try { for (let i = 0; i < budget; i++) { await bs.runFor(20000); if (bcpu.pc === pc && bcpu.readmem(0xf4) === b) return; } }
  finally { h.remove(); }
  throw new Error(`B: runTo ${pc.toString(16)} timed out`);
}
await runToB(BA.title_loop, 7);
bank(bcpu, 7, () => {
  // title_loop: jsr ensure_menu / jsr t_title_menu -> both skipped, "start game"
  for (let i = 0; i < 6; i++) bcpu.writemem(BA.title_loop + i, 0xea);
  bcpu.writemem(BA.title_loop + 3, 0xa9); bcpu.writemem(BA.title_loop + 4, 0);
  let ok = false;
  for (let a = BA.level_loop; a < BA.level_loop + 24; a++)
    if (bcpu.readmem(a) === 0xa6 && bcpu.readmem(a + 1) === (BA.level & 255)) { bcpu.writemem(a, 0xa2); bcpu.writemem(a + 1, LEVEL); ok = true; break; }
  if (!ok) throw new Error("B: ldx level not found in level_loop");
});
await runToB(BA.level_init, 7, 60000);           // the disc load: seeks at DFS's step rate
bank(bcpu, 7, () => bcpu.writemem(BA.scan_keys, 0x60));
await runToB(BA.frame_top, 7);

// ---- the state each side exposes: (name, reader) -- one number or an array
const OBJN_M = 149, OBJN_B = 149, NOBJ = mcpu.readmem(MA.nobj);
const zp = ["px","py","vx","vy","anim","evframe","facing","running","firing","hurt","control","bx","by","bvx","bvy","bcnt","bactive","bounce","stars","exiting","lives","health","score","frame","wx","wy","lastkeys","gridsh"];
const sizes = { px:2,py:2,vx:2,vy:2,evframe:2,bx:2,by:2,bvx:2,bvy:2,score:2,frame:2,wx:2,wy:2 };
function state(cpu, A, objn) {
  const r16 = (a) => cpu.readmem(a) | (cpu.readmem(a + 1) << 8);
  const st = {};
  for (const n of zp) st[n] = sizes[n] === 2 ? r16(A[n]) : cpu.readmem(A[n]);
  bank(cpu, 7, () => {
    for (let k = 0; k < 16; k++) { const arr = []; for (let i = 0; i < NOBJ; i++) arr.push(cpu.readmem(A.LV_OBJST + k * objn + i)); st["O" + k] = arr.join(","); }
  });
  return st;
}
// a key script both sides get: held states for random spans (LCG on seed0)
let rng = seed0 >>> 0; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
let keys = 0, hold = 0, bad = 0;
const t0 = Date.now();
for (let f = 0; f < frames; f++) {
  if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 16, 2|16, 1|16, 8][rnd() % 10]; hold = 4 + rnd() % 40; }
  mcpu.writemem(MA.keys, keys); bcpu.writemem(BA.keys, keys);
  await M.runTo(MA.frame_top); await runToB(BA.frame_top, 7);
  const sm = state(mcpu, MA, OBJN_M), sb = state(bcpu, BA, OBJN_B);
  const diffs = Object.keys(sm).filter((k) => sm[k] !== sb[k]);
  if (diffs.length) {
    console.log(`frame ${f} (logic frame ${sm.frame}/${sb.frame}) keys=${keys}: DIFFER in ${diffs.join(" ")}`);
    for (const k of diffs.slice(0, 6)) console.log(`  ${k}: M=${String(sm[k]).slice(0, 120)}\n  ${" ".repeat(k.length)}  B=${String(sb[k]).slice(0, 120)}`);
    if (++bad >= 3) break;
  }
  if (f % 50 === 0) console.log(`frame ${f}: px=${sm.px} py=${sm.py} stars=${sm.stars} score=${sm.score} health=${sm.health} keys=${keys} (${((Date.now()-t0)/1000).toFixed(0)}s)`);
  if (sm.exiting) { console.log("level over at frame", f); break; }
}
console.log(bad ? `FAILED: ${bad} differing frames` : `OK: ${frames} frames in lock step`);
process.exit(bad ? 1 : 0);
