// Boot the Model B disc under jsbeeb and watch it: the title, then a game started with
// RETURN, screenshots along the way and the PC/bank sampled so a hang shows where.
//   node tools/bboot.mjs [model] [seconds] [outdir]     model: B-DFS1.2 (8271) or B1770
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { findJsbeeb, loadLabels } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
const model = process.argv[2] ?? "B-DFS1.2", secs = parseFloat(process.argv[3] ?? "12"), out = process.argv[4] ?? "/tmp";
const base = path.dirname(findJsbeeb()) + "/";
const { MachineSession } = await import(pathToFileURL(base + "machine-session.js"));
const A = loadLabels("build/labels.txt");
const names = new Map(Object.entries(A).map(([n, a]) => [a, n]));
const s = new MachineSession(model);
await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor;
const where = () => { const pc = cpu.pc, b = cpu.readmem(0xf4); let best = null; for (const [a, n] of names) if (a <= pc && (best === null || a > best[0])) best = [a, n]; return `pc ${pc.toString(16)} bank ${b} (${best ? best[1] + "+" + (pc - best[0]).toString(16) : "?"})`; };
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
let t = 0;
const step = async (sec, label) => { for (let i = 0; i < sec * 20; i++) { await s.runFor(100_000); } t += sec; console.log(`t=${t}s ${label}: ${where()} title_res=${cpu.readmem(A.title_res)} MUSON=${cpu.readmem(A.MUSON)}`); };
await step(secs, "after boot");
writeFileSync(`${out}/b_title.png`, await s.screenshotActive());
// RETURN starts the game (the title menu's first item)
s.keyDown(13); await s.runFor(300_000); s.keyUp(13);
await step(secs, "after RETURN");
writeFileSync(`${out}/b_level.png`, await s.screenshotActive());
for (let i = 0; i < 3; i++) { await step(2, "playing"); }
writeFileSync(`${out}/b_level2.png`, await s.screenshotActive());
s.destroy();
