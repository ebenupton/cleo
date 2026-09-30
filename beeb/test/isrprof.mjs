// Where the interrupt's time goes: every instruction executed between the handler's
// entry and its RTI, its cycles by source line and by routine (the nearest global
// label), over N frames of bwork2.mjs's key script; and interrupts a vsync by kind.
//   node test/isrprof.mjs master|modelb <disc> <labels> [level=0] [frames=200] [rows=30]
import { open, dbgPath, loadLabels } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { readFileSync } from "node:fs";
const [machine, disc, labels, lvA = "0", frA = "200", rowsA = "30"] = process.argv.slice(2);
const level = +lvA, frames = +frA, rows = +rowsA;
// ---- the build's lines: address -> "file:line" per segment (so per bank), from the spans
const dbgFile = dbgPath(labels);
const dbg = readFileSync(dbgFile, "utf8");
const files = new Map(), segs = new Map(), spans = new Map();
for (const m of dbg.matchAll(/^file\tid=(\d+),name="([^"]+)"/gm)) files.set(m[1], m[2].replace(/^src\//, ""));
for (const m of dbg.matchAll(/^seg\tid=(\d+),name="(\w+)",start=0x([0-9A-F]+)/gm)) segs.set(m[1], { name: m[2], start: parseInt(m[3], 16) });
for (const m of dbg.matchAll(/^span\tid=(\d+),seg=(\d+),start=(\d+),size=(\d+)/gm)) spans.set(m[1], { seg: m[2], start: +m[3], size: +m[4] });
const BANKSEG = { SPR4CODE: 4, SPR4TAB: 4, SPR5TAB: 5, SPR4SWAP: 4, SPR4MASK: 4, SPR5CODE: 5, MAP5CODE: 5, SPR5MASK: 5, TIL6ENT: 6, TILCODE: 6, MNUCODE: 7, GAMECODE: 7, GAMEDATA: 7, ENGCODE: 7, KRNCODE: 7, KRNDATA: 7 };
const src = new Map(), mac = new Map();                         // "bank|addr" -> file:line, and inside a macro
for (const m of dbg.matchAll(/^line\tid=\d+,file=(\d+),line=(\d+)(,type=\d+)?(,count=\d+)?,span=([\d+]+)/gm)) {
  const loc = `${files.get(m[1])}:${m[2]}`, isMacro = !!m[3];
  for (const sid of m[5].split("+")) {
    const sp = spans.get(sid); if (!sp) continue;
    const sg = segs.get(sp.seg), bank = BANKSEG[sg.name] ?? -1;
    for (let a = sg.start + sp.start; a < sg.start + sp.start + sp.size; a++) {
      const k = `${bank}|${a}`, t = isMacro ? mac : src, o = t.get(k);
      if (!o || sp.size < o[1]) t.set(k, [loc, sp.size]);          // the narrowest span
    }
  }
}
const where = { get: (k) => { const s = src.get(k), m = mac.get(k); return s ? (m ? `${s[0]} > ${m[0]}` : s[0]) : m ? m[0] : undefined; } };


let cpu, A, cyc, step, wr, bankOf;
if (machine === "master") {
  const H = await open({ disc, labels, level });
  cpu = H.cpu; A = H.A; cyc = () => H.cyc(); step = () => H.runTo(A.frame_top); wr = (a, v) => H.wr(a, v);
} else {
  const B = await openB({ level, disc, labels });
  cpu = B.cpu; A = B.A; cyc = B.cyc; step = () => B.runTo(A.frame_top, 7); wr = (a, v) => B.bank(7, () => cpu.writemem(a, v));
}
const glob = Object.entries(A).filter(([n]) => !n.startsWith("@") && !n.startsWith("__")).sort((p, q) => p[1] - q[1]);
const routine = (pc) => { let r = "?"; for (const [n, a] of glob) { if (a > pc) break; r = n; } return r; };
const byLine = new Map(), byRoutine = new Map();
let inIsr = false, lastPc = -1, lastC = 0, total = 0, count = 0, t0c = 0;
// per interrupt: its kind (a chain step writes R13) and its phases: entry to the first
// CRTC write, first CRTC write to R13's, R13's to the RTI
let iEnt = 0, iFirst = -1, iR13 = -1, iKind = "vsync", lastIdx = -1;
const kinds = { step: { n: 0, c: 0, pre: 0, mid: 0, post: 0 }, vsync: { n: 0, c: 0 } };
const CRTC_IDX = 0xfe00, CRTC_DAT = 0xfe01;
const hook = cpu.debugInstruction.add((pc, op) => {
  const now = cyc();
  if (inIsr && lastPc >= 0) {
    const d = now - lastC, bank = lastPc >= 0x8000 && lastPc < 0xc000 ? 7 : -1;
    const loc = where.get(`${bank}|${lastPc}`) ?? where.get(`-1|${lastPc}`) ?? `$${lastPc.toString(16)}`;
    byLine.set(loc, (byLine.get(loc) || 0) + d); const r = routine(lastPc); byRoutine.set(r, (byRoutine.get(r) || 0) + d); total += d;
  }
  if (inIsr && lastPc >= 0) {                  // the last instruction's store, if a CRTC one
    const o = cpu.readmem(lastPc);
    if (o === 0x8d) { const ad = cpu.readmem(lastPc + 1) | cpu.readmem(lastPc + 2) << 8;
      if (ad === CRTC_IDX) lastIdx = cpu.a; else if (ad === CRTC_DAT) { if (iFirst < 0) iFirst = now; if (lastIdx === 13) { iR13 = now; iKind = "step"; } } }
    if (o === 0x8c && (cpu.readmem(lastPc + 1) | cpu.readmem(lastPc + 2) << 8) === CRTC_DAT && iFirst < 0) iFirst = now;
  }
  if (pc === A.irq_handler) { inIsr = true; count++; iEnt = now; iFirst = -1; iR13 = -1; iKind = "vsync"; }
  lastPc = inIsr ? pc : -1; lastC = now;
  if (inIsr && op === 0x40) { const d2 = 6; total += d2; inIsr = false; lastPc = -1;
    const k = kinds[iKind], all = now + 6 - iEnt; k.n++; k.c += all;
    if (iKind === "step") { k.pre += iFirst - iEnt; k.mid += iR13 - iFirst; k.post += now + 6 - iR13; } }
  return false;
});
t0c = cyc();
let rng = 1; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
let keys = 0, hold = 0;
for (let f = 0; f < frames; f++) { if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8][rnd() % 9]; hold = 4 + rnd() % 40; } wr(A.keys, keys); await step(); }
hook.remove();
const vs = (cyc() - t0c) / 40000;
console.log(`${machine} L${level}: ${(total / vs).toFixed(0)} cycles of interrupt a vsync, ${(count / vs).toFixed(2)} interrupts a vsync (${(total / count).toFixed(0)} each)`);
for (const [n, k] of Object.entries(kinds)) console.log(`  ${n}: ${(k.n / vs).toFixed(2)} a vsync, ${(k.c / k.n).toFixed(0)} cycles each` + (n === "step" ? ` (entry to first CRTC write ${(k.pre / k.n).toFixed(0)}, to R13 ${(k.mid / k.n).toFixed(0)}, R13 to RTI ${(k.post / k.n).toFixed(0)})` : ""));
console.log("\nby routine, cycles a vsync:");
for (const [k, v] of [...byRoutine].sort((p, q) => q[1] - p[1]).slice(0, 14)) console.log(`  ${(v / vs).toFixed(0).padStart(6)}  ${k}`);
console.log("\nby line, cycles a vsync:");
for (const [k, v] of [...byLine].sort((p, q) => q[1] - p[1]).slice(0, rows)) console.log(`  ${(v / vs).toFixed(1).padStart(7)}  ${k}`);
process.exit(0);
