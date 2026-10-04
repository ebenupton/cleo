// Boot the game on a jsbeeb Model B and bring it to a level's first frame_top, as
// harness.mjs open does on the Master.  SHIFT-BREAK (jsbeeb key 16 held over a reset),
// then: run to title_loop (bank 7, the menus' image, after its disc load); patch its
// `jsr title_menu` to `lda #0; nop` (A = 0: start a game); run to game_in (disc.s: the
// game's image is in bank 7, its level loop not yet entered); in level_loop turn
// `ldx level` into `ldx #level`; run to level_init (the level's own loader gathers it
// from the disc at DFS's step rate); unless keys: true, make scan_keys an rts so 'keys'
// is only what a tool writes; run to frame_top.  Returns the session, the CPU, the
// labels and the helpers the tools share.
//   const B = await openB({ level = 0, model = BMODEL ?? "B-DFS1.2" | "B1770",
//                           disc = "build/cleo.ssd", labels = "build/modelb/labels.txt",
//                           keys = false, onSession = null })
//   B.s, B.cpu, B.A (labels and defs_ld.inc constants, harness loadLabels)
//   B.PB(b)         the socket holding the code's bank b (4..7)
//   B.bank(b, f)    f() with bank b paged (ROMSEL and its copy romsel_cpy), then back
//   B.cyc()         cycles since boot (jsbeeb's counter unwrapped)
//   B.runTo(pc, b, budget = 3000)   run until PC = pc with bank b paged and bank 7's
//                   image right (harness imgOk: ld_img); budget x 20000 cycles, then
//                   throws.  jsbeeb's debugInstruction hook stops before the instruction.
// onSession({ s, cpu, A, bank, cyc, PB }) is called before the boot, for a tool's hooks.
// Known limits: four sideways RAM sockets are required (jsbeeb's own Model B has RAM in
// 0-7); a build whose labels have no game_in gets the older one-image title patch.
import { findJsbeeb, loadLabels, loadBanks, imgOk, dbgPath } from "./harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";

// (the write-select boards' emulation is beebgame's; re-exported for the tools)
import { boardEmu } from "../beebgame/test/lib/boards.mjs";
export { boardEmu };

export async function openB({ level = 0, model = process.env.BMODEL ?? "B-DFS1.2", disc = "build/cleo.ssd", labels = "build/modelb/labels.txt", keys = false, onSession = null } = {}) {
  const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
  const A = loadLabels(labels);
  const banks = loadBanks(dbgPath(labels));   // (bank 7's images)
  const s = new MachineSession(model);
  await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const cpu = s._machine.processor;
  // BBOARD=watford|solidisk: a sideways RAM board whose write bank is its own register
  // (jsbeeb has none; boards.mjs wraps the CPU's store)
  if (process.env.BBOARD) boardEmu(cpu, process.env.BBOARD);
  // the banks: the code is assembled for banks 4..7 and the boot loader (loader.s
  // find_ram) puts them in the lowest four sockets it finds RAM in -- jsbeeb's Model B
  // has RAM in sockets 0-7, so bank 7 is socket 3 here.  BSWRAM="8,9,10,11" (any
  // sockets, no ROMs in them) puts the RAM elsewhere.  bank() and runTo() take the
  // code's numbers; PB maps them.
  const SW = process.env.BSWRAM ? process.env.BSWRAM.split(",").map(Number) : null;
  if (SW) cpu.model.swram = Array.from({ length: 16 }, (_, i) => SW.includes(i));
  const P = cpu.model.swram.map((r, i) => (r ? i : -1)).filter((i) => i >= 0).slice(0, 4);
  if (P.length < 4) throw new Error("B: fewer than four sideways RAM sockets");
  const PB = (b) => (b >= 4 && b <= 7 ? P[b - 4] : b);
  const bank = (b, f) => { const was = cpu.readmem((A.romsel_cpy ?? 0xf4)); cpu.writemem((A.romsel_cpy ?? 0xf4), PB(b)); cpu.writemem(0xfe30, PB(b)); const r = f(); cpu.writemem((A.romsel_cpy ?? 0xf4), was); cpu.writemem(0xfe30, was); return r; };
  const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
  if (onSession) onSession({ s, cpu, A, bank, cyc, PB });   // (a tool's hooks, before the boot)
  // break at pc with bank b paged and bank 7's image right; a chunk is 20000 cycles
  async function runTo(pc, b, budget = 3000) {
    const pb = PB(b);
    const at = (p) => p === pc && cpu.readmem((A.romsel_cpy ?? 0xf4)) === pb && imgOk(cpu, A, banks, pc);
    const h = cpu.debugInstruction.add((p) => at(p));
    try { for (let i = 0; i < budget; i++) { await s.runFor(20000); if (at(cpu.pc)) return; } }
    finally { h.remove(); }
    throw new Error(`B: runTo ${pc.toString(16)} timed out`);
  }
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  await runToB(A.title_loop, 7, 60000);          // (the menus' image: a disc load first)
  if (A.game_in !== undefined) {
    bank(7, () => {                               // jsr title_menu -> lda #0 (A = 0: start); nop
      cpu.writemem(A.title_loop, 0xa9); cpu.writemem(A.title_loop + 1, 0); cpu.writemem(A.title_loop + 2, 0xea);
    });
    await runToB(A.game_in, 7, 60000);           // the game's image in, before its level_loop
  } else bank(7, () => {                          // (a build before bank 7's images: one image,
                                                  //  the menus called from the loop)
    cpu.writemem(A.title_loop + 5, 0xea);
    cpu.writemem(A.title_loop + 3, 0xa9); cpu.writemem(A.title_loop + 4, 0);
  });
  bank(7, () => {                                 // ldx level ($A6 zp) -> ldx #level ($A2), in level_loop's first 24 bytes
    let ok = false;
    for (let a = A.level_loop; a < A.level_loop + 24; a++)
      if (cpu.readmem(a) === 0xa6 && cpu.readmem(a + 1) === (A.level & 255)) { cpu.writemem(a, 0xa2); cpu.writemem(a + 1, level); ok = true; break; }
    if (!ok) throw new Error("B: ldx level not found in level_loop");
  });
  await runToB(A.level_init, 7, 60000);          // the level's disc load: seeks at DFS's step rate
  if (!keys) bank(7, () => cpu.writemem(A.scan_keys, 0x60));   // scan_keys -> rts: 'keys' is the tool's only
  await runToB(A.frame_top, 7);
  return { s, cpu, A, bank, cyc, runTo, PB };
  async function runToB(pc, b, budget) { return runTo(pc, b, budget); }
}
