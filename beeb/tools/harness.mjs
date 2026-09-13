// Cleo measurement harness: a frame-exact driver for the real game under jsbeeb.
//
// WHY THIS EXISTS.  The old benchmark advanced the machine in 20000-cycle polls and
// checked a frame counter afterwards, so every wait overshot by a variable amount and
// every key write landed at an arbitrary point inside a frame.  Whether the logic saw
// a key this frame or the next then depended on sub-frame phase -- which depends on
// absolute timing, which depends on code size.  One frame of drift at the first
// location put the world somewhere else for every location after it (measured: f0 64
// vs 65 at location 1, and by location 10 one build's Cleo had died and restarted the
// level).  The costs being compared were of different scenes.
//
// THE FIX.  jsbeeb's debugInstruction hook stops execution *before* the instruction
// when a handler returns true, so an exact PC break is available at full speed.  Every
// wait here is therefore "run to the next frame_top", a symbol placed in main.s at the
// one point reached exactly once per rendered frame, before the two logic steps read
// 'keys'.  Inputs are written while stopped there.  Nothing in the protocol can
// observe a cycle count, so nothing in it can observe code size.
//
// WHAT IS STILL NOT INVARIANT, and why that is honest rather than a bug: moving code
// changes real cycle counts, because a taken 6502 branch costs an extra cycle when its
// target is on another page, and so does an indexed access that crosses one.  No
// harness can remove that -- it is the machine.  So this module does not claim equal
// cycles; it claims the same SCENE, and proves it: fingerprint() hashes every piece of
// state the renderer reads, and a comparison is only valid where the fingerprints
// match.  A cycle difference under a matching fingerprint is genuine; a cycle
// difference under a differing fingerprint is a measurement artifact.
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import { createHash } from "node:crypto";
import path from "node:path";

export function findJsbeeb() {
  const npx = path.join(homedir(), ".npm", "_npx");
  for (const d of readdirSync(npx)) {
    const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js");
    if (existsSync(p)) return p;
  }
  throw new Error("jsbeeb not found");
}
export function loadLabels(file) {
  const A = {};
  for (const m of readFileSync(file, "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
  return A;
}

const CHUNK = 90_000;          // < jsbeeb's MaxCyclesPerIter (100000) so each runFor is
                               // exactly one execute() call -- see runTo for why
const WRAP = 2_000_000;        // cpu.currentCycles wraps at 2e6 (cycleSeconds ticks)

export class Harness {
  constructor(s, A) { this.s = s; this.A = A; this.cpu = s._machine.processor; }

  rd(a) { return this.cpu.readmem(a); }
  wr(a, v) { this.cpu.writemem(a, v); }
  rd16(a) { return this.rd(a) | (this.rd(a + 1) << 8); }
  rds16(a) { const v = this.rd16(a); return v >= 32768 ? v - 65536 : v; }
  wr16(a, v) { this.wr(a, v & 255); this.wr(a + 1, (v >> 8) & 255); }
  cyc() { return this.cpu.currentCycles + this.cpu.cycleSeconds * WRAP; }

  // Run until PC is exactly `pc`.  jsbeeb skips the hook check on the FIRST
  // instruction of each execute() call, so a chunk boundary landing on the target
  // would silently run past it.  Two things make this safe: we chunk ourselves at
  // less than MaxCyclesPerIter (one execute per runFor), and we test cpu.pc after
  // every chunk -- so a chunk that *ended* on the target is detected here rather
  // than resumed past.  Resuming from the target is only ever done deliberately, by
  // the next runTo call, which is exactly the "advance to the next occurrence" we want.
  async runTo(pc, budget = 40_000_000) {
    const t0 = this.cyc();
    const h = this.cpu.debugInstruction.add((p) => p === pc);
    try {
      while (this.cyc() - t0 < budget) {
        await this.s.runFor(CHUNK);
        if (this.cpu.pc === pc) return this.cyc() - t0;
      }
    } finally { h.remove(); }
    throw new Error(`runTo(${pc.toString(16)}) timed out after ${budget} cycles`);
  }

  // ---- render-work measurement, with the interrupt separated out ------------------
  // The window is select_backbuf..render_done (render_frame opens with wait_flip, an
  // idle spin of 6-23k cycles that is not work).  The vsync/timer ISR fires inside
  // that window, and how many times depends on where the CRTC phase happens to sit --
  // so it is accounted separately rather than left to pollute the figure.
  // Also counts instructions retired in the window.  Cycles move when code moves --
  // a taken branch costs an extra cycle across a page -- so for a change of a few
  // hundred cycles the cycle figure cannot tell a real win from a relocation.  The
  // instruction count can: it is exactly what the code did, wherever it sits.
  installMeter() {
    // 'work' is the render window.  'logic' is frame_top..render_frame, the two game
    // steps -- about 18000 cycles a frame, and invisible to the render figure, so a
    // change to the logic measures as nothing at all unless it is timed separately.
    const A = this.A, m = { work: 0, isr: 0, isrCount: 0, frames: 0, instrs: 0, logic: 0, logicI: 0 };
    let t0 = -1, inWin = false, isrAt = -1, exiting = false;
    this.meter = m;
    let n = 0, lt0 = -1, li = 0, inLogic = false;
    this.cpu.debugInstruction.add((pc, op) => {
      if (inWin) n++;
      if (inLogic) li++;
      if (pc === A.frame_top) { lt0 = this.cyc(); inLogic = true; li = 0; }
      else if (pc === A.render_frame && inLogic) { m.logic = this.cyc() - lt0; m.logicI = li; inLogic = false; }
      if (pc === A.select_backbuf) { t0 = this.cyc(); inWin = true; m.isr = 0; m.isrCount = 0; n = 0; }
      else if (pc === A.render_done && inWin) { m.work = this.cyc() - t0; m.instrs = n; inWin = false; m.frames++; }
      else if (pc === A.irq_handler) { isrAt = this.cyc(); }
      else if (isrAt >= 0 && op === 0x40) { exiting = true; }   // RTI: measure to the
      else if (exiting) {                                       // instruction after it
        if (inWin) { m.isr += this.cyc() - isrAt; m.isrCount++; }
        exiting = false; isrAt = -1;
      }
      return false;
    });
    return m;
  }

  // ---- the scene the renderer sees ------------------------------------------------
  // Every input to render_frame's cost, named by label so it is build-independent.
  sceneRanges() {
    const A = this.A, MAXSPR = 32, MAXREC = 32;
    return [
      ["wcx", A.wcx, 2], ["wcy", A.wcy, 1], ["wfine", A.wfine, 1], ["wy", A.wy, 2],
      ["curbuf", A.curbuf, 1], ["BUF_VALID", A.BUF_VALID, 2],
      ["BUF_CX", A.BUF_CX, 4], ["BUF_CY", A.BUF_CY, 2],
      ["PART_LO", A.PART_LO, 2], ["PART_HI", A.PART_HI, 2],
      ["BARDIRTY", A.BARDIRTY, 2], ["BARBG", A.BARBG, 2],
      ["MIRR_R", A.MIRR_R, 2], ["MIRR_LO", A.MIRR_LO, 2],
      ["NSPR", A.NSPR, 1], ["SPRLIST", A.SPRLIST, 5 * MAXSPR],
      ["RECCNT", A.RECCNT, 2], ["SPRREC", A.SPRREC, 2 * MAXREC * 10], ["KEEP", A.KEEP, MAXREC],
      ["DIRTYCNT", A.DIRTYCNT, 2], ["DIRTYLIST", A.DIRTYLIST, 2 * 2 * 16],
      ["px", A.px, 2], ["py", A.py, 2], ["vx", A.vx, 2], ["vy", A.vy, 2],
      ["frame", A.frame, 2], ["health", A.health, 1], ["hurt", A.hurt, 1],
      ["level", A.level, 1], ["score", A.score, 3],
    ].filter(([, a]) => a !== undefined);
  }
  fingerprint() {
    const h = createHash("sha256"), parts = {};
    for (const [name, addr, len] of this.sceneRanges()) {
      const b = Buffer.alloc(len);
      for (let i = 0; i < len; i++) b[i] = this.rd(addr + i);
      h.update(name); h.update(b);
      parts[name] = b.toString("hex");
    }
    return { fp: h.digest("hex").slice(0, 16), parts };
  }
}

// ---- bring a build up to a level, with every game-visible patch applied -----------
export async function open({ disc, labels, level, quiet = true }) {
  const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
  const A = loadLabels(labels);
  for (const need of ["frame_top", "select_backbuf", "render_done", "irq_handler", "level_init", "title_loop", "level_loop", "scan_keys", "keys"])
    if (A[need] === undefined) throw new Error(`labels are missing ${need} -- rebuild?`);
  const s = new MachineSession("Master");
  await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const H = new Harness(s, A);
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  await H.runTo(A.title_loop, 120_000_000);
  H.wr(A.title_loop, 0xa9); H.wr(A.title_loop + 1, 0); H.wr(A.title_loop + 2, 0xea);
  let ok = false;
  for (let a = A.level_loop; a < A.level_loop + 16; a++)
    if (H.rd(a) === 0xa6 && H.rd(a + 1) === (A.level & 255)) { H.wr(a, 0xa2); H.wr(a + 1, level); ok = true; break; }
  if (!ok) throw new Error("ldx level not found in level_loop");
  await H.runTo(A.level_init, 40_000_000);
  H.wr(A.scan_keys, 0x60);                       // inputs come from the harness only
  const blink = patchBlink(H);
  if (blink !== 1 && !quiet) console.error(`WARNING: blink test matched ${blink} sites (expected 1)`);
  await H.runTo(A.frame_top, 40_000_000);        // from here on, everything is frames
  H.installMeter();
  return H;
}

// While 'hurt' is set the player is drawn only when (frame & 3) == 0, so a naive
// measurement sees a 3/4-absent player.  Patch 'lda hurt' to 'lda #0' so the draw is
// unconditional; zeroing 'hurt' itself would also strip her invulnerability and let a
// hit zero 'control', which changes how many frames a run takes.
export function patchBlink(H) {
  const ROMSEL = 0xfe30, keep = H.rd(0xf4), A = H.A;
  H.wr(ROMSEL, 7);
  const hits = [];
  for (let a = 0x8000; a < 0xc000 - 8; a++)
    if (H.rd(a) === 0xa5 && H.rd(a + 1) === A.hurt && H.rd(a + 2) === 0xf0 && H.rd(a + 4) === 0xa5 &&
        H.rd(a + 5) === (A.frame & 255) && H.rd(a + 6) === 0x29 && H.rd(a + 7) === 0x03 && H.rd(a + 8) === 0xd0) hits.push(a);
  for (const a of hits) { H.wr(a, 0xa9); H.wr(a + 1, 0x00); }
  H.wr(ROMSEL, keep);
  return hits.length;
}
