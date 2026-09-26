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

// A banked build (the Model B's layout, on either machine) has code and state in
// sideways RAM, where one address names a different byte in each bank: the linker's
// debug file says which bank each label is in (by its segment), so a PC break waits
// for that bank to be paged ($F4, ROMSEL's copy) and a state read pages it first.
const SEGBANK = [[/^(COMMON4|SPR4)/, 4], [/^(COMMON5|TIL|MNU)/, 5], [/^(COMMON6|MAPLO|SPR6)/, 6],
                 [/^(COMMON7|LGC)/, 7]];
export function loadBanks(dbgFile) {
  if (!existsSync(dbgFile)) return null;
  const segBank = new Map(), byName = new Map(), byPc = new Map();
  const t = readFileSync(dbgFile, "utf8");
  for (const m of t.matchAll(/^seg\tid=(\d+),name="(\w+)"/gm)) {
    const e = SEGBANK.find(([re]) => re.test(m[2]));
    if (e) segBank.set(m[1], e[1]);
  }
  if (!segBank.size) return null;
  for (const m of t.matchAll(/^sym\tid=\d+,name="(\w+)",[^\n]*?val=0x([0-9A-F]+),seg=(\d+),type=lab/gm)) {
    const b = segBank.get(m[3]);
    if (b === undefined) continue;
    byName.set(m[1], b);
    const a = parseInt(m[2], 16);
    byPc.set(a, byPc.has(a) && byPc.get(a) !== b ? -1 : b);   // (-1: two banks, ambiguous)
  }
  return { byName, byPc };
}

export class Harness {
  constructor(s, A, banks = null) { this.s = s; this.A = A; this.cpu = s._machine.processor; this.banks = banks; }
  // is the CPU at pc, in the bank that label lives in?
  at(pc, p) { if (p !== pc) return false; const b = this.banks?.byPc.get(pc); return b === undefined || b < 0 || this.cpu.readmem(0xf4) === b; }
  // is the CPU at address a, in the bank the named label lives in? (an address that is
  // no label -- the instruction after a jsr, say -- takes its bank from a neighbour)
  atIn(a, name, p) { if (p !== a) return false; const b = this.banks?.byName.get(name); return b === undefined || this.cpu.readmem(0xf4) === b; }
  // f() with the bank a named label lives in paged in (read side only)
  inBank(name, f) {
    const b = this.banks?.byName.get(name);
    if (b === undefined) return f();
    const was = this.cpu.readmem(0xf4); this.cpu.writemem(0xfe30, b);
    try { return f(); } finally { this.cpu.writemem(0xfe30, was); }
  }

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
    const h = this.cpu.debugInstruction.add((p) => this.at(pc, p));
    try {
      while (this.cyc() - t0 < budget) {
        await this.s.runFor(CHUNK);
        if (this.at(pc, this.cpu.pc)) return this.cyc() - t0;
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
      if (this.at(A.frame_top, pc)) { lt0 = this.cyc(); inLogic = true; li = 0; }
      else if (inLogic && this.at(A.render_frame, pc)) { m.logic = this.cyc() - lt0; m.logicI = li; inLogic = false; }
      // the window opens as render_frame's wait for the flip returns (its first
      // instruction is that jsr): everything the frame does after, on either layout --
      // a banked build selects the buffer through a far call, after the bar
      if (!inWin && this.atIn(A.render_frame + 3, "render_frame", pc)) { t0 = this.cyc(); inWin = true; m.isr = 0; m.isrCount = 0; n = 0; }
      else if (inWin && this.at(A.render_done, pc)) { m.work = this.cyc() - t0; m.instrs = n; inWin = false; m.frames++; }
      else if (this.at(A.irq_handler, pc)) { isrAt = this.cyc(); }
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
      ["curbuf", A.curbuf, 1],   // (not BUF_VALID: the Master encodes it in BUF_CX now)
      ["BUF_CX", A.BUF_CX, 4], ["BUF_CY", A.BUF_CY, 2],
      ["BARDIRTY", A.BARDIRTY, 1],   // (one byte: one bar; not BARBG, gone)
      ["MIRR_R", A.MIRR_R, 2], ["MIRR_LO", A.MIRR_LO, 2],
      ["NSPR", A.NSPR, 1], ["SPRLIST", A.SPRLIST, 5 * MAXSPR, "sprites"],
      ["RECCNT", A.RECCNT, 2], ["SPRREC", A.SPRREC, 2 * MAXREC * 10, "rec"], ["KEEP", A.KEEP, MAXREC, "keep"],
      ["DIRTYCNT", A.DIRTYCNT, 2], ["DIRTYLIST", A.DIRTYLIST, 2 * 2 * 64, "dirty"],
      ["px", A.px, 2], ["py", A.py, 2], ["vx", A.vx, 2], ["vy", A.vy, 2],
      ["frame", A.frame, 2], ["health", A.health, 1], ["hurt", A.hurt, 1],
      ["level", A.level, 1], ["score", A.score, 3],
    ].filter(([, a]) => a !== undefined);
  }
  fingerprint() {
    const h = createHash("sha256"), parts = {};
    for (const [name, addr, len, kind] of this.sceneRanges()) {
      const b = Buffer.alloc(len);
      if (kind === "dirty") {         // each buffer's list up to its count: the capacity
        const cap = (this.A.DIRTYCNT - this.A.DIRTYLIST) / 4;   // (DIRTYMAX) is a build choice
        const n = cap >= 1 && cap <= 64 && Number.isInteger(cap) ? cap : 16;
        for (let bf = 0; bf < 2; bf++) { const c = Math.min(this.rd(this.A.DIRTYCNT + bf), n);
          for (let i = 0; i < 2 * c; i++) b[bf * 128 + i] = this.rd(this.A.DIRTYLIST + bf * 2 * n + i); }
      } else if (kind === "sprites" && this.A.SPR_XL !== undefined) {   // five arrays: as id,xl,xh,yl,yh records
        // (each array to its own length, MAXSPR being a build's choice; the rest zero)
        const n = Math.min(len / 5, this.A.SPR_XL - this.A.SPR_ID), F = [this.A.SPR_ID, this.A.SPR_XL, this.A.SPR_XH, this.A.SPR_YL, this.A.SPR_YH];
        this.inBank("SPR_ID", () => { for (let i = 0; i < n; i++) for (let k = 0; k < 5; k++) b[i * 5 + k] = F[k] < 0x10000 ? this.rd(F[k] + i) : 0; });
      } else if (kind === "rec" || kind === "keep") {   // per buffer, the records it holds
        // (MAXREC is a build's choice: each buffer's live records, the rest zero)
        const mr = (this.A.RECCNT - this.A.SPRREC) / 20, cap = len / (kind === "rec" ? 20 : 1);
        this.inBank("SPRREC", () => {
          if (kind === "keep") { for (let i = 0; i < Math.min(mr, cap); i++) b[i] = this.rd(addr + i); return; }
          for (let bf = 0; bf < 2; bf++) {
            const c = Math.min(this.rd(this.A.RECCNT + bf), mr, cap);
            for (let i = 0; i < c * 10; i++) b[bf * cap * 10 + i] = this.rd(this.A.SPRREC + bf * mr * 10 + i);
          }
        });
      } else this.inBank(name, () => { for (let i = 0; i < len; i++) b[i] = this.rd(addr + i); });
      h.update(name); h.update(b);
      parts[name] = b.toString("hex");
    }
    return { fp: h.digest("hex").slice(0, 16), parts };
  }
}

// ---- bring a build up to a level, with every game-visible patch applied -----------
// HARNESS_ALLOW_DAMAGE=1 stops the driver pinning 'hurt', so enemies can actually
// connect.  Knockback states (an object's C and D carrying a 16-bit throw offset, say)
// are unreachable otherwise, and a field's range measured without them is not its range.
// Health stays pinned either way: a death leaves the frame loop and the run just hangs.
export const ALLOW_DAMAGE = !!process.env.HARNESS_ALLOW_DAMAGE;
export async function open({ disc, labels, level, quiet = true, onSession = null }) {
  const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
  const A = loadLabels(labels);
  const banks = loadBanks(path.join(path.dirname(labels), "cleo.dbg"));
  if (banks && banks.byName.get("frame_top") !== undefined) return openBanked({ MachineSession, disc, A, banks, level, quiet, onSession });
  for (const need of ["frame_top", "select_backbuf", "render_done", "irq_handler", "level_init", "title_loop", "level_loop", "scan_keys", "keys"])
    if (A[need] === undefined) throw new Error(`labels are missing ${need} -- rebuild?`);
  const s = new MachineSession("Master");
  await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const H = new Harness(s, A);
  if (onSession) onSession(H);                   // (a tool's hooks, before anything runs)
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

// A banked build (the converged Master: modelb/build.sh TARGET=master) boots through
// the Model B's loader, and its game loop is bank 7's: the title and the level are
// patched there, as modelb/tools/bopen.mjs does for the Model B.
async function openBanked({ MachineSession, disc, A, banks, level, quiet, onSession }) {
  const s = new MachineSession("Master");
  await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const H = new Harness(s, A, banks);
  if (onSession) onSession(H);
  const in7 = (f) => { const was = H.rd(0xf4); H.wr(0xfe30, 7); try { return f(); } finally { H.wr(0xfe30, was); } };
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  await H.runTo(A.title_loop, 200_000_000);
  in7(() => {
    H.wr(A.title_loop + 5, 0xea);                 // keep jsr ensure_menu; jsr t_title_menu ->
    H.wr(A.title_loop + 3, 0xa9); H.wr(A.title_loop + 4, 0);   // "start game"
    let ok = false;
    for (let a = A.level_loop; a < A.level_loop + 24; a++)
      if (H.rd(a) === 0xa6 && H.rd(a + 1) === (A.level & 255)) { H.wr(a, 0xa2); H.wr(a + 1, level); ok = true; break; }
    if (!ok) throw new Error("banked: ldx level not found in level_loop");
  });
  await H.runTo(A.level_init, 200_000_000);
  if (banks.byName.get("scan_keys") === undefined) H.wr(A.scan_keys, 0x60);   // (main RAM)
  else in7(() => H.wr(A.scan_keys, 0x60));
  const blink = patchBlink(H);
  if (blink !== 1 && !quiet) console.error(`WARNING: blink test matched ${blink} sites (expected 1)`);
  await H.runTo(A.frame_top, 40_000_000);
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
