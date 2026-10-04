// Which variables the code touches, and how often: every executed instruction is
// counted (by address and the socket paged at the time), then its opcode decoded for
// the data address it names -- absolute, zero page, indexed, indirect (the 65C02's
// (zp) too) -- and the count credited to the variable there (the build's game.dbg
// names it: labels with their banks, equates for zero page).  An indirect access also
// credits the pointer's high byte.  Absolute addresses below $100 or at $FC00 up (I/O)
// are skipped.  Opened by harness.mjs open (Master) or bopen.mjs openB (Model B) for
// each level in turn; each frame is a break at frame_top with 'keys' from the fixed
// pattern PAT (s idle, r RIGHT, l LEFT, j UP) and hurt = 1, health = 3 written there.
// A sideways PC's bank is the code bank (4..7) of the socket paged, from PBANK; the
// decoding pages each socket in turn afterwards.
//
//   node test/hotvars.mjs master|modelb <disc> <labels> [levels=0,4,8] [frames=200] [rows=40]
//
// An absolute access costs a cycle and a byte more than a zero-page one.  The report
// has the non-indexed absolute accesses a frame, hottest first (the scalars zero page
// would speed up), the indexed ones (arrays, up to 15 rows), zero page's own traffic
// by address coldest first (the candidates to trade), and the zero-page addresses
// never touched.  A name is the nearest symbol at or below within 255 bytes, with its
// segment.
import { open, loadBanks, dbgPath } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { readFileSync } from "node:fs";
import path from "node:path";

const [machine, disc, labels, levelsArg = "0,4,8", framesArg = "200", rowsArg = "40"] = process.argv.slice(2);
if (!labels) { console.log("usage: node test/hotvars.mjs master|modelb <disc> <labels> [levels] [frames] [rows]"); process.exit(2); }
const levels = levelsArg.split(",").map(Number), frames = +framesArg, rows = +rowsArg;
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KK = (c) => ({ s: 0, r: 2, l: 1, j: 4 })[c] ?? 0;

// ---- the addressing modes that name data (the 65C02's included)
const MODE = {};
const modes = {
  zp:   "05 06 24 25 26 45 46 65 66 84 85 86 A4 A5 A6 C4 C5 C6 E4 E5 E6 04 14 64",
  zpx:  "15 16 35 36 55 56 75 76 94 95 B4 B5 D5 D6 F5 F6 34 74",
  zpy:  "96 B6",
  izx:  "01 21 41 61 81 A1 C1 E1",
  izy:  "11 31 51 71 91 B1 D1 F1",
  izp:  "12 32 52 72 92 B2 D2 F2",
  abs:  "0D 0E 2C 2D 2E 4D 4E 6D 6E 8C 8D 8E AC AD AE CC CD CE EC ED EE 0C 1C 9C",
  absx: "1D 1E 3D 3E 5D 5E 7D 7E 9D BC BD DD DE FD FE 3C 9E",
  absy: "19 39 59 79 99 B9 BE D9 F9",
};
for (const [mode, ops] of Object.entries(modes)) for (const o of ops.split(" ")) MODE[parseInt(o, 16)] = mode;

// ---- the build's names: labels (with their banks) and zero page's equates
const dbgFile = dbgPath(labels);
const dbg = readFileSync(dbgFile, "utf8"), banks = loadBanks(dbgFile);
const segName = new Map([...dbg.matchAll(/^seg\tid=(\d+),name="(\w+)"/gm)].map((m) => [m[1], m[2]]));
const syms = [];
for (const m of dbg.matchAll(/^sym\tid=\d+,name="(\w+)",([^\n]*)/gm)) {
  const val = /val=0x([0-9A-F]+)/.exec(m[2]);
  if (!val || m[1].startsWith("__") || /parent=/.test(m[2])) continue;
  const a = parseInt(val[1], 16), isLab = m[2].includes("type=lab"), seg = /seg=(\d+)/.exec(m[2]);
  if (!isLab && a >= 0x100) continue;                         // equates: zero page's only
  syms.push({ name: m[1], a, bank: isLab ? (banks?.byName.get(m[1]) ?? -1) : -1, seg: seg ? segName.get(seg[1]) : "" });
}
syms.sort((p, q) => p.a - q.a);
function nameOf(a, bank) {
  const paged = a >= 0x8000 && a < 0xC000;
  let best = null;
  for (const s of syms) if (s.a <= a && (!paged || s.bank === bank) && (!best || s.a >= best.a)) best = s;
  if (!best || a - best.a > 255) return `$${a.toString(16)}`;
  return (best.a === a ? best.name : `${best.name}+${a - best.a}`) + (best.seg ? ` [${best.seg}]` : "");
}

// ---- run, counting executed instructions by (the socket paged, pc)
const tally = new Map();                                        // "kind|bank|addr" -> accesses
for (const level of levels) {
  const M = machine === "master" ? await open({ disc, labels, level }) : await openB({ level, disc, labels });
  const cpu = M.cpu, A = M.A;
  const poke = (a, v) => (machine === "master" ? M.wr(a, v) : M.bank(7, () => cpu.writemem(a, v)));
  const exec = new Map();
  const hook = cpu.debugInstruction.add((pc) => {
    const k = pc >= 0x8000 && pc < 0xC000 ? cpu.readmem((A.romsel_cpy ?? 0xf4)) * 0x10000 + pc : pc;
    exec.set(k, (exec.get(k) ?? 0) + 1);
    return false;
  });
  for (let f = 0; f < frames; f++) {
    poke(A.keys, KK(PAT[f % PAT.length])); poke(A.hurt, 1); poke(A.health, 3);
    await (machine === "master" ? M.runTo(A.frame_top) : M.runTo(A.frame_top, 7));
  }
  hook.remove();
  // a socket's code bank (4..7) from PBANK, then each instruction decoded in its bank
  const bankOf = (sock) => { for (let b = 0; b < 4; b++) if (cpu.readmem(A.PBANK + b) === sock) return b + 4; return -1; };
  const was = cpu.readmem((A.romsel_cpy ?? 0xf4));
  for (const [k, n] of exec) {
    const pc = k % 0x10000, sock = Math.floor(k / 0x10000), paged = pc >= 0x8000 && pc < 0xC000;
    if (paged) cpu.writemem(0xFE30, sock);
    const op = cpu.readmem(pc), mode = MODE[op];
    if (!mode) continue;
    const abs = mode.startsWith("abs"), a = abs ? cpu.readmem(pc + 1) | (cpu.readmem(pc + 2) << 8) : cpu.readmem(pc + 1);
    if (abs && (a < 0x100 || a >= 0xFC00)) continue;           // I/O; zero page by a long form
    const bank = a >= 0x8000 && a < 0xC000 ? (paged ? bankOf(sock) : -1) : -1;
    const key = `${abs ? (mode === "abs" ? "S" : "X") : "Z"}|${bank}|${a}`;
    tally.set(key, (tally.get(key) ?? 0) + n);
    if (mode === "izy" || mode === "izx" || mode === "izp") {   // a pointer: its high byte too
      const k2 = `Z|-1|${(a + 1) & 255}`;
      tally.set(k2, (tally.get(k2) ?? 0) + n);
    }
  }
  cpu.writemem(0xFE30, was);
  if (M.s?.destroy) M.s.destroy();
}
const perFrame = (n) => n / (frames * levels.length);

// ---- by variable: a name and its accesses a frame
const byVar = (kind) => {
  const v = new Map();
  for (const [k, n] of tally) {
    const [kd, bank, a] = k.split("|");
    if (kd !== kind) continue;
    const name = nameOf(+a, +bank);
    v.set(name, (v.get(name) ?? 0) + perFrame(n));
  }
  return [...v].sort((p, q) => q[1] - p[1]);
};
console.log(`${machine}: ${levels.length} levels x ${frames} frames\n`);
console.log("absolute scalars (non-indexed), accesses a frame -- a cycle each in zero page:");
for (const [name, n] of byVar("S").slice(0, rows)) console.log(`  ${n.toFixed(1).padStart(8)}  ${name}`);
console.log("\nabsolute indexed (arrays), accesses a frame:");
for (const [name, n] of byVar("X").slice(0, Math.min(rows, 15))) console.log(`  ${n.toFixed(1).padStart(8)}  ${name}`);
const zp = new Map();
for (const [k, n] of tally) { const [kd, , a] = k.split("|"); if (kd === "Z") zp.set(+a, (zp.get(+a) ?? 0) + perFrame(n)); }
console.log("\nzero page, accesses a frame by address, coldest first (unlisted: untouched):");
for (const [a, n] of [...zp].sort((p, q) => p[1] - q[1]).slice(0, rows)) console.log(`  ${n.toFixed(1).padStart(8)}  $${a.toString(16).padStart(2, "0")}  ${nameOf(a, -1)}`);
const untouched = [];
for (let a = 0; a < 0x100; a++) if (!zp.has(a)) untouched.push(a);
console.log(`\nzero page never touched (${untouched.length}): ${untouched.map((a) => "$" + a.toString(16).padStart(2, "0")).join(" ")}`);
process.exit(0);
