// What every source line costs: cycles and executions a rendered frame, in every bank
// (the build's game.dbg, as cycprof.mjs maps it: the narrowest span, a macro's body
// line as "file:line > macrofile:line"), over the usual key script with the player
// unhurt.  An instruction's cycles are the time to the next one (an interrupt's entry
// is charged to the instruction it broke into; the handler's own instructions to their
// lines).  The spin-waits are idle, not work, and are left out: the
// five bytes from wait_flip (render_frame's flip spin -- and the lda bar_dirty after
// it) and the twelve from game.s fl_wait (the vsync wait and the peg test that loops
// back to it), in main RAM or bank 7.  Opened by harness.mjs open (Master) or
// bopen.mjs openB (Model B) for each level in turn; each frame is a break at frame_top
// with 'keys' from the fixed pattern PAT (s idle, r RIGHT, l LEFT, j UP) and hurt = 1,
// health = 3 written there.  A sideways PC's bank is the code bank (4..7) of the
// socket paged, from PBANK.
// For the grinds (tools/cycgrind/ and tools/bytegrind/: regions.py, apply.py): JSON
// by "file:line" (paths relative to beeb/), with the frame total.
//   node test/linecyc.mjs master|modelb <disc> <labels> <out.json> [levels=0,2,4,8,9] [frames=150]
// Output: out.json {machine, levels, frames, total, lines: {"file:line": {ex, cy,
// banks}}} (ex, cy a frame, averaged over levels x frames) and one line: the cycles a
// frame and the line count.
import { open } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { dbgPath } from "./harness.mjs";
import { readFileSync, writeFileSync } from "node:fs";

const [machine, disc, labels, outFile, lvS = "0,2,4,8,9", frS = "150"] = process.argv.slice(2);
const levels = lvS.split(",").map(Number), frames = +frS;
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KK = (c) => ({ s: 0, r: 2, l: 1, j: 4 })[c] ?? 0;
const dbgFile = dbgPath(labels);

// ---- the build's lines: (bank, address) -> "file:line", innermost source line first
// (a macro's body line is reported as "file:line > macrofile:line")
const dbg = readFileSync(dbgFile, "utf8");
const files = new Map(), segs = new Map(), spans = new Map();
for (const m of dbg.matchAll(/^file\tid=(\d+),name="([^"]+)"/gm)) files.set(m[1], m[2].replace(/^src\//, ""));
for (const m of dbg.matchAll(/^seg\tid=(\d+),name="(\w+)",start=0x([0-9A-F]+)/gm)) segs.set(m[1], { name: m[2], start: parseInt(m[3], 16) });
for (const m of dbg.matchAll(/^span\tid=(\d+),seg=(\d+),start=(\d+),size=(\d+)/gm)) spans.set(m[1], { seg: m[2], start: +m[3], size: +m[4] });
const BANKSEG = { SPR4CODE: 4, SPR4TAB: 4, SPR5TAB: 5, SPR4SWAP: 4, SPR4MASK: 4, SPR5CODE: 5, MAP5CODE: 5, SPR5MASK: 5, TIL6ENT: 6, TILCODE: 6, MNUCODE: 7, GAMECODE: 7, GAMEDATA: 7, ENGCODE: 7, KRNCODE: 7, KRNDATA: 7 };
const src = new Map(), mac = new Map();
for (const m of dbg.matchAll(/^line\tid=\d+,file=(\d+),line=(\d+)(,type=\d+)?(,count=\d+)?,span=([\d+]+)/gm)) {
  const loc = `${files.get(m[1])}:${m[2]}`, isMacro = !!m[3];
  for (const sid of m[5].split("+")) {
    const sp = spans.get(sid); if (!sp) continue;
    const sg = segs.get(sp.seg), bank = BANKSEG[sg.name] ?? -1;
    for (let a = sg.start + sp.start; a < sg.start + sp.start + sp.size; a++) {
      const k = `${bank}|${a}`, t = isMacro ? mac : src, o = t.get(k);
      if (!o || sp.size < o[1]) t.set(k, [loc, sp.size]);
    }
  }
}
const rel = (f) => f.replace(/^.*\/cleo\/beeb\//, "");
const locOf = (bank, pc) => {
  let s, m;
  for (const b of [bank, -1]) if (!s) s = src.get(`${b}|${pc}`);
  for (const b of [bank, -1]) if (!m) m = mac.get(`${b}|${pc}`);
  if (s && m) return `${rel(s[0])} > ${rel(m[0])}`;
  if (s || m) return rel((s || m)[0]);
  return `?b${bank}:$${pc.toString(16)}`;
};

// ---- run
const st = new Map();                                   // "bank|pc" -> [exec, cycles]
let total = 0;
for (const level of levels) {
  const M = machine === "master" ? await open({ disc, labels, level }) : await openB({ level, disc, labels });
  const cpu = M.cpu, A = M.A;
  const poke = (a, v) => (machine === "master" ? M.wr(a, v) : M.bank(7, () => cpu.writemem(a, v)));
  const cyc = machine === "master" ? () => M.cyc() : M.cyc;
  const bankOf = (sock) => { for (let b = 0; b < 4; b++) if (cpu.readmem(A.PBANK + b) === sock) return b + 4; return -1; };
  const sockBank = new Map();
  const IDLE = new Set();                               // the spin-waits' addresses (not counted)
  for (const [lo, n] of [[A.wait_flip, 5], [A.fl_wait, 12]]) if (lo !== undefined) for (let a = lo; a < lo + n; a++) IDLE.add(a);
  let last = null, lastC = 0;
  const hook = cpu.debugInstruction.add((pc) => {
    const now = cyc();
    if (last) { last[1] += now - lastC; }
    let bank = -1;
    if (pc >= 0x8000 && pc < 0xc000) { const s = cpu.readmem((A.romsel_cpy ?? 0xf4)); if (!sockBank.has(s)) sockBank.set(s, bankOf(s)); bank = sockBank.get(s); }
    if (IDLE.has(pc) && bank === -1 || IDLE.has(pc) && bank === 7) { last = null; lastC = now; return false; }
    const k = `${bank}|${pc}`;
    let rec = st.get(k); if (!rec) st.set(k, (rec = [0, 0]));
    rec[0]++; last = rec; lastC = now;
    return false;
  });
  for (let f = 0; f < frames; f++) {
    poke(A.keys, KK(PAT[f % PAT.length])); poke(A.hurt, 1); poke(A.health, 3);
    await (machine === "master" ? M.runTo(A.frame_top) : M.runTo(A.frame_top, 7));
  }
  hook.remove();
  if (M.s?.destroy) M.s.destroy();
}
const n = frames * levels.length;
const lines = {};
for (const [k, [ex, cy]] of st) {
  const [bank, pc] = k.split("|").map(Number);
  const loc = locOf(bank, pc);
  const r = (lines[loc] ??= { ex: 0, cy: 0, banks: [] });
  r.ex += ex / n; r.cy += cy / n; total += cy / n;
  if (!r.banks.includes(bank)) r.banks.push(bank);
}
for (const r of Object.values(lines)) { r.ex = +r.ex.toFixed(2); r.cy = +r.cy.toFixed(1); }
writeFileSync(outFile, JSON.stringify({ machine, levels, frames, total: +total.toFixed(0), lines }));
console.log(`${machine}: ${total.toFixed(0)} cycles a frame (idle excluded), ${Object.keys(lines).length} lines`);
process.exit(0);
