import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const lvl = parseInt(process.argv[2] ?? "0");
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleo.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
let hit = false; const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false)); await s.runFor(80_000_000); h.remove();
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea); { let ok = false; for (let a = A.level_loop; a < A.level_loop + 16; a++) if (rd(a) === 0xa6 && rd(a + 1) === (A.level & 255)) { wr(a, 0xa2); wr(a + 1, lvl); ok = true; break; } if (!ok) throw new Error("ldx level not found"); }
{   // the level load reads the tile file, so wait for the game to be drawing before
    // timing anything: otherwise the first window measures the disc, not the renderer
    let seen = 0;
    const h = cpu.debugInstruction.add((pc) => (pc === A.render_frame ? ++seen >= 8 : false));
    for (let i = 0; i < 12 && seen < 8; i++) await s.runFor(5_000_000);
    h.remove();
}
let last = -1; const periods = [];
const hook = cpu.debugInstruction.add((pc) => { if (pc === A.render_frame) { const v = rd(A.vsyncs); if (last >= 0) periods.push((v - last) & 255); last = v; } return false; });
const report = (name) => { const n = periods.length; const hist = {}; for (const p of periods) hist[p] = (hist[p] || 0) + 1; const mean = periods.reduce((a, b) => a + b, 0) / n; console.log(`${name}: ${n} renders, mean period ${mean.toFixed(2)} vsyncs = ${(50 / mean).toFixed(1)} fps; histogram ` + Object.entries(hist).sort((a, b) => a[0] - b[0]).map(([p, c]) => `${p}v:${c}`).join(" ")); periods.length = 0; last = -1; };
await s.runFor(4_000_000); report("standing still ");
s.keyDown(39); await s.runFor(6_000_000); report("running right  "); s.keyUp(39);
s.keyDown(13); await s.runFor(300_000); s.keyUp(13); await s.runFor(2_500_000); report("jump (vertical)");
