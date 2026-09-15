import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
const addr = lab[process.argv[2] ?? "wcy"];
let armed = false, last = null, log = [];
cpu.debugInstruction.add((pc) => {
  if (!armed) { if (pc === 0x8100) armed = true; return false; }
  const v = cpu.readmem(addr);
  if (v !== last && log.length < 12) { log.push(`$${addr.toString(16)} = ${v} at pc=$${cpu.pc.toString(16)} (romsel ${cpu.readmem(0xf4)})`); last = v; }
  return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(8_000_000);
console.log(log.join("\n"));
process.exit(0);
