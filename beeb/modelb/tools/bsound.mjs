// Play with the jump key and capture the sound chip's writes: silence means the
// effects are not reaching the SN76489.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const frames = parseInt(process.argv[2] ?? "120"), keys = parseInt(process.argv[3] ?? "6");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(24_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const sound = s._soundChip;
console.log("sound chip:", sound ? Object.getOwnPropertyNames(Object.getPrototypeOf(sound)).join(",") : "none");
const writes = [];
if (sound) { const orig = sound.poke.bind(sound); sound.poke = (v) => { writes.push(v); return orig(v); }; }
for (let f = 0; f < frames; f++) { cpu.writemem(lab.keys, keys); await s.runFor(40000); }
console.log("sound chip writes:", writes.length);
console.log(writes.slice(0, 40).map((v) => v.toString(16)).join(" "));
process.exit(0);
