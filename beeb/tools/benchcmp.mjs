// Compare bench2 runs across builds.   node tools/benchcmp.mjs <a.json> <b.json> ...
//
// Reports two separate things, because they mean different things:
//   SCENE    -- do all builds agree on the fingerprint at this location?  If not, they
//               were measured with the world in different states and the cycle figures
//               are not comparable at all.  This is the property a harness can and must
//               make invariant to code size and placement.
//   CYCLES   -- the spread in render work where the scene DOES agree.  This is not
//               expected to be zero: a taken 6502 branch costs an extra cycle when its
//               target lies on another page, and an indexed access costs one when it
//               crosses a page, so relocating code genuinely changes the count.  What
//               matters is that the spread is that size (tens of cycles) and not the
//               size of a different scene (thousands).
import { readFileSync } from "node:fs";
import path from "node:path";
const files = process.argv.slice(2);
if (files.length < 2) { console.error("need two or more bench2 json files"); process.exit(2); }
const runs = files.map((f) => ({ name: path.basename(path.dirname(f)) || path.basename(f, ".json"), d: JSON.parse(readFileSync(f, "utf8")) }));
const n = runs[0].d.samples.length;
for (const r of runs) if (r.d.samples.length !== n) { console.error(`${r.name}: ${r.d.samples.length} samples, expected ${n}`); process.exit(2); }

const pct = (v) => (v * 100).toFixed(1) + "%";
let sceneOk = 0, worst = { jump: 0, run: 0 }, spreads = { jump: [], run: [] }, mism = [];
console.log(`comparing ${runs.length} builds x ${n} locations on L${runs[0].d.lv}`);
console.log(`${"loc".padEnd(11)} scene   jump spread   run spread   f0`);
for (let i = 0; i < n; i++) {
  const ss = runs.map((r) => r.d.samples[i]);
  const s0 = ss[0];
  const same = (k) => ss.every((s) => s[k] === s0[k]);
  const ok = same("fp0") && same("fpRun") && same("f0") && same("vx");
  if (ok) sceneOk++;
  else mism.push({ i, loc: `${s0.px},${s0.py}`, fp0: [...new Set(ss.map((s) => s.fp0))].length, fpRun: [...new Set(ss.map((s) => s.fpRun))].length, f0: [...new Set(ss.map((s) => s.f0))], vx: [...new Set(ss.map((s) => s.vx))] });
  const sp = (k) => { const v = ss.map((s) => s[k]).filter((x) => x != null); return v.length ? Math.max(...v) - Math.min(...v) : null; };
  const sj = sp("jump"), sr = sp("run");
  if (ok) { spreads.jump.push(sj); spreads.run.push(sr); worst.jump = Math.max(worst.jump, sj); worst.run = Math.max(worst.run, sr); }
  console.log(`${(s0.px + "," + s0.py).padEnd(11)} ${ok ? "same  " : "DIFFER"}  ${String(sj).padStart(11)}  ${String(sr).padStart(11)}   ${same("f0") ? s0.f0 : [...new Set(ss.map((s) => s.f0))].join("/")}`);
}
console.log(`\nSCENE: ${sceneOk}/${n} locations identical across all ${runs.length} builds (${pct(sceneOk / n)})`);
if (mism.length) {
  console.log("mismatching locations (cycle figures here are NOT comparable):");
  for (const m of mism) console.log(`  ${m.loc}: ${m.fp0} distinct fp0, ${m.fpRun} distinct fpRun, f0 ${m.f0.join("/")}, vx ${m.vx.join("/")}`);
}
const med = (a) => { a = [...a].sort((x, y) => x - y); return a.length ? a[a.length >> 1] : 0; };
// Signed deltas against the first file, over the locations whose scene matched.  With
// two builds this is the answer; the spread above is the right summary for more.
for (let r = 1; r < runs.length; r++) {
  const ds = { jump: [], run: [] }, nz = [];
  for (let i = 0; i < n; i++) {
    if (mism.some((m) => m.i === i)) continue;
    const a = runs[0].d.samples[i], b = runs[r].d.samples[i];
    for (const k of ["jump", "run"]) if (a[k] != null && b[k] != null) ds[k].push(b[k] - a[k]);
    for (const k of ["jumpI", "runI"]) if (a[k] != null && b[k] != null) (ds[k] ??= []).push(b[k] - a[k]);
    const dj = (b.jump ?? 0) - (a.jump ?? 0), dr = (b.run ?? 0) - (a.run ?? 0);
    if (dj || dr) nz.push(`${a.px},${a.py}:${dj >= 0 ? "+" : ""}${dj}/${dr >= 0 ? "+" : ""}${dr}`);
  }
  const sum = (a) => a.reduce((x, y) => x + y, 0);
  console.log(`\n${runs[r].name} - ${runs[0].name}:  d(jump) median ${med(ds.jump)} mean ${Math.round(sum(ds.jump) / (ds.jump.length || 1))};  d(run) median ${med(ds.run)} mean ${Math.round(sum(ds.run) / (ds.run.length || 1))}`);
  console.log(`  locations that moved at all (jump/run): ${nz.length ? nz.join("  ") : "none"}`);
  if (ds.jumpI?.length) console.log(`  INSTRUCTIONS retired (placement-independent): d(jump) median ${med(ds.jumpI)};  d(run) median ${med(ds.runI)}`);
}
if (sceneOk) {
  console.log(`CYCLES where the scene matches: jump spread median ${med(spreads.jump)} worst ${worst.jump}; run spread median ${med(spreads.run)} worst ${worst.run}`);
  const base = runs[0].d.samples.filter((_, i) => !mism.some((m) => m.i === i));
  const rel = Math.max(worst.jump, worst.run) / med(base.map((s) => s.jump || 0).filter(Boolean));
  console.log(`worst spread is ${pct(rel)} of a typical frame`);
}
process.exit(sceneOk === n ? 0 : 1);
