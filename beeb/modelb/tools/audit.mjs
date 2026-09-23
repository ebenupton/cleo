// Every store into sideways RAM ($8000-$BFFF) during play, by PC + selected bank.
// These are the sites whose WRITE bank must be right on a Solidisk/Watford board.
import { openB } from "/Users/ebenupton/cleo/beeb/modelb/tools/bopen.mjs";
const B = await openB({ level: parseInt(process.argv[3] ?? "4") }); const { cpu, A } = B;
const frames = parseInt(process.argv[2] ?? "300");
const names = Object.entries(A).sort((a, b) => a[1] - b[1]);
const nm = (pc) => { let best = null; for (const [n2, a] of names) if (a <= pc && (!best || a > best[1])) best = [n2, a]; return best ? `${best[0]}+${(pc - best[1]).toString(16)}` : "?"; };
const byPc = new Map();
cpu.debugWrite.add((addr) => {
  if (addr >= 0x8000 && addr < 0xc000) {
    const b = cpu.readmem(0xf4), k = (b << 24) | cpu.pc;
    if (!byPc.has(k)) byPc.set(k, 0); byPc.set(k, byPc.get(k) + 1);
  }
  return false;
});
let rng = 7; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16); let keys = 0, hold = 0;
for (let f = 0; f < frames; f++) {
  if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 16, 2|16, 1|16, 8][rnd() % 10]; hold = 4 + rnd() % 40; }
  cpu.writemem(A.keys, keys); await B.runTo(A.frame_top, 7);
}
const rows = [...byPc.entries()].sort((a, b) => b[1] - a[1]);
console.log(`sideways-RAM stores during play (level ${process.argv[3] ?? 4}, ${frames} frames):`);
for (const [k, c] of rows) { const b = (k >>> 24) & 15, pc = k & 0xffffff; console.log(`  ${(c/frames).toFixed(1).padStart(7)}/frame  socket ${b}  pc $${pc.toString(16)} ${nm(pc)}`); }
