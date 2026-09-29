// Which stars to bake (tools/assets.py, NIBSPR): play each level file with bwork2.mjs's
// seeded key script, find the frames whose work misses the peg (3 vsyncs less the
// interrupt), and charge every masked star drawn in them its draw and erase cycles.
// Writes tools/starbake.json: by level file, the vsync's usable cycles V and every frame
// that misses the peg with a star in it: its work and each star's tile and cycles --
// what assets.py needs to choose the stars that save the most vsyncs.
//   node test/starplan.mjs [frames=600] [seeds=1,2] [machine=modelb]
import { openB } from "./bopen.mjs";
import { open } from "./harness.mjs";
import { writeFileSync } from "node:fs";
const [fr = "600", sd = "1,2", machine = "modelb"] = process.argv.slice(2);
const MASKSTAR = (i) => i >= 34 && i <= 39;
const plan = {}, report = [];
for (let lv = 0; lv < 16; lv++) {
  const cost = new Map(), kept = []; let miss = 0, total = 0, lvV = 0, lost = 0;
  for (const seed of sd.split(",").map(Number)) {
    let cpu, A, step, wr, cyc;
    if (machine === "master") { const H = await open({ disc: "build/cleo.ssd", labels: "build/master/labels.txt", level: lv }); cpu = H.cpu; A = H.A; step = () => H.runTo(A.frame_top); wr = (a, v) => H.wr(a, v); cyc = () => H.cyc(); }
    else { const B = await openB({ level: lv, ...(process.env.SDISC ? { disc: process.env.SDISC, labels: process.env.SLABELS } : {}) }); cpu = B.cpu; A = B.A; step = () => B.runTo(A.frame_top, 7); wr = (a, v) => B.bank(7, () => cpu.writemem(a, v)); cyc = B.cyc; }
    const ret = (sp) => (cpu.readmem(0x101 + sp) | cpu.readmem(0x102 + sp) << 8) + 1;
    let isrAt = -1, lastC = 0, lastPc = -1, t0 = -1, work = 0, isrTot = 0, c0 = cyc();
    let dRet = -1, dKey = null, dC = 0, eRet = -1, cbRet = -1, cbKey = null, cbC = 0, fr_ = [];
    const WF0 = A.wait_flip, WF1 = A.wait_flip + 4;
    const h = cpu.debugInstruction.add((pc, op) => {
      const now = cyc(), d = now - lastC;
      if (isrAt < 0 && lastPc >= 0 && t0 >= 0 && !(lastPc >= WF0 && lastPc <= WF1)) { work += d; if (dRet >= 0) dC += d; if (cbRet >= 0) cbC += d; }
      lastPc = pc; lastC = now;
      if (pc === A.irq_handler) { isrAt = now; lastPc = -1; return false; }
      if (isrAt >= 0) { if (op === 0x40) { isrTot += now + 6 - isrAt; isrAt = -1; lastPc = -1; } return false; }
      if (pc === A.frame_top) { t0 = now; work = 0; fr_ = []; }
      else if (pc === A.render_done && t0 >= 0) { total++; frames.push([work, fr_]); t0 = -1; }
      if (pc === A.drawsprite && dRet < 0) { dRet = ret(cpu.s); dC = 0; dKey = MASKSTAR(cpu.a) ? `${(cpu.readmem(A.spx) | cpu.readmem(A.spx + 1) << 8) >> 3},${(cpu.readmem(A.spy) | cpu.readmem(A.spy + 1) << 8) >> 3}` : null; }
      else if (pc === dRet) { if (dKey) fr_.push([dKey, dC]); dRet = -1; }
      if (pc === A.erase_old && eRet < 0) eRet = ret(cpu.s); else if (pc === eRet) eRet = -1;
      if (eRet >= 0 && pc === A.callbank && cbRet < 0) { cbRet = ret(cpu.s); cbC = 0; const rp = cpu.readmem(A.rp) | cpu.readmem(A.rp + 1) << 8; const rd = (o) => machine === "master" ? cpu.readmem(rp + o) : cpu.readmem(rp + o);
        const id = rd(0); cbKey = MASKSTAR(id) ? `${(rd(1) | rd(2) << 8) >> 3},${(rd(3) | rd(4) << 8) >> 3}` : null; }
      else if (pc === cbRet) { if (cbKey) fr_.push([cbKey, cbC]); cbRet = -1; }
      return false;
    });
    const frames = [];
    let rng = seed >>> 0; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
    let keys = 0, hold = 0;
    for (let f = 0; f < +fr; f++) {
      if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8][rnd() % 9]; hold = 4 + rnd() % 40; }
      wr(A.keys, keys); wr(A.health, 3);        // (kept alive: the walk stays in the level)
      try { await step(); } catch (e) { break; } // (the level ended: what was measured stands)
    }
    h.remove();
    const isrV = isrTot / ((cyc() - c0) / 40000), V = 40000 - isrV, budget = 3 * V;
    lvV = V;
    for (const [w, list] of frames) {
      if (w > budget) { miss++; lost += Math.ceil(w / V) - 3; }
      const sum = list.reduce((a, [, c]) => a + c, 0);
      if (w > budget && list.length) {          // a frame a star could bring nearer the peg
        const per = new Map(); for (const [k, c] of list) per.set(k, (per.get(k) || 0) + c);
        kept.push([Math.round(w), [...per].map(([k, c]) => [...k.split(",").map(Number), Math.round(c)])]);
        for (const [k, c] of per) cost.set(k, (cost.get(k) || 0) + c);
      }
    }
  }
  const ranked = [...cost].sort((a, b) => b[1] - a[1]);
  plan[lv] = { V: Math.round(lvV), frames: kept };
  report.push(`L${lv}: ${miss} of ${total} frames miss the peg (${lost} vsyncs lost); stars in them: ${ranked.slice(0, 8).map(([k, c]) => `(${k}) ${Math.round(c)}`).join(" ") || "none"}`);
  console.log(report[report.length - 1]);
}
if (!process.env.NOWRITE) writeFileSync("tools/starbake.json", JSON.stringify(plan));
process.exit(0);
