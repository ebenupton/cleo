import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
let armed = false, trace = [], n = 0;
cpu.debugInstruction.add((pc) => {
  if (pc === 0x8000) armed = true;
  if (armed && n < 400) { trace.push(pc); n++; }
  return false;
});
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(6_000_000);
// compress the trace into ranges
let out = [], last = -9, run = 0;
for (const p of trace) { if (p === last + 1 || p === last) { run++; last = p; continue; } if (run) out.push(`+${run}`); out.push("$" + p.toString(16)); last = p; run = 0; }
console.log(out.slice(0, 160).join(" "));
process.exit(0);
