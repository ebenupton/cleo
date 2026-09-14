import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const hits = {}; const want = { 0x1900: "loader", 0x8000: "bank7 entry", 0xffdd: "OSFILE" };
let first = {};
cpu.debugInstruction.add((pc) => { const w = want[pc]; if (w) { hits[w] = (hits[w] || 0) + 1; if (!(w in first)) first[w] = cpu.currentCycles; } return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(10_000_000);
console.log("hits:", hits);
console.log("pc", cpu.pc.toString(16), "romsel", cpu.readmem(0xf4).toString(16));
console.log("$1900..$1910:", [...Array(16)].map((_, i) => cpu.readmem(0x1900 + i).toString(16).padStart(2, "0")).join(" "));
// what the OS thinks PAGE is
console.log("PAGE ($18):", cpu.readmem(0x18).toString(16), " OSHWM");
process.exit(0);
