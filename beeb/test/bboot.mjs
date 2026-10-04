// Boot the disc on a jsbeeb Model B and watch it, no patches: SHIFT-BREAK, the title,
// then RETURN (the title menu's first item starts a game), with a screenshot at each
// stage and the PC, socket and nearest label sampled so a hang shows where.
//   node test/bboot.mjs [model=B-DFS1.2] [seconds=12] [outdir=/tmp]
// model: B-DFS1.2 (the 8271) or B1770; seconds: the wait after the boot and again
// after RETURN -- it must cover the boot and the title's disc load (12 s does; at 4 s
// RETURN lands before the title is up and nothing starts).  The six "playing" samples
// are 2 s apart.
// BBOARD=watford|solidisk emulates a write-select board (beebgame/test/lib/boards.mjs);
// BSWRAM="a,b,c,..." puts the sideways RAM in those sockets (jsbeeb's own: 0-7); the
// boot loader takes the lowest four it finds, or says why not with fewer.
// Output: "t=<s> <stage>: pc <hex> bank <socket> (<label>+<off>) mus_on=<n>" per sample;
// <outdir>/b_title.png, b_level.png, b_level2.png.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { findJsbeeb, loadLabels } from "./harness.mjs";
import { boardEmu } from "./bopen.mjs";
const model = process.argv[2] ?? "B-DFS1.2", secs = parseFloat(process.argv[3] ?? "12"), out = process.argv[4] ?? "/tmp";
mkdirSync(out, { recursive: true });
const base = path.dirname(findJsbeeb()) + "/";
const { MachineSession } = await import(pathToFileURL(base + "machine-session.js"));
const A = loadLabels("build/modelb/labels.txt");
const names = new Map(Object.entries(A).map(([n, a]) => [a, n]));
const s = new MachineSession(model);
await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleo.ssd"));
const cpu = s._machine.processor;
if (process.env.BBOARD) boardEmu(cpu, process.env.BBOARD);   // a write-select board (boards.mjs)
if (process.env.BSWRAM) { const SW = process.env.BSWRAM.split(",").map(Number); cpu.model.swram = Array.from({ length: 16 }, (_, i) => SW.includes(i)); }
const where = () => { const pc = cpu.pc, b = cpu.readmem((A.romsel_cpy ?? 0xf4)); let best = null; for (const [a, n] of names) if (a <= pc && (best === null || a > best[0])) best = [a, n]; return `pc ${pc.toString(16)} bank ${b} (${best ? best[1] + "+" + (pc - best[0]).toString(16) : "?"})`; };
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
let t = 0;
const step = async (sec, label) => { for (let i = 0; i < sec * 20; i++) { await s.runFor(100_000); } t += sec; console.log(`t=${t}s ${label}: ${where()} mus_on=${cpu.readmem(A.mus_on)}`); };
await step(secs, "after boot");
writeFileSync(`${out}/b_title.png`, await s.screenshotActive());
// RETURN: the title menu's first item starts a game (menu.s title_loop)
s.keyDown(13); await s.runFor(300_000); s.keyUp(13);
await step(secs, "after RETURN");
writeFileSync(`${out}/b_level.png`, await s.screenshotActive());
for (let i = 0; i < 3; i++) { await step(2, "playing"); }
writeFileSync(`${out}/b_level2.png`, await s.screenshotActive());
s.destroy();
