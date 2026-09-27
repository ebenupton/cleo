// Cleo's harness: beebgame's (beebgame/test/lib/harness.mjs) with Cleo's scene and the
// way into a level through Cleo's own title.
import { Harness, findJsbeeb, loadLabels, loadBanks, dbgPath } from "../beebgame/test/lib/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
export * from "../beebgame/test/lib/harness.mjs";

// the game state a scene is of: the player, the frame, the level
export class CleoHarness extends Harness {
  gameScene() {
    const A = this.A;
    return [["px", A.px, 2], ["py", A.py, 2], ["vx", A.vx, 2], ["vy", A.vy, 2],
            ["frame", A.frame, 2], ["health", A.health, 1], ["hurt", A.hurt, 1],
            ["level", A.level, 1], ["score", A.score, 3]];
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
  const banks = loadBanks(dbgPath(labels));
  if (!banks || banks.byName.get("frame_top") === undefined) throw new Error(`${labels}: no game.dbg beside it with the banks -- rebuild?`);
  // boot through the loader; the title is patched to start a game at once (the menus'
  // image), and the level set as the game's image comes in, as bopen.mjs does for the
  // Model B
  const s = new MachineSession("Master");
  await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  const H = new CleoHarness(s, A, banks);
  if (onSession) onSession(H);                   // (a tool's hooks, before anything runs)
  const in7 = (f) => { const was = H.rd(0xf4); H.wr(0xfe30, 7); try { return f(); } finally { H.wr(0xfe30, was); } };
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  await H.runTo(A.title_loop, 200_000_000);
  if (A.game_in !== undefined) {
    in7(() => {                                  // jsr title_menu -> lda #0 (start game); nop
      H.wr(A.title_loop, 0xa9); H.wr(A.title_loop + 1, 0); H.wr(A.title_loop + 2, 0xea);
    });
    await H.runTo(A.game_in, 200_000_000);       // the game's image is in: its level_loop
  } else in7(() => {                             // (a build before bank 7's images: one
    H.wr(A.title_loop + 5, 0xea);                //  image, the menus called from the loop)
    H.wr(A.title_loop + 3, 0xa9); H.wr(A.title_loop + 4, 0);
  });
  in7(() => {                                    // ldx level -> ldx #level
    let ok = false;
    for (let a = A.level_loop; a < A.level_loop + 24; a++)
      if (H.rd(a) === 0xa6 && H.rd(a + 1) === (A.level & 255)) { H.wr(a, 0xa2); H.wr(a + 1, level); ok = true; break; }
    if (!ok) throw new Error("ldx level not found in level_loop");
  });
  await H.runTo(A.level_init, 200_000_000);
  in7(() => H.wr(A.scan_keys, 0x60));            // inputs come from the harness only
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
