// Run N cycles from boot and print the game's state and where the PC is.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const cycles = parseInt(process.argv[2] ?? "30000000");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(cycles);
const r = (n) => cpu.readmem(lab[n]), r16 = (n) => cpu.readmem(lab[n]) | (cpu.readmem(lab[n] + 1) << 8);
const st = {};
for (const n of ["frame","vsyncs","flipreq","flipvs","logicvs","curbuf","SECIDX","curR7","NEXTSECT","DISPSECT","exiting","lives","health","stars","level","NSPR","BARBG","BARDIRTY","wcy","wfine","barq","keys"]) st[n] = r(n);
for (const n of ["wx","wy","px","py","ringS","score"]) st[n] = r16(n);
console.log(`pc=$${cpu.pc.toString(16)} bank=${cpu.readmem(0xf4)} sp=$${cpu.s.toString(16)} ier=$${cpu.readmem(0xfe4e).toString(16)} irq1v=$${(cpu.readmem(0x204)|(cpu.readmem(0x205)<<8)).toString(16)} irq_handler=$${lab.irq_handler.toString(16)}`);
console.log(JSON.stringify(st));
// which bank-7 label is the PC in (from the map's segment ranges)
const segs = []; for (const m of readFileSync("build/map.txt", "utf8").matchAll(/^(\w+)\s+([0-9A-F]{6})\s+([0-9A-F]{6})\s+([0-9A-F]{6})/gm)) segs.push([m[1], parseInt(m[2],16), parseInt(m[3],16)]);
const bankof = { LGCLO:7, LGCENT:7, LGCCODE:7, LGCDATA:7, TILCODE:5, TILDATA:5, SPR4CODE:4, SPR6CODE:6, LOWCODE:0, MAPLO:6 };
const pc = cpu.pc, bank = cpu.readmem(0xf4);
let best = null;
for (const [n, a] of Object.entries(lab)) { if (a > pc || n.startsWith("__")) continue;
  const seg = segs.find(([sn, s0, s1]) => a >= s0 && a <= s1 && (bankof[sn] === bank || bankof[sn] === 0));
  if (!seg) continue; if (!best || a > best[1]) best = [n, a]; }
console.log("pc near", best ? `${best[0]}+${pc - best[1]}` : "?");
process.exit(0);
