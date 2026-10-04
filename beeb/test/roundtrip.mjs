// Whole sessions, build against build: the title, a game, lost (the lose screen and big
// Cleo's frames), the title again, a second game, won (level 15 ended with no star
// left: the win screen), the title again -- each swap of bank 7's image with a disc
// load between.  Both builds boot through the real title (SHIFT-BREAK, no patches) and
// run the same script: RETURN (jsbeeb key 13) starts a game; a game is ended by
// writing lives = 0 (or level = 15 and stars = 0) and exiting = 1.  They are compared
// at every stop from the third on: menu_keys in the menus (the menus' bank and image:
// game.dbg, ld_img), frame_top in play (bank 7), with hurt = 1 and health = 3 written
// before each play frame.  Stops: title 6, game 30, lose 40, title 6, game 30, win 40,
// title 6 = 144 compared.
//   node test/roundtrip.mjs master|modelb <discA> <labelsA> <discB> <labelsB> [pngdir]
// BBOARD=watford|solidisk emulates a write-select board on the Model B (boards.mjs);
// BMODEL=B1770 for the 1770 machine.
// Compared: in play the painted picture (jsbeeb's frame, RGB: the ring's hidden rows
// are a layout's choice, see wincmp.mjs); in the menus main RAM from CLEAR0 (the first
// build's defs_ld.inc) to $8000 as the CPU sees it.  pngdir gets <stop>_A.ppm and
// <stop>_B.ppm (P6) at the end of each stop.
// Output: the first twelve differing stops, then "<machine> round trip: identical at
// <n> stops | DIFFERS at <n>/<stops> stops"; exit 1 on a difference.
// to() steps off a break with runFor(1), and jsbeeb then runs the rest of the
// interrupted 20000-cycle chunk, so whatever bank is paged after a stop is the CPU's
// business: the bank-7 variables (exiting, stars) are written through w7, which pages
// bank 7's socket for the write and puts ROMSEL back.
import { findJsbeeb, loadLabels, loadBanks, imgOk, dbgPath } from "./harness.mjs";
import { boardEmu } from "./bopen.mjs";
import { pathToFileURL } from "node:url"; import path from "node:path"; import { writeFileSync } from "node:fs";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const [kind, dA, lA, dB, lB, png] = process.argv.slice(2);
async function boot(disc, labels) {
  const s = new MachineSession(kind === "master" ? "Master" : (process.env.BMODEL ?? "B-DFS1.2")); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const cpu = s._machine.processor, A = loadLabels(labels), banks = loadBanks(dbgPath(labels));
  if (kind !== "master" && process.env.BBOARD) boardEmu(cpu, process.env.BBOARD);
  const P = kind === "master" ? [4, 5, 6, 7] : cpu.model.swram.map((r, i) => (r ? i : -1)).filter((i) => i >= 0).slice(0, 4);
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  const bankOf = (n) => P[banks.byName.get(n) - 4];
  const at = (n) => cpu.pc === A[n] && cpu.readmem((A.romsel_cpy ?? 0xf4)) === bankOf(n) && imgOk(cpu, A, banks, A[n]);
  async function to(n, budget = 6000) {
    const h = cpu.debugInstruction.add(() => at(n));
    try { for (let i = 0; i < budget; i++) { await s.runFor(20000); if (at(n)) { await s.runFor(1); return; } } } finally { h.remove(); }
    throw new Error(`${n} not reached`);
  }
  // a bank-7 variable written with bank 7 paged for the write, then ROMSEL back to the
  // game's copy (romsel_cpy: the Model B's ROMSEL is write-only, so it cannot be read)
  const w7 = (a, v) => { const cp = (A.romsel_cpy ?? 0xf4); cpu.writemem(0xfe30, P[3]); cpu.writemem(a, v); cpu.writemem(0xfe30, cpu.readmem(cp)); };
  return { s, cpu, A, to, w7 };
}
const X = await boot(dA, lA), Y = await boot(dB, lB);
const both = async (f) => { for (const M of [X, Y]) await f(M); };
let bad = 0, stops = 0;
function cmp(what, k, painted) {
  let n = 0;
  if (painted) {                     // in play: the picture (the ring's hidden rows are a
    const fa = X.s._completeFb8, fb = Y.s._completeFb8;   // layout's choice: wincmp.mjs); RGBA, alpha skipped
    for (let i = 0; i < fa.length; i += 4) if (fa[i] !== fb[i] || fa[i + 1] !== fb[i + 1] || fa[i + 2] !== fb[i + 2]) n++;
  } else {                           // the menus' clear to $8000: CLEAR0 (the build's
    const c0 = X.A.CLEAR0 ?? (kind === "master" ? 0x3000 : 0x0800);   // defs_ld.inc; the literals
    for (let a = c0; a < 0x8000; a++) if (X.cpu.readmem(a) !== Y.cpu.readmem(a)) n++;   // for an older build)
  }
  stops++;
  if (n) { bad++; if (bad <= 12) console.log(`  ${what} ${k}: ${n} bytes differ`); }
}
function shot(name) {
  if (!png) return;
  for (const [t, M] of [["A", X], ["B", Y]]) {
    const fb = M.s._completeFb8, W = 1024, H = fb.length / 4 / W, px = Buffer.alloc(W * H * 3);
    for (let i = 0; i < W * H; i++) { px[i * 3] = fb[i * 4]; px[i * 3 + 1] = fb[i * 4 + 1]; px[i * 3 + 2] = fb[i * 4 + 2]; }
    writeFileSync(`${png}/${name}_${t}.ppm`, Buffer.concat([Buffer.from(`P6 ${W} ${H} 255\n`), px]));
  }
}
const press = async (M, key) => { M.s.keyDown(key); await M.s.runFor(150_000); M.s.keyUp(key); };
async function menu(what, n) { for (let k = 0; k < n; k++) { await both((M) => M.to("menu_keys")); if (k >= 2) cmp(what, k); } shot(what); }
async function play(what, n) {
  for (let k = 0; k < n; k++) { await both(async (M) => { M.cpu.writemem(M.A.hurt, 1); M.cpu.writemem(M.A.health, 3); await M.to("frame_top", 60000); }); if (k >= 2) cmp(what, k, true); }
  shot(what);
}
await menu("title", 6);
await both((M) => press(M, 13)); await play("game1", 30);
await both((M) => { M.cpu.writemem(M.A.lives, 0); M.w7(M.A.exiting, 1); });
await menu("lose", 40);
await both((M) => press(M, 13)); await menu("title2", 6);
await both((M) => press(M, 13)); await play("game2", 30);
await both((M) => { M.cpu.writemem(M.A.level, 15); M.w7(M.A.stars, 0); M.w7(M.A.exiting, 1); });
await menu("win", 40);
await both((M) => press(M, 13)); await menu("title3", 6);
console.log(`${kind} round trip: ${bad ? `DIFFERS at ${bad}/${stops} stops` : `identical at ${stops} stops`}`);
process.exit(bad ? 1 : 0);
