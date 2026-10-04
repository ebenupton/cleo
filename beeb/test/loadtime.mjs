// How long a level load takes: CPU cycles (2 MHz) from level_loop to level_init, both
// in bank 7 -- the load itself, with the palette black -- for the level's FIRST load
// (the resident sets come in with it) and a SECOND (after the first frame_top,
// 'exiting' is set so the level ends and loads again; the open's `ldx #level` patch
// pins the level number, so it is the same level, as it would stand after any other).
// Opened by harness.mjs open (Master) or bopen.mjs openB (Model B) with an onSession
// hook, so the first load is timed too.
//   node test/loadtime.mjs master|modelb <disc> <labels> <level>
// Output: "<machine> L<n>: first load <s> s, second <s> s".
import { open } from "./harness.mjs";
import { openB } from "./bopen.mjs";
const [kind, disc, labels, lvS] = process.argv.slice(2);
const lv = +lvS, times = [];
let t0 = -1;
function hook(cpu, A, cyc, inBank7) {
  cpu.debugInstruction.add((pc) => {
    if (pc === A.level_loop && inBank7()) t0 = cyc();
    else if (pc === A.level_init && inBank7() && t0 >= 0) { times.push(cyc() - t0); t0 = -1; }
    return false;
  });
}
if (kind === "modelb") {
  const B = await openB({ level: lv, disc, labels, onSession: ({ cpu, A, cyc, PB }) => hook(cpu, A, cyc, () => cpu.readmem((A.romsel_cpy ?? 0xf4)) === PB(7)) });
  B.bank(7, () => B.cpu.writemem(B.A.exiting, 1));
  await B.runTo(B.A.level_init, 7, 60000);
} else {
  const H = await open({ disc, labels, level: lv, onSession: (H) => hook(H.cpu, H.A, () => H.cyc(), () => H.cpu.readmem((H.A.romsel_cpy ?? 0xf4)) === 7) });
  H.wr(H.A.exiting, 1);
  await H.runTo(H.A.level_init, 400_000_000);
}
const s = (c) => (c / 2e6).toFixed(2);
console.log(`${kind} L${lv}: first load ${s(times[0])} s, second ${s(times[1])} s`);
process.exit(0);
