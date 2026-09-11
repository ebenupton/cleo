// Per-frame phase timer: cycles spent in the logic step(s), waiting for the flip, and
// rendering, from a scripted play session.   node tools/phase.mjs [level]
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = {}; for (const m of readFileSync(process.env.LABELS ?? "build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const lvl = parseInt(process.argv[2] ?? "0");
const s = new MachineSession(process.env.MODEL ?? "Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(process.env.SSD ?? "build/cleo.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
let hit = false; const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false)); await s.runFor(80_000_000); h.remove();
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea); { let ok = false; for (let a = A.level_loop; a < A.level_loop + 16; a++) if (rd(a) === 0xa6 && rd(a + 1) === (A.level & 255)) { wr(a, 0xa2); wr(a + 1, lvl); ok = true; break; } if (!ok) throw new Error("ldx level not found"); }
await s.runFor(9_000_000);
let lastC = cpu.currentCycles, now = 0;
const clock = () => { const c = cpu.currentCycles; let d = c - lastC; if (d < 0) d += 2_000_000; lastC = c; now += d; return now; };
let tLogic = 0, tWait = 0, tRender = 0, nLogic = 0, nRender = 0, t0 = 0, tStart = 0, ret = -1, sumLogic = [], sumRender = [], sumWait = [];
const hook = cpu.debugInstruction.add((pc) => {
    if (pc === A.game_frame) { t0 = clock(); ret = (rd(0x100 + ((cpu.s + 1) & 255)) | (rd(0x100 + ((cpu.s + 2) & 255)) << 8)) + 1; }
    else if (pc === ret) { sumLogic.push(clock() - t0); ret = -1; }
    else if (pc === A.render_frame) t0 = clock();
    else if (pc === A.select_backbuf) { const t = clock(); sumWait.push(t - t0); t0 = t; }
    else if (pc === A.render_done) sumRender.push(clock() - t0);
    return false;
});
const stat = (a) => { if (!a.length) return "n/a"; const m = a.reduce((x, y) => x + y, 0) / a.length; const mx = Math.max(...a); return `${a.length}x mean ${(m / 1000).toFixed(1)}K max ${(mx / 1000).toFixed(1)}K`; };
const report = (name) => { console.log(`${name}: logic ${stat(sumLogic)} | flip wait ${stat(sumWait)} | render ${stat(sumRender)}`); sumLogic = []; sumRender = []; sumWait = []; };
await s.runFor(4_000_000); report("standing still ");
s.keyDown(39); await s.runFor(6_000_000); report("running right  "); s.keyUp(39);
s.keyDown(13); await s.runFor(300_000); s.keyUp(13); await s.runFor(2_500_000); report("jump (vertical)");
