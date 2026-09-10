// dftrace — execution trace + code image for tools/dfscan.py.
//
// Boots the disc, plays a scripted session (menus, two outdoor levels, one tomb,
// running, jumping, throwing, a death and the lose screen), and records:
//   counts   pc -> executions, over every code region (IRQ and NMI included)
//   mem      the bytes of each code region, read with HAZEL paged in
// Written to build/dftrace.json.   node tools/dftrace.mjs [out.json]
import { readdirSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));

const A = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
// code regions, from cleo.cfg: LOW2 (MOS vector/VDU pages), LOW (NMI page), CODE, HAZEL
const REGIONS = [];
for (const ln of readFileSync("build/map.txt", "utf8").split("\n")) {
    const m = ln.match(/^(LOW2|LOW|CODE|HAZEL)\s+([0-9A-F]+)\s+([0-9A-F]+)\s+([0-9A-F]+)/);
    if (m) REGIONS.push({ name: m[1], lo: parseInt(m[2], 16), hi: parseInt(m[3], 16) });
}
if (REGIONS.length !== 4) throw new Error("expected 4 code regions, got " + REGIONS.length);

const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleo.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
let hit = false; const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false));
await s.runFor(80_000_000); h.remove();
if (!hit) throw new Error("title_loop not reached");

const counts = new Uint32Array(65536);
const inCode = (pc) => REGIONS.some((r) => pc >= r.lo && pc <= r.hi);
// observed control-flow edges: Cleo dispatches through jmp (tab,x) and through
// jmp operands patched at run time, neither of which is in the static CFG
const edges = new Map();
let tracing = false, prev = -1;
cpu.debugInstruction.add((pc) => {
    if (tracing) {
        counts[pc]++;
        if (prev >= 0 && inCode(prev) && inCode(pc)) {
            let s = edges.get(prev);
            if (s === undefined) edges.set(prev, (s = new Set()));
            if (s.size < 16) s.add(pc);
        }
        prev = pc;
    }
    return false;
});

const K = { LEFT: 37, UP: 38, RIGHT: 39, RETURN: 13, ESCAPE: 27, DOWN: 40, SLASH: 191 };
const tap = async (k, hold, after) => { s.keyDown(k); await s.runFor(hold); s.keyUp(k); await s.runFor(after); };
tracing = true;
// title screen and its menu (menu_list, draw_glyph_rows, the title blitters)
await s.runFor(2_000_000);
await tap(K.DOWN, 200_000, 400_000);           // move the cursor (menu redraw)
await tap(K.UP, 200_000, 400_000);
await tap(K.RETURN, 300_000, 6_000_000);       // START GAME -> level 0
// level 0: run, jump, fire, run back (mirrored sprites, both scroll directions)
s.keyDown(K.RIGHT); await s.runFor(5_000_000);
await tap(K.RETURN, 300_000, 2_500_000);       // jump while running
await tap(K.SLASH, 200_000, 2_000_000);        // boomerang
s.keyUp(K.RIGHT);
s.keyDown(K.LEFT); await s.runFor(3_000_000); s.keyUp(K.LEFT);
await s.runFor(1_000_000);
// pause menu
await tap(K.ESCAPE, 300_000, 1_500_000);
await tap(K.ESCAPE, 300_000, 1_500_000);
// jump straight to a tomb level (indoor tiles, bats, solid-black fills)
{
    let found = false;
    for (let a = A.level_loop; a < A.level_loop + 16; a++)
        if (rd(a) === 0xa6 && rd(a + 1) === (A.level & 255)) { wr(a, 0xa2); wr(a + 1, 1); found = true; break; }
    if (!found) throw new Error("ldx level not found");
}
wr(A.exiting, 1); await s.runFor(12_000_000);
s.keyDown(K.RIGHT); await s.runFor(4_000_000);
await tap(K.RETURN, 300_000, 2_500_000);
s.keyUp(K.RIGHT); await s.runFor(1_000_000);
// die: lose screen exercises the half-res title blitter and winlose
wr(A.lives, 1); wr(A.health, 0); await s.runFor(10_000_000);
tracing = false;

const mem = REGIONS.map((r) => {
    const b = Buffer.alloc(r.hi - r.lo + 1);
    for (let a = r.lo; a <= r.hi; a++) b[a - r.lo] = rd(a);
    return { ...r, bytes: b.toString("base64") };
});
let nPc = 0, nSteps = 0, nOut = 0;
const cnt = {};
for (let pc = 0; pc < 65536; pc++) if (counts[pc]) { nSteps += counts[pc]; if (inCode(pc)) { cnt[pc] = counts[pc]; nPc++; } else nOut += counts[pc]; }
const edgeObj = {};
for (const [from, set] of edges) edgeObj[from] = [...set];
writeFileSync(process.argv[2] || "build/dftrace.json", JSON.stringify({ counts: cnt, edges: edgeObj, mem, labels: A }));
console.log(`trace: ${nSteps} steps, ${nPc} distinct PCs in code regions (${nOut} steps outside: MOS/ROM), ${edges.size} edge sources`);
for (const r of REGIONS) console.log(`  ${r.name.padEnd(6)} $${r.lo.toString(16).toUpperCase()}..$${r.hi.toString(16).toUpperCase()}`);
