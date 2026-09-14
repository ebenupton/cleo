import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
let done = 0, log = [];
cpu.debugInstruction.add((pc) => {
  if (pc === 0x191a && done < 4) { done++;
    log.push(`after OSFILE #${done}: A=${cpu.a} $2000=${[...Array(4)].map((_,i)=>cpu.readmem(0x2000+i).toString(16)).join(",")} fname="${[...Array(6)].map((_,i)=>String.fromCharCode(cpu.readmem(0x1975+i))).join("")}"`); }
  if (pc === 0xff1b || pc === 0xffdd) log.push(`OSFILE entry A=${cpu.a} X=${cpu.x} Y=${cpu.y}`);
  return false;
});
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await s.runFor(6_000_000);
console.log(log.slice(0, 12).join("\n"));
// where is 'fname' really?
const dis = [...Array(24)].map((_, i) => cpu.readmem(0x1968 + i).toString(16).padStart(2,"0")).join(" ");
console.log("$1968:", dis);
process.exit(0);
