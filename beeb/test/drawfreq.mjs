// How often each sprite id is drawn a frame, per level: every entry to drawsprite (bank
// 7, A = the id) over the usual key script with the player unhurt.  The packer weighs
// its placements by these (tools/assets.py, tools/drawfreq.json: this tool writes it,
// both machines averaged -- their windows differ).
//   node test/drawfreq.mjs [frames=300] [out=tools/drawfreq.json]
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
    if (pc === A.drawsprite && cpu.readmem(0xf4) === sock7) n.set(cpu.a, (n.get(cpu.a) ?? 0) + 1);
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
