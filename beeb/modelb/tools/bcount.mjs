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
const names = process.argv.slice(2).length ? process.argv.slice(2) : ["draw_maprect", "draw_tile", "map_strip", "farcall", "ring_row"];
const hit = {}; const addrs = {};
for (const n of names) { if (lab[n] === undefined) { console.log("no label", n); continue; } addrs[lab[n]] = n; hit[n] = 0; }
let firstTiles = [];
cpu.debugInstruction.add((pc) => { const n = addrs[pc]; if (n) { hit[n]++;
    if (n === "draw_tile" && firstTiles.length < 8) firstTiles.push(`id=${cpu.a} dst0=$${(cpu.readmem(lab.dst0) | (cpu.readmem(lab.dst0 + 1) << 8)).toString(16)} dst1=$${(cpu.readmem(lab.dst1) | (cpu.readmem(lab.dst1 + 1) << 8)).toString(16)}`); }
  return false; });
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(6_000_000);
console.log("counts:", hit);
console.log("first tiles:", firstTiles.join(" | "));
console.log("MAPBUF:", [...Array(20)].map((_, i) => cpu.readmem(lab.MAPBUF + i)).join(","));
console.log("FARTAB:", [...Array(15)].map((_, i) => cpu.readmem(lab.FARTAB + i).toString(16)).join(" "));
console.log("ring A row0 first 16:", [...Array(16)].map((_, i) => cpu.readmem(0x0a80 + i).toString(16)).join(" "));
process.exit(0);
