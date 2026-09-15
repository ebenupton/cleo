// Who writes a given ring slot?  Log PC + bank for every write to a small address range.
import { findJsbeeb } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
const keys = parseInt(process.argv[2] ?? "6"), frames = parseInt(process.argv[3] ?? "150");
const lo = parseInt(process.argv[4], 16), hi = parseInt(process.argv[5] ?? process.argv[4], 16);
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const s = new MachineSession("B-DFS1.2");
await s.initialise(); await s.boot(30);
s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const lab = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) lab[m[2]] = parseInt(m[1], 16);
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16); await s.runFor(13_000_000);
{ const was = cpu.readmem(0xf4); cpu.writemem(0xfe30, 7); cpu.writemem(lab.scan_keys, 0x60); cpu.writemem(0xfe30, was); }
const hits = [];
let frame = 0;
let phase = "?";
cpu.debugInstruction.add((p) => {
  if (p === lab.frame_top && cpu.readmem(0xf4) === 7) { frame++; phase = "scroll"; }
  else if (p === lab.erase_old && cpu.readmem(0xf4) === 4) phase = "erase";
  else if (p === lab.draw_maprect && cpu.readmem(0xf4) === 5) hits.push(`f${frame} RECT ${phase} cx=${cpu.readmem(lab.dt_cx)} n=${cpu.readmem(lab.dt_ncx)} ty=${cpu.readmem(lab.dt_ty)} ny=${cpu.readmem(lab.dt_ny)} buf=${cpu.readmem(lab.curbuf)} wcx=${cpu.readmem(lab.wcx)} wcy=${cpu.readmem(lab.wcy)}`);
  else if (p === lab.dm_row && cpu.readmem(0xf4) === 5 && hits.length && hits[hits.length-1].includes("RECT")) hits[hits.length-1] += ` -> cx=${cpu.readmem(lab.dt_cx)} n=${cpu.readmem(lab.dt_ncx)} ty=${cpu.readmem(lab.dt_ty)} ny=${cpu.readmem(lab.dt_ny)}`;
  return false; });
cpu.debugWrite.add((addr, val) => { if (addr >= lo && addr <= hi) hits.push(`f${frame} @${addr.toString(16)}=${val.toString(16)} pc=${cpu.pc.toString(16)} bank=${cpu.readmem(0xf4)} wcx=${cpu.readmem(lab.wcx)} wcy=${cpu.readmem(lab.wcy)} buf=${cpu.readmem(lab.curbuf)} spx=${cpu.readmem(lab.spx)|(cpu.readmem(lab.spx+1)<<8)} spy=${cpu.readmem(lab.spy)|(cpu.readmem(lab.spy+1)<<8)} c0=${cpu.readmem(lab.sp_c0)} c1=${cpu.readmem(lab.sp_c1)} r0=${cpu.readmem(lab.sp_r0)} r1=${cpu.readmem(lab.sp_r1)} id=${cpu.readmem(lab.sp_id)} clip=${cpu.readmem(lab.spclip)}`); });
for (let f = 0; f < frames; f++) { cpu.writemem(lab.keys, keys); for (let i = 0; i < 400; i++) { await s.runFor(2000); if (cpu.pc === lab.frame_top && cpu.readmem(0xf4) === 7) break; } }
console.log(hits.slice(-200).join("\n"));
console.log("total", hits.length);
process.exit(0);
