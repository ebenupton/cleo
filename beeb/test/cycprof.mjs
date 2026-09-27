// Where the frame pays for branches and page crossings: every executed instruction is
// counted by its bank and address, and for each one the extra cycles it cost --
//   a taken branch: +1, and +1 more when it lands in another page;
//   an indexed or indirect read (abs,X  abs,Y  (zp),Y) that crosses a page: +1.
// Then per source line (the build's game.dbg): the executions a frame, the branches
// taken and not, the cycles a frame a taken branch spends over falling through (what
// turning it round could save, before whatever the turning costs), and the page
// crossings' cycles a frame.  Run over the usual key script with the player unhurt.
//   node test/cycprof.mjs master|modelb <disc> <labels> [levels=0,2,4,6] [frames=150] [rows=40] [cross|taken|line=file:line,...]
import { open, loadBanks, dbgPath } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { readFileSync } from "node:fs";
import path from "node:path";

const [machine, disc, labels, levelsArg = "0,2,4,6", framesArg = "150", rowsArg = "40", sortBy = "cross"] = process.argv.slice(2);
if (!labels) { console.log("usage: node test/cycprof.mjs master|modelb <disc> <labels> [levels] [frames] [rows] [cross|taken]"); process.exit(2); }
const levels = levelsArg.split(",").map(Number), frames = +framesArg, rows = +rowsArg;
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KK = (c) => ({ s: 0, r: 2, l: 1, j: 4 })[c] ?? 0;
const cmos = machine === "master";

// ---- opcodes: branches, and the reads whose index can cross a page
const BR = new Set([0x10, 0x30, 0x50, 0x70, 0x90, 0xb0, 0xd0, 0xf0].concat(cmos ? [0x80] : []));
const RD_ABSX = new Set([0x1d, 0x3d, 0x5d, 0x7d, 0xbd, 0xdd, 0xfd, 0xbc].concat(cmos ? [0x3c] : []));
const RD_ABSY = new Set([0x19, 0x39, 0x59, 0x79, 0xb9, 0xd9, 0xf9, 0xbe]);
const RD_IZY = new Set([0x11, 0x31, 0x51, 0x71, 0xb1, 0xd1, 0xf1]);

// ---- the build's lines: address -> "file:line" per segment (so per bank), from the spans
const dbgFile = dbgPath(labels);
const dbg = readFileSync(dbgFile, "utf8");
const files = new Map(), segs = new Map(), spans = new Map();
for (const m of dbg.matchAll(/^file\tid=(\d+),name="([^"]+)"/gm)) files.set(m[1], m[2].replace(/^src\//, ""));
for (const m of dbg.matchAll(/^seg\tid=(\d+),name="(\w+)",start=0x([0-9A-F]+)/gm)) segs.set(m[1], { name: m[2], start: parseInt(m[3], 16) });
for (const m of dbg.matchAll(/^span\tid=(\d+),seg=(\d+),start=(\d+),size=(\d+)/gm)) spans.set(m[1], { seg: m[2], start: +m[3], size: +m[4] });
const BANKSEG = { SPR4CODE: 4, SPR4SWAP: 4, SPR4MASK: 4, SPR5CODE: 5, MAP5CODE: 5, SPR5MASK: 5, TIL6ENT: 6, TILCODE: 6, MNUCODE: 7, GAMECODE: 7, GAMEDATA: 7, ENGCODE: 7, KRNCODE: 7, KRNDATA: 7 };
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

// ---- run
const st = new Map();                                           // "bank|pc" -> [exec, taken, extra]
for (const level of levels) {
  const M = machine === "master" ? await open({ disc, labels, level }) : await openB({ level, disc, labels });
  const cpu = M.cpu, A = M.A;
  const poke = (a, v) => (machine === "master" ? M.wr(a, v) : M.bank(7, () => cpu.writemem(a, v)));
  const bankOf = (sock) => { for (let b = 0; b < 4; b++) if (cpu.readmem(A.PBANK + b) === sock) return b + 4; return -1; };
  const sockBank = new Map();
  let pend = null;                                              // the branch just executed
  const hook = cpu.debugInstruction.add((pc) => {
    if (pend) {                                                 // did the last branch go?
      const [rec, from] = pend; pend = null;
      if (pc !== ((from + 2) & 0xffff)) { rec[1]++; rec[2]++; if ((pc & 0xff00) !== ((from + 2) & 0xff00)) rec[2]++; }
    }
    let bank = -1;
    if (pc >= 0x8000 && pc < 0xc000) { const s = cpu.readmem(0xf4); if (!sockBank.has(s)) sockBank.set(s, bankOf(s)); bank = sockBank.get(s); }
    const k = `${bank}|${pc}`;
    let rec = st.get(k); if (!rec) st.set(k, (rec = [0, 0, 0]));
    rec[0]++;
    const op = cpu.readmem(pc);
    if (BR.has(op)) pend = [rec, pc];
    else if (RD_ABSX.has(op) || RD_ABSY.has(op)) {
      const base = cpu.readmem(pc + 1) | (cpu.readmem(pc + 2) << 8);
      if (((base + (RD_ABSX.has(op) ? cpu.x : cpu.y)) & 0xff00) !== (base & 0xff00)) rec[2]++;
    } else if (RD_IZY.has(op)) {
      const zp = cpu.readmem(pc + 1), base = cpu.readmem(zp) | (cpu.readmem((zp + 1) & 0xff) << 8);
      if (((base + cpu.y) & 0xff00) !== (base & 0xff00)) rec[2]++;
    }
    return false;
  });
  for (let f = 0; f < frames; f++) {
    poke(A.keys, KK(PAT[f % PAT.length])); poke(A.hurt, 1); poke(A.health, 3);
    await (machine === "master" ? M.runTo(A.frame_top) : M.runTo(A.frame_top, 7));
  }
  hook.remove();
  if (M.s?.destroy) M.s.destroy();
}
const per = (n) => n / (frames * levels.length);

// ---- by source line
const lines = new Map();
for (const [k, [ex, tk, extra]] of st) {
  const [bank, pc] = k.split("|").map(Number);
  const loc = where.get(`${bank}|${pc}`) ?? where.get(`-1|${pc}`) ?? `?${bank}:$${pc.toString(16)}`;
  const key = `${loc}  [${bank >= 0 ? "b" + bank + " " : ""}$${pc.toString(16)}]`;
  let r = lines.get(key); if (!r) lines.set(key, (r = { ex: 0, tk: 0, cross: 0, br: false }));
  r.ex += ex; r.tk += tk;
  r.cross += extra - tk;                                        // what is left is page crossing
  if (tk || extra === 0 && ex) r.br ||= tk > 0;
}
const all = [...lines].map(([k, r]) => ({ k, ex: per(r.ex), tk: per(r.tk), nt: per(r.ex - r.tk), cross: per(r.cross) }));
const tot = all.reduce((a, r) => ({ cross: a.cross + r.cross, tk: a.tk + r.tk }), { cross: 0, tk: 0 });
console.log(`${machine}: levels ${levels.join(",")} x ${frames} frames; a frame: ${tot.cross.toFixed(0)} cycles in page crossings, ${tot.tk.toFixed(0)} branches taken`);
if (sortBy.startsWith("line=")) {                               // every site on the lines named
  const want = sortBy.slice(5).split(",");
  for (const r of all.filter((r) => want.some((w) => r.k.includes(w + " ") || r.k.includes(w + "  ") || r.k.endsWith(w))))
    console.log(`  exec ${r.ex.toFixed(1).padStart(7)}  taken ${r.tk.toFixed(1).padStart(7)}  cross ${r.cross.toFixed(1).padStart(6)}  ${r.k}`);
} else if (sortBy === "cross") {
  console.log("\npage crossings, cycles a frame (branches' included):");
  for (const r of all.sort((p, q) => q.cross - p.cross).slice(0, rows)) console.log(`  ${r.cross.toFixed(1).padStart(8)}  ${r.k}   (exec ${r.ex.toFixed(0)})`);
} else {
  console.log("\nbranches taken more than not, cycles a frame over falling through (taken - not taken):");
  for (const r of all.filter((r) => r.tk > r.nt).sort((p, q) => (q.tk - q.nt) - (p.tk - p.nt)).slice(0, rows))
    console.log(`  ${(r.tk - r.nt).toFixed(1).padStart(8)}  ${r.k}   (taken ${r.tk.toFixed(0)}, not ${r.nt.toFixed(0)})`);
}
process.exit(0);
