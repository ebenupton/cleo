// Two builds in lock step: the game's state at every frame_top -- every object's
// fields (LV_OBJST: 16 arrays of OBJN), Cleo's (px..health, score, stars, lives), and
// the sprite list the frame drew (SPR_ID/X/Y) -- over fwork.mjs's seeded key script.
// For a logic change meant to be behaviour-neutral: prints the first frame and field
// that differ, per level.  (Master: the harness's machine.)
//   node test/statecmp.mjs <discA> <labelsA> <discB> <labelsB> [frames=600] [seeds=1,2] [levels=0-15]
import { open } from "./harness.mjs";
const [dA, lA, dB, lB, fr = "600", sd = "1,2", lv = "0-15"] = process.argv.slice(2);
const levels = lv.includes("-") ? (([a, b]) => Array.from({ length: b - a + 1 }, (_, i) => a + i))(lv.split("-").map(Number)) : lv.split(",").map(Number);
const ZP = ["px", "py", "vx", "vy", "health", "score", "stars", "lives", "facing", "bactive", "bx", "by", "hurt", "wx", "wy"];
let bad = 0;
for (const level of levels) for (const seed of sd.split(",").map(Number)) {
  const A = await open({ disc: dA, labels: lA, level }), B = await open({ disc: dB, labels: lB, level });
  const OBJN = (A.A.LV_GRID - A.A.LV_OBJST) / 16;
  const snap = (H) => {
    const r = [], a = H.A;
    for (let i = 0; i < 16 * OBJN; i++) if (i >= OBJN) r.push(H.cpu.readmem(a.LV_OBJST + i)); // (O_STAMP, the first array, is the walk's)
    for (const n of ZP) if (a[n] !== undefined) { r.push(H.cpu.readmem(a[n])); r.push(H.cpu.readmem(a[n] + 1)); }
    const ns = H.cpu.readmem(a.NSPR); r.push(ns);
    for (let i = 0; i < ns; i++) for (const t of ["SPR_ID", "SPR_XL", "SPR_XH", "SPR_YL", "SPR_YH"]) r.push(H.cpu.readmem(a[t] + i));
    return r;
  };
  let rng = seed >>> 0; const rnd = () => (rng = (rng * 1103515245 + 12345) >>> 0, rng >>> 16);
  let keys = 0, hold = 0, first = -1;
  for (let f = 0; f < +fr && first < 0; f++) {
    if (hold-- <= 0) { keys = [0, 1, 2, 2|4, 1|4, 4, 8, 2|8, 1|8][rnd() % 9]; hold = 4 + rnd() % 40; }
    A.wr(A.A.keys, keys); B.wr(B.A.keys, keys);
    let ea = false, eb = false;                           // a run past the level's end (death, the exit) times out
    try { await A.runTo(A.A.frame_top); } catch { ea = true; }
    try { await B.runTo(B.A.frame_top); } catch { eb = true; }
    if (ea || eb) { if (ea !== eb) { first = f; console.log(`L${level} seed ${seed}: frame ${f}: only ${ea ? "A" : "B"} left the level`); } else { console.log(`L${level} seed ${seed}: both left the level at frame ${f}`); first = -2; } break; }
    const sa = snap(A), sb = snap(B);
    for (let i = 0; i < sa.length || i < sb.length; i++) if (sa[i] !== sb[i]) { first = f; console.log(`L${level} seed ${seed}: frame ${f} differs at item ${i} (${sa[i]} vs ${sb[i]})`); break; }
  }
  if (first === -1) console.log(`L${level} seed ${seed}: ${fr} frames identical`); else if (first >= 0) bad++;
}
console.log(bad ? `${bad} runs differ` : "all identical");
process.exit(bad ? 1 : 0);
