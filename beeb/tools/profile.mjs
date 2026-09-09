// Per-instruction cycle profiler for the Cleo BBC Master build, driving the jsbeeb core
// (the same emulator the jsbeeb MCP uses) headlessly from Node.
//   node tools/profile.mjs build/cleo.ssd build/profile.json
// Boots the disc, starts the game, then profiles a scripted play session, accumulating
// cycles and execution counts per PC. Output: {"cycles": {pc: n}, "count": {pc: n}}.
import { readdirSync, existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";

function findJsbeeb() {
    if (process.env.JSBEEB_SRC) return process.env.JSBEEB_SRC;
    const npx = path.join(homedir(), ".npm", "_npx");
    for (const d of readdirSync(npx)) {
        const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js");
        if (existsSync(p)) return p;
    }
    throw new Error("jsbeeb not found; set JSBEEB_SRC to .../jsbeeb/src/machine-session.js");
}
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));

const disc = path.resolve(process.argv[2] || "build/cleo.ssd");
const out = path.resolve(process.argv[3] || "build/profile.json");
const K = { SHIFT: 16, RETURN: 13, LEFT: 37, UP: 38, RIGHT: 39 };

const s = new MachineSession("Master");
await s.initialise();
await s.boot(30);
s.loadDisc(disc);
s.keyDown(K.SHIFT); s.reset(true); await s.runFor(2_000_000); s.keyUp(K.SHIFT);
await s.runFor(42_000_000);                 // *RUN CLEO, load, title
const tap = async (k, hold, after) => { s.keyDown(k); await s.runFor(hold); s.keyUp(k); await s.runFor(after); };
await tap(K.RETURN, 300_000, 3_000_000);   // title -> menu
await tap(K.RETURN, 300_000, 4_000_000);   // START GAME -> level 0

// ---- profile
const cpu = s._machine.processor;
const cyc = new Float64Array(65536), cnt = new Uint32Array(65536);
let lastPc = -1, lastC = cpu.currentCycles;
cpu.debugInstruction.add((pc) => {
    const now = cpu.currentCycles;
    let d = now - lastC;
    if (d < 0) d += 2_000_000;             // execute() rebases currentCycles by 2M once a second
    if (lastPc >= 0) { cyc[lastPc] += d; cnt[lastPc]++; }
    lastPc = pc; lastC = now;
    return false;
});
const t0 = Date.now();
s.keyDown(K.RIGHT); await s.runFor(5_000_000);            // run right down the hill (scroll)
await tap(K.UP, 400_000, 2_500_000);                      // jump while running
await tap(K.UP, 400_000, 2_500_000);
s.keyUp(K.RIGHT);
s.keyDown(K.LEFT); await s.runFor(3_000_000);             // run left (mirrored sprites, left scroll)
await tap(K.UP, 400_000, 2_000_000);
s.keyUp(K.LEFT);
s.keyDown(K.RIGHT); await s.runFor(6_000_000);            // and right again
await tap(K.UP, 400_000, 3_000_000);
s.keyUp(K.RIGHT);
await s.runFor(1_000_000);                                // stand still
const total = cyc.reduce((a, b) => a + b, 0);
console.log(`profiled ${total.toFixed(0)} cycles in ${((Date.now() - t0) / 1000).toFixed(1)}s wall`);
const cycles = {}, count = {};
for (let pc = 0; pc < 65536; pc++) if (cnt[pc]) { cycles[pc] = cyc[pc]; count[pc] = cnt[pc]; }
writeFileSync(out, JSON.stringify({ total, cycles, count }));
const top = Object.entries(cycles).sort((a, b) => b[1] - a[1]).slice(0, 12);
for (const [pc, c] of top) console.log(`  $${(+pc).toString(16).padStart(4, "0")}  ${(100 * c / total).toFixed(2)}%  x${count[pc]}`);
