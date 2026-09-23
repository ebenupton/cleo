// Where the rupture chain's CRTC writes land, on the CRTC's own clock: for every write
// to R9/R4/R6/R7/R12/R13 the CRTC's (row, scanline, char) at the moment of the write,
// per T1 step, for frames with a fine scroll (wfine > 0) -- the sections shorter than a
// row are where emulators disagree about when R4/R9 are compared.  Model B or Master.
//   node tools/bcrtc.mjs B|M [frames] [level]
import { openB } from "./bopen.mjs";
import { open as openMaster } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
const which = process.argv[2] ?? "B", frames = parseInt(process.argv[3] ?? "150"), LEVEL = parseInt(process.argv[4] ?? "0");
let cpu, A, runTo;
if (which === "B") { const B = await openB({ level: LEVEL }); cpu = B.cpu; A = B.A; runTo = (pc) => B.runTo(pc, 7); }
else { const M = await openMaster({ disc: "/Users/ebenupton/cleo/beeb/build/cleo.ssd", labels: "/Users/ebenupton/cleo/beeb/build/labels.txt", level: LEVEL }); cpu = M.cpu; A = M.A; runTo = (pc) => M.runTo(pc); }
const v = cpu.video;
let idx = -1, frame = 0, step = [];
const steps = [];
cpu.debugWrite.add((addr, val) => {
  if (addr === 0xfe00) idx = val;
  else if (addr === 0xfe01) {
    if (idx === 9) { step = []; steps.push({ frame, wfine: cpu.readmem(A.wfine), w: step }); }   // a step starts with R9
    step.push({ reg: idx, val, v: v.vertCounter, s: v.scanlineCounter, h: v.horizCounter });
  }
  return false;
});
cpu.debugInstruction.add((pc) => {
  if (pc === A.irq_handler && (cpu.readmem(0xfe4d) & 2)) steps.push({ frame, vsync: true, v: v.vertCounter, s: v.scanlineCounter, h: v.horizCounter });
  return false;
});
for (frame = 0; frame < frames; frame++) {
  cpu.writemem(A.keys, frame % 50 < 12 ? 16 : (frame % 50 < 30 ? 2 : 1));   // jump, then walk: the camera moves vertically
  await runTo(A.frame_top);
}
// the R9 write of every step: which scanline of the section it lands in, and where
const hist = {};
for (const st of steps) {
  if (st.vsync) continue;
  const r9 = st.w[0], r4 = st.w.find((x) => x.reg === 4);
  const k = `R9 at s=${r9.s} h=${r9.h}` + (r4 ? ` R4 at s=${r4.s} h=${r4.h}` : "");
  hist[k] = (hist[k] ?? 0) + 1;
}
console.log(`${which}: ${steps.filter((s) => !s.vsync).length} steps in ${frames} frames`);
for (const [k, n] of Object.entries(hist).sort((a, b) => b[1] - a[1])) console.log(`  ${n.toString().padStart(5)}  ${k}`);
console.log("vsync IRQ entry positions:", [...new Set(steps.filter((s) => s.vsync).map((s) => `v=${s.v} s=${s.s} h=${s.h}`))].join("  "));
// one fine-scroll frame in full
const f = steps.find((s) => !s.vsync && s.wfine > 0 && s.wfine < 7)?.frame;
if (f !== undefined) {
  console.log(`frame ${f} (wfine ${steps.find((s) => s.frame === f && !s.vsync).wfine}):`);
  for (const st of steps.filter((s) => s.frame === f)) {
    if (st.vsync) { console.log(`  vsync irq        at v=${st.v} s=${st.s} h=${st.h}`); continue; }
    console.log("  " + st.w.map((x) => `R${x.reg}=${x.val}@${x.v}/${x.s}/${x.h}`).join(" "));
  }
}
