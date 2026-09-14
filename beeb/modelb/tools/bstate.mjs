import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(parseInt(process.argv[2] ?? "10000000"));
const cpu = s._machine.processor, v = s._video;
const rd = (a) => cpu.readmem(a);
const lab = {}; for (const m of (await import("node:fs")).readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
const r16 = (a) => rd(a) | (rd(a + 1) << 8);
console.log("wcy", rd(lab.wcy), "wcx", r16(lab.wcx), "wfine", rd(lab.wfine), "curbuf", rd(lab.curbuf),
            "ringS", r16(lab.ringS), "barq", rd(lab.barq), "SECIDX", rd(lab.SECIDX), "DISPSECT", rd(lab.DISPSECT),
            "frame", rd(lab.frame), "vsyncs", rd(lab.vsyncs), "flipreq", rd(lab.flipreq));
console.log("crtcb", r16(lab.crtcb).toString(16), "crtcbm", r16(lab.crtcbm).toString(16), "VS2T", r16(lab.VS2T));
for (let b = 0; b < 2; b++) { let out = [];
  for (let i = 0; i < 6; i++) { const a = lab.SECTAB + b * 48 + i * 8;
    out.push(`[${i}] addr $${((rd(a) << 8) | rd(a + 1)).toString(16)} R4=${rd(a + 2)} R9=${rd(a + 3)} R6=${rd(a + 4)} R7=${rd(a + 5)} dur=${rd(a + 6) | (rd(a + 7) << 8)}`); }
  console.log(`buf ${b}: ` + out.join("\n       ")); }
console.log("CRTC now: R4", v.regs[4], "R6", v.regs[6], "R7", v.regs[7], "R9", v.regs[9], "R12/13", v.regs[12], v.regs[13]);
console.log("ring A row0:", [...Array(8)].map((_, i) => rd(0x0a80 + i).toString(16)).join(" "), " bar:", [...Array(4)].map((_, i) => rd(0x300 + i).toString(16)).join(" "));
process.exit(0);
