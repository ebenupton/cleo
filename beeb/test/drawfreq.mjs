// How often each sprite id is drawn a frame, per level: every entry to draw_sprite
// (bank 7, A = the id) over the usual key script with the player unhurt, on both
// machines (their windows differ), the two averaged.  The packer weighs its
// placements by these (tools/assets.py reads tools/drawfreq.json, which this writes
// by default -- into the tree).  Each level is opened afresh on each machine
// (harness.mjs open, bopen.mjs openB); each frame is a break at frame_top with 'keys'
// from the fixed pattern PAT (s idle, r RIGHT, l LEFT, j UP) and hurt = 1, health = 3
// written there.
//   node test/drawfreq.mjs [frames=300] [out=tools/drawfreq.json]
// Output: out = {level: {id: draws a frame (3 decimals)}} for levels 0-15; progress on
// stderr; the build is build/cleo.ssd with build/<machine>/labels.txt.
import { open } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { writeFileSync } from "node:fs";

const frames = +(process.argv[2] ?? 300), outFile = process.argv[3] ?? "tools/drawfreq.json";
const PAT = "ssrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrjrjrjrjrjssllllllllllllllllllllllllllllljljljljljss";
const KK = (c) => ({ s: 0, r: 2, l: 1, j: 4 })[c] ?? 0;

async function one(machine, level) {
  const labels = `build/${machine}/labels.txt`;
  const M = machine === "master" ? await open({ disc: "build/cleo.ssd", labels, level }) : await openB({ level, disc: "build/cleo.ssd", labels });
  const cpu = M.cpu, A = M.A;
  const poke = (a, v) => (machine === "master" ? M.wr(a, v) : M.bank(7, () => cpu.writemem(a, v)));
  const sock7 = machine === "master" ? 7 : M.PB(7);
  const n = new Map();
  const hook = cpu.debugInstruction.add((pc) => {
    if (pc === A.draw_sprite && cpu.readmem((A.romsel_cpy ?? 0xf4)) === sock7) n.set(cpu.a, (n.get(cpu.a) ?? 0) + 1);
    return false;
  });
  for (let f = 0; f < frames; f++) {
    poke(A.keys, KK(PAT[f % PAT.length])); poke(A.hurt, 1); poke(A.health, 3);
    await (machine === "master" ? M.runTo(A.frame_top) : M.runTo(A.frame_top, 7));
  }
  hook.remove();
  if (M.s?.destroy) M.s.destroy();
  return Object.fromEntries([...n].map(([id, c]) => [id, c / frames]));
}

const out = {};
for (let level = 0; level < 16; level++) {
  const [a, b] = await Promise.all([one("master", level), one("modelb", level)]);
  const ids = new Set([...Object.keys(a), ...Object.keys(b)]);
  out[level] = Object.fromEntries([...ids].sort((p, q) => p - q).map((id) => [id, +(((a[id] ?? 0) + (b[id] ?? 0)) / 2).toFixed(3)]));
  console.error(`L${level}: ${ids.size} ids`);
}
writeFileSync(outFile, JSON.stringify(out, null, 1) + "\n");
console.log(`wrote ${outFile}`);
process.exit(0);
