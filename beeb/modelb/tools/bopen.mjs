// Boot the full game under jsbeeb and bring it to a level's first frame_top, the way
// the Master harness does (harness.mjs open): the title menu is patched out and the
// level is chosen by rewriting level_loop's `ldx level`, so the game's own loader
// gathers the level from the disc.  Returns the session, the CPU, the labels and the
// helpers the tools share.
//   const B = await openB({ level: 0, model: "B-DFS1.2" | "B1770" })
import { findJsbeeb, loadLabels } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";

// Emulate a write-select sideways RAM board on a jsbeeb Model B: reads page through
// ROMSEL as ever, a store into $8000-$BFFF goes to the bank the board's register names
// -- Watford: the last store to $FF30-$FF3F (its low nibble); Solidisk: user VIA port B
// bits 0-3 (ORB & DDRB).  Both start at bank 0, as a fresh machine would, more or less.
export function boardEmu(cpu, kind) {
  if (kind !== "watford" && kind !== "solidisk") throw new Error(`BBOARD: ${kind}?`);
  const orig = cpu.writemem.bind(cpu);
  let wr = 0, orb = 0, ddrb = 0;
  cpu.writemem = function (addr, b) {
    addr &= 0xffff;
    if (addr >= 0x8000 && addr < 0xc000) {
      if (cpu._debugWrite) cpu._debugWrite(addr, b);
      const bank = kind === "solidisk" ? (orb & ddrb & 15) : wr;
      if (cpu.model.swram[bank]) cpu.ramRomOs[cpu.romOffset + bank * 16384 + (addr - 0x8000)] = b;
      return;
    }
    if (kind === "watford" && (addr & 0xfff0) === 0xff30) wr = addr & 15;
    if (kind === "solidisk") { if ((addr & 0xffef) === 0xfe60) orb = b; else if ((addr & 0xffef) === 0xfe62) ddrb = b; }
    return orig(addr, b);
  };
}

export async function openB({ level = 0, model = process.env.BMODEL ?? "B-DFS1.2", disc = "build/cleob.ssd", labels = "build/labels.txt", keys = false } = {}) {
  const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
  const A = loadLabels(labels);
  const s = new MachineSession(model);
  await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const cpu = s._machine.processor;
  // BBOARD=watford|solidisk: a sideways RAM board whose write bank is its own register
  // (jsbeeb has none; this wraps the CPU's store)
  if (process.env.BBOARD) boardEmu(cpu, process.env.BBOARD);
  // the banks: the code is assembled for banks 4..7 and the boot loader puts them in
  // the lowest four sockets it finds RAM in -- jsbeeb's Model B has RAM in sockets
  // 0-7, so bank 7 is socket 3 here.  BSWRAM="8,9,10,11" (any sockets, no ROMs in
  // them) puts the RAM elsewhere.  bank() and runTo() take the code's numbers.
  const SW = process.env.BSWRAM ? process.env.BSWRAM.split(",").map(Number) : null;
  if (SW) cpu.model.swram = Array.from({ length: 16 }, (_, i) => SW.includes(i));
  const P = cpu.model.swram.map((r, i) => (r ? i : -1)).filter((i) => i >= 0).slice(0, 4);
  if (P.length < 4) throw new Error("B: fewer than four sideways RAM sockets");
  const PB = (b) => (b >= 4 && b <= 7 ? P[b - 4] : b);
  const bank = (b, f) => { const was = cpu.readmem(0xf4); cpu.writemem(0xf4, PB(b)); cpu.writemem(0xfe30, PB(b)); const r = f(); cpu.writemem(0xf4, was); cpu.writemem(0xfe30, was); return r; };
  const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
  async function runTo(pc, b, budget = 3000) {
    const pb = PB(b);
    const h = cpu.debugInstruction.add((p) => p === pc && cpu.readmem(0xf4) === pb);
    try { for (let i = 0; i < budget; i++) { await s.runFor(20000); if (cpu.pc === pc && cpu.readmem(0xf4) === pb) return; } }
    finally { h.remove(); }
    throw new Error(`B: runTo ${pc.toString(16)} timed out`);
  }
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  await runToB(A.title_loop, 7);
  bank(7, () => {
    cpu.writemem(A.title_loop + 5, 0xea);   // keep jsr ensure_menu (the overlay, the title pack and the BAR); jsr t_title_menu ->
    cpu.writemem(A.title_loop + 3, 0xa9); cpu.writemem(A.title_loop + 4, 0);   // "start game"
    let ok = false;
    for (let a = A.level_loop; a < A.level_loop + 24; a++)
      if (cpu.readmem(a) === 0xa6 && cpu.readmem(a + 1) === (A.level & 255)) { cpu.writemem(a, 0xa2); cpu.writemem(a + 1, level); ok = true; break; }
    if (!ok) throw new Error("B: ldx level not found in level_loop");
  });
  await runToB(A.level_init, 7, 60000);          // the disc load: seeks at DFS's step rate
  if (!keys) bank(7, () => cpu.writemem(A.scan_keys, 0x60));   // inputs from the tool only
  await runToB(A.frame_top, 7);
  return { s, cpu, A, bank, cyc, runTo, PB };
  async function runToB(pc, b, budget) { return runTo(pc, b, budget); }
}
