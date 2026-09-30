// The logic's cycles by routine: frame_top to render_frame (the two logic steps a
// rendered frame), interrupts excluded, over N frames of fwork.mjs's seeded key
// script.  Every jsr is followed (a routine's cycles are its own plus its callees'),
// and the tree is printed to a depth, as cycles a rendered frame.
// With FLAT=n, then the n source lines costing most (cycles and executions a frame).
//   node test/logprof.mjs master|modelb <disc> <labels> [frames=300] [seed=1] [levels=0] [depth=3]
import { open, dbgPath } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { readFileSync } from "node:fs";
const [machine, disc, labels, fr = "300", sd = "1", lvs = "0", dp = "3"] = process.argv.slice(2);
const frames = +fr, DEPTH = +dp;
// the label names, for jsr targets: the nearest label at or below
const names = new Map();
for (const l of readFileSync(labels, "utf8").split("\n")) {
  const p = l.split(/\s+/); if (p[0] === "al") { const a = parseInt(p[1], 16), n = p[2].replace(/^\./, ""); if (!names.has(a) || n.length < names.get(a).length) names.set(a, n); }
}
const nameOf = (a) => names.get(a) ?? `$${a.toString(16)}`;
const tree = { n: "logic", c: 0, calls: 0, kids: new Map() };
const FLAT = +(process.env.FLAT ?? 0), flat = new Map();    // "bank|pc" -> [cycles, execs]
let nFrames = 0;
for (const LEVEL of lvs.split(",").map(Number)) {
  let cpu, A, cyc, step, inB7, wr;
  if (machine === "master") {
    const H = await open({ disc, labels, level: LEVEL });
    cpu = H.cpu; A = H.A; cyc = () => H.cyc(); step = () => H.runTo(A.frame_top); inB7 = () => true; wr = (a, v) => H.wr(a, v);
  } else {
    const B = await openB({ level: LEVEL, disc, labels });
    cpu = B.cpu; A = B.A; cyc = B.cyc; const B7 = B.PB(7);
    step = () => B.runTo(A.frame_top, 7); inB7 = () => cpu.readmem(0xf4) === B7; wr = (a, v) => B.bank(7, () => cpu.writemem(a, v));
  }
  let on = false, isr = false, lastC = 0, stack = [], lastK = null;   // stack: [node, return address]
  const meter = cpu.debugInstruction.add((pc, op) => {
    const now = cyc();
    if (isr) { if (op === 0x40) { isr = false; lastC = now + 6; } return false; }
    if (pc === A.irq_handler) { if (on) { const d = now - lastC; for (const [nd] of stack) nd.c += d; tree.c += d; } isr = true; return false; }
    if (pc === A.frame_top && inB7()) { on = true; stack = []; lastC = now; nFrames++; }
    if (!on) return false;
    const d = now - lastC; lastC = now;
    tree.c += d; for (const [nd] of stack) nd.c += d;
    if (FLAT) {
      if (lastK) { const r = flat.get(lastK); r[0] += d; }
      lastK = `${pc >= 0x8000 && pc < 0xc000 ? (inB7() ? 7 : -1) : -1}|${pc}`;
      let r = flat.get(lastK); if (!r) flat.set(lastK, (r = [0, 0])); r[1]++;
    }
    if (op === 0x20 && stack.length === 0 && (cpu.readmem(pc + 1) | cpu.readmem(pc + 2) << 8) === A.render_frame) { on = false; return false; }
    // unwind returns: rts lands at a frame's return address
    while (stack.length && stack[stack.length - 1][1] === pc) stack.pop();
    if (op === 0x20) {
      const t = cpu.readmem(pc + 1) | cpu.readmem(pc + 2) << 8;
      const par = stack.length ? stack[stack.length - 1][0] : tree;
      const key = nameOf(t);
      let nd = par.kids.get(key); if (!nd) { nd = { n: key, c: 0, calls: 0, kids: new Map() }; par.kids.set(key, nd); }
      nd.calls++;
      stack.push([nd, (pc + 3) & 0xffff]);
    }
    return false;
  });
  let rng = +sd >>> 0; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
  let keys = 0, hold = 0;
  for (let f = 0; f < frames; f++) {
    if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8][rnd() % 9]; hold = 4 + rnd() % 40; }
    wr(A.keys, keys); await step();
  }
  meter.remove();
}
if (FLAT) {
  const dbg = readFileSync(dbgPath(labels), "utf8");
  const files = new Map(), segs = new Map(), spans = new Map(), src = new Map();
  for (const m of dbg.matchAll(/^file\tid=(\d+),name="([^"]+)"/gm)) files.set(m[1], m[2].replace(/^.*\/src\//, ""));
  for (const m of dbg.matchAll(/^seg\tid=(\d+),name="(\w+)",start=0x([0-9A-F]+)/gm)) segs.set(m[1], { name: m[2], start: parseInt(m[3], 16) });
  for (const m of dbg.matchAll(/^span\tid=(\d+),seg=(\d+),start=(\d+),size=(\d+)/gm)) spans.set(m[1], { seg: m[2], start: +m[3], size: +m[4] });
  const B7 = new Set(["GAMECODE", "GAMEDATA", "ENGCODE", "KRNCODE", "KRNDATA", "MNUCODE"]);
  for (const m of dbg.matchAll(/^line\tid=\d+,file=(\d+),line=(\d+)(,type=\d+)?(,count=\d+)?,span=([\d+]+)/gm)) {
    const loc = `${files.get(m[1])}:${m[2]}`;
    for (const sid of m[5].split("+")) {
      const sp = spans.get(sid); if (!sp) continue;
      const sg = segs.get(sp.seg); const a0 = sg.start + sp.start;
      const bank = a0 >= 0x8000 && a0 < 0xc000 ? (B7.has(sg.name) ? 7 : -2) : -1;
      for (let a = a0; a < a0 + sp.size; a++) { const k = `${bank}|${a}`, o = src.get(k); if (!o || sp.size < o[1]) src.set(k, [loc, sp.size]); }
    }
  }
  // blocks: the nearest code label at or below (cheap ones too, under their scope)
  const labs = [];
  const symName = new Map();
  const syms = [];
  for (const m of dbg.matchAll(/^sym\tid=(\d+),name="([^"]+)",([^\n]*)$/gm)) {
    const rest = m[3], val = rest.match(/val=0x([0-9A-F]+)/), seg = rest.match(/seg=(\d+)/), par = rest.match(/parent=(\d+)/);
    if (!/type=lab/.test(rest) || !val || !seg) continue;
    symName.set(m[1], m[2]); syms.push([m[2], parseInt(val[1], 16), seg[1], par?.[1]]);
  }
  for (const [name, v, sgid, par] of syms) {
    const sg = segs.get(sgid); if (!sg || /^@(bf_|s_|wr|WR)/.test(name)) continue;     // the macros' site markers
    const bank = v >= 0x8000 && v < 0xc000 ? (B7.has(sg.name) ? 7 : -2) : -1;
    labs.push([bank, v, name.startsWith("@") && par ? `${symName.get(par) ?? "?"}${name}` : name]);
  }
  labs.sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  const blockOf = (bank, pc) => { let best = null; for (const l of labs) { if (l[0] !== bank) continue; if (l[1] <= pc) best = l; else break; } return best ? best[2] : "?"; };
  const byBlock = new Map();
  for (const [k, [c, e]] of flat) { const [b, a] = k.split("|").map(Number); const nm = blockOf(b, a); const r = byBlock.get(nm) ?? [0, 0]; r[0] += c; r[1] += e; byBlock.set(nm, r); }
  console.log(`\nby block (the nearest label; cycles a rendered frame):`);
  for (const [nm, [c]] of [...byBlock].sort((a, b) => b[1][0] - a[1][0]).slice(0, FLAT)) console.log(`${(c / nFrames).toFixed(0).padStart(7)}  ${nm}`);
  const byLine = new Map();
  for (const [k, [c, e]] of flat) { const loc = src.get(k)?.[0] ?? k; const r = byLine.get(loc) ?? [0, 0]; r[0] += c; r[1] += e; byLine.set(loc, r); }
  console.log(`\nthe ${FLAT} costliest lines (cycles, executions a rendered frame):`);
  for (const [loc, [c, e]] of [...byLine].sort((a, b) => b[1][0] - a[1][0]).slice(0, FLAT))
    console.log(`${(c / nFrames).toFixed(0).padStart(7)} ${(e / nFrames).toFixed(1).padStart(7)}  ${loc}`);
}
const pr = (nd, depth, ind) => {
  const kids = [...nd.kids.values()].sort((a, b) => b.c - a.c);
  const own = nd.c - kids.reduce((s, k) => s + k.c, 0);
  console.log(`${ind}${(nd.c / nFrames).toFixed(0).padStart(7)}  ${nd.n}${nd.calls ? `  (x${(nd.calls / nFrames).toFixed(1)}/frame)` : ""}${kids.length ? `  own ${(own / nFrames).toFixed(0)}` : ""}`);
  if (depth < DEPTH) for (const k of kids) if (k.c / nFrames >= 20) pr(k, depth + 1, ind + "  ");
};
console.log(`${machine}, levels ${lvs}, ${nFrames} frames: cycles a rendered frame (inclusive; interrupts excluded)`);
pr(tree, 0, "");
process.exit(0);
