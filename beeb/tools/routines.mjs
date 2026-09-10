// Inclusive/self cycles per routine label over a scripted window.  node tools/routines.mjs [level] [mode]
// mode: still | run | jump ; prints self time per label (nearest preceding code label) and call counts.
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const lvl = parseInt(process.argv[2] ?? "0"), mode = process.argv[3] ?? "still";
// label table sorted by address (code labels only: below $8000 or $C000-$DFFF)
const labs = Object.entries(A).filter(([n, a]) => (a < 0x8000 && a >= 0x400) || (a >= 0xc000 && a < 0xe000)).sort((x, y) => x[1] - y[1]);
const labAt = new Array(65536).fill(null); { let i = 0; for (let pc = 0; pc < 65536; pc++) { while (i + 1 < labs.length && labs[i + 1][1] <= pc) i++; labAt[pc] = labs[i][1] <= pc ? labs[i][0] : null; } }
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleo.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
let hit = false; const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false)); await s.runFor(80_000_000); h.remove();
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea); { let ok = false; for (let a = A.level_loop; a < A.level_loop + 16; a++) if (rd(a) === 0xa6 && rd(a + 1) === (A.level & 255)) { wr(a, 0xa2); wr(a + 1, lvl); ok = true; break; } if (!ok) throw new Error("ldx level not found"); }
await s.runFor(9_000_000);
if (mode === "run") { s.keyDown(39); await s.runFor(1_000_000); }
if (mode === "jump") { s.keyDown(13); }
const self = {}, calls = {};
let lastPc = -1, lastC = cpu.currentCycles, total = 0, renders = 0;
cpu.debugInstruction.add((pc) => {
    const c = cpu.currentCycles; let d = c - lastC; if (d < 0) d += 2_000_000; lastC = c;
    if (lastPc >= 0) { const l = labAt[lastPc] ?? "?"; self[l] = (self[l] || 0) + d; total += d; }
    if (A[labAt[pc]] === pc && (lastPc < 0 || labAt[lastPc] !== labAt[pc])) calls[labAt[pc]] = (calls[labAt[pc]] || 0) + 1;
    if (pc === A.render_frame) renders++;
    lastPc = pc; return false;
});
await s.runFor(mode === "jump" ? 300_000 : 3_000_000);
if (mode === "jump") { s.keyUp(13); await s.runFor(2_000_000); }
console.log(`${mode} level ${lvl}: ${renders} renders in ${(total / 1e6).toFixed(2)}M cycles = ${(total / renders / 1000).toFixed(1)}K per render`);
for (const [l, c] of Object.entries(self).sort((a, b) => b[1] - a[1]).slice(0, 28)) console.log(`  ${l.padEnd(18)} ${(100 * c / total).toFixed(1).padStart(5)}%  ${(c / renders / 1000).toFixed(1).padStart(6)}K/render  x${((calls[l] || 0) / renders).toFixed(1)}`);
