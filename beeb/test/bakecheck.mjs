// The loader's baked boxes against the packer's: build/<machine>/bakes.json (written by
// tools/assets.py: for each level its baked items -- kind, index, (x, y), (bank,
// address), the bytes) is checked byte for byte in the banks after the level's load,
// on either machine.  Each level in the range is opened afresh (harness.mjs open on the
// Master, bopen.mjs openB on the Model B) at its first frame_top; the bytes are read
// with the item's bank paged (Master: ROMSEL written straight; Model B: openB's bank()).
//   node test/bakecheck.mjs master|modelb [disc=build/cleo.ssd] [labels=build/<machine>/labels.txt] [levels=0-15]
// (levels: "a-b" or a single "a")
// Output: a line per wrong item (bytes differing, the first offset), a line per level,
// a total; exit 1 if any item is wrong.
import { open } from "./harness.mjs";
import { openB } from "./bopen.mjs";
import { readFileSync } from "node:fs";
const [machine, disc = "build/cleo.ssd", labels = `build/${machine}/labels.txt`, lv = "0-15"] = process.argv.slice(2);
const bakes = JSON.parse(readFileSync(`build/${machine}/bakes.json`));
const [l0, l1] = lv.split("-").map(Number);
let bad = 0, n = 0;
for (let L = l0; L <= (l1 ?? l0); L++) {
  const items = bakes[L] || [];
  if (!items.length) { console.log(`L${L}: none`); continue; }
  let rd;
  if (machine === "master") {
    const H = await open({ disc, labels, level: L });
    rd = (b, a) => { const was = H.rd((H.A.romsel_cpy ?? 0xf4)); H.wr(0xfe30, b); const v = H.rd(a); H.wr(0xfe30, was); return v; };
  } else {
    const B = await openB({ level: L, disc, labels });
    rd = (b, a) => B.bank(b, () => B.cpu.readmem(a));
  }
  let lbad = 0;
  for (const [kind, j, [x, y], [bank, addr], want] of items) {
    let d = 0, first = -1;
    for (let i = 0; i < want.length; i++) if (rd(bank, addr + i) !== want[i]) { d++; if (first < 0) first = i; }
    n++;
    if (d) { lbad++; console.log(`L${L} ${kind}${j} at (${x},${y}) bank ${bank} $${addr.toString(16)}: ${d}/${want.length} bytes differ, first at ${first}`); }
  }
  bad += lbad;
  console.log(`L${L}: ${items.length} items, ${lbad} wrong`);
}
console.log(`${machine}: ${n} baked items, ${bad} wrong`);
process.exit(bad ? 1 : 0);
