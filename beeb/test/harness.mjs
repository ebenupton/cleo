// Cleo's harness: beebgame's (beebgame/test/lib/harness.mjs: Harness, runTo, the meter,
// the fingerprint) with Cleo's scene and the way into a level through Cleo's own title.
// Exports everything beebgame's does, plus open(), patchBlink() and ALLOW_DAMAGE.
import { Harness, findJsbeeb, loadLabels, loadBanks, dbgPath } from "../beebgame/test/lib/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
export * from "../beebgame/test/lib/harness.mjs";

// the game state a scene is of: the player, the frame, the level.
// The score as a number, whatever its encoding: BCD (3 bytes, ones first, when
// hi_score follows it at +3 -- the current layout) or binary (2 bytes) in a build
// from before
function scoreValue(H, b) {
  const A = H.A, r = (i) => H.rd(A.score + i);
  let v;
  if (A.hi_score - A.score === 3) { v = 0; for (let i = 2; i >= 0; i--) v = v * 100 + (r(i) >> 4) * 10 + (r(i) & 15); }
  else v = r(0) | r(1) << 8;
  b.writeUIntLE(v, 0, 3);
}
export class CleoHarness extends Harness {
  gameScene() {
    const A = this.A;
    return [["px", A.px, 2], ["py", A.py, 2], ["vx", A.vx, 2], ["vy", A.vy, 2],
            ["frame", A.frame, 2], ["health", A.health, 1], ["hurt", A.hurt, 1],
            ["level", A.level, 1], ["score", A.score, 3, scoreValue]];
  }
}

// ---- bring a build up to a level, with every game-visible patch applied -----------
// open(): a jsbeeb Master booted from the disc with SHIFT-BREAK, run to title_loop
// (bank 7, the menus' image); `jsr title_menu` patched to `lda #0; nop` (A = 0: start
// a game); run to game_in (the game's image in bank 7); `ldx level` in level_loop
// turned into `ldx #level`; run to level_init; scan_keys made an rts ('keys' is only
// what a tool writes); patchBlink; run to frame_top; the meter installed.  Returns the
// CleoHarness (H.A labels and defs_ld.inc constants, H.rd/wr, H.runTo(pc, budget),
// H.meter, H.fingerprint()).  onSession(H) runs before the boot, for a tool's hooks.
// ALLOW_DAMAGE (HARNESS_ALLOW_DAMAGE=1) is exported for drivers that pin 'hurt': with
// it set they should not, so enemies can connect (knockback states are unreachable
// otherwise); health stays pinned either way, a death leaving the frame loop.  Nothing
// in this file reads it.
export const ALLOW_DAMAGE = !!process.env.HARNESS_ALLOW_DAMAGE;
export async function open({ disc, labels, level, quiet = true, onSession = null }) {
  const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
  const A = loadLabels(labels);
  const banks = loadBanks(dbgPath(labels));
  if (!banks || banks.byName.get("frame_top") === undefined) throw new Error(`${labels}: no game.dbg beside it with the banks -- rebuild?`);
  // boot through the loader; the title is patched to start a game at once (the menus'
  // image), and the level set as the game's image comes in, as bopen.mjs does for the
  // Model B.  Each runTo budget is in cycles (harness.mjs Harness.runTo).
  const s = new MachineSession("Master");
  await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const H = new CleoHarness(s, A, banks);
  if (onSession) onSession(H);                   // (a tool's hooks, before anything runs)
  // f() with bank 7 paged (ROMSEL only: the copy at romsel_cpy is left as the game had it)
  const in7 = (f) => { const was = H.rd((A.romsel_cpy ?? 0xf4)); H.wr(0xfe30, 7); try { return f(); } finally { H.wr(0xfe30, was); } };
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  await H.runTo(A.title_loop, 200_000_000);
  if (A.game_in !== undefined) {
    in7(() => {                                  // jsr title_menu -> lda #0 (A = 0: start); nop
      H.wr(A.title_loop, 0xa9); H.wr(A.title_loop + 1, 0); H.wr(A.title_loop + 2, 0xea);
    });
    await H.runTo(A.game_in, 200_000_000);       // the game's image is in: its level_loop
  } else in7(() => {                             // (a build before bank 7's images: one
    H.wr(A.title_loop + 5, 0xea);                //  image, the menus called from the loop)
    H.wr(A.title_loop + 3, 0xa9); H.wr(A.title_loop + 4, 0);
  });
  in7(() => {                                    // ldx level ($A6 zp) -> ldx #level ($A2)
    let ok = false;
    for (let a = A.level_loop; a < A.level_loop + 24; a++)
      if (H.rd(a) === 0xa6 && H.rd(a + 1) === (A.level & 255)) { H.wr(a, 0xa2); H.wr(a + 1, level); ok = true; break; }
    if (!ok) throw new Error("ldx level not found in level_loop");
  });
  await H.runTo(A.level_init, 200_000_000);
  in7(() => H.wr(A.scan_keys, 0x60));            // scan_keys -> rts: 'keys' is the harness's only
  const blink = patchBlink(H);
  if (blink !== 1 && !quiet) console.error(`WARNING: blink test matched ${blink} sites (expected 1)`);
  await H.runTo(A.frame_top, 40_000_000);        // from here on, everything is frames
  H.installMeter();
  return H;
}

// While 'hurt' is set the player is drawn only on some frames (the flashing), so a
// measurement with hurt pinned sees a part-absent player.  This looks through bank 7
// for player_update's blink test in either spelling -- today's `ldy hurt; beq; tax;
// lda frame; and #1; bne` (logic.s @spr) or older builds' `lda hurt; beq +4; lda
// frame; and #3; bne` -- and turns its load of hurt into a load of 0, so the draw is
// unconditional; zeroing 'hurt' itself would strip her invulnerability and let a hit
// zero 'control', which changes how many frames a run takes.  Returns the number of
// sites patched (open warns unless quiet when it is not 1).
export function patchBlink(H) {
  // Two spellings of player_update's blink test (logic.s @spr), old builds and new:
  //   lda hurt / beq + / lda frame / and #3 / bne         -> lda #0 (the beq is taken)
  //   ldy hurt / beq @drawp / tax / lda frame / and #1 / bne -> ldy #0 (likewise)
  // with hurt and frame in zero page (as both are); each found site is patched.
  const ROMSEL = 0xfe30, A = H.A, keep = H.rd((A.romsel_cpy ?? 0xf4));
  H.wr(ROMSEL, 7);
  const hits = [], fr = A.frame & 255;
  for (let a = 0x8000; a < 0xc000 - 9; a++) {
    const b = (i) => H.rd(a + i);
    if (b(0) === 0xa5 && b(1) === A.hurt && b(2) === 0xf0 && b(4) === 0xa5 && b(5) === fr &&
        b(6) === 0x29 && b(7) === 0x03 && b(8) === 0xd0) hits.push([a, 0xa9]);
    else if (b(0) === 0xa4 && b(1) === A.hurt && b(2) === 0xf0 && b(4) === 0xaa && b(5) === 0xa5 &&
        b(6) === fr && b(7) === 0x29 && b(8) === 0x01 && b(9) === 0xd0) hits.push([a, 0xa0]);
  }
  for (const [a, op] of hits) { H.wr(a, op); H.wr(a + 1, 0x00); }
  H.wr(ROMSEL, keep);
  return hits.length;
}
