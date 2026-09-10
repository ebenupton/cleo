// For each level index, start it directly and log Cleo's py over the first second: a spawn
// with no floor shows py running away.   node tools/spawncheck.mjs build/cleo.ssd
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() {
    const npx = path.join(homedir(), ".npm", "_npx");
    for (const d of readdirSync(npx)) {
        const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js");
        if (existsSync(p)) return p;
    }
    throw new Error("jsbeeb not found");
}
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = {};
for (const m of readFileSync(path.join(path.dirname(process.argv[2]), "labels.txt"), "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const names = ["L0B", "L0A", "L1B", "L1A", "L2B", "L2A", "L3B", "L3A", "L4B", "L4A", "L5B", "L5A", "L6B", "L6A", "L7B", "L7A"];
for (let lvl = 0; lvl < 16; lvl++) {
    const s = new MachineSession("Master");
    await s.initialise();
    await s.boot(30);
    s.loadDisc(path.resolve(process.argv[2]));
    s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
    const cpu = s._machine.processor;
    const rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
    let hit = false;
    const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false));
    await s.runFor(80_000_000);
    h.remove();
    if (!hit) throw new Error("title_loop not reached");
    wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea);
    { let ok = false; for (let a = A.level_loop; a < A.level_loop + 16; a++) if (rd(a) === 0xa6 && rd(a + 1) === (A.level & 255)) { wr(a, 0xa2); wr(a + 1, lvl); ok = true; break; } if (!ok) throw new Error("ldx level not found"); }  // ldx level (after jsr blank_palette) -> ldx #lvl
    await s.runFor(6_000_000);
    const px = () => rd(A.px) | (rd(A.px + 1) << 8), py = () => rd(A.py) | (rd(A.py + 1) << 8);
    const sx = rd(A.startx) | (rd(A.startx + 1) << 8), sy = rd(A.starty) | (rd(A.starty + 1) << 8);
    const trace = [];
    for (let i = 0; i < 12; i++) { trace.push(py()); await s.runFor(250_000); }
    console.log(`${names[lvl].padEnd(4)} lvl${String(lvl).padStart(2)} start(${sx},${sy}) maph=${rd(A.maph) | (rd(A.maph + 1) << 8)} px=${px()} py: ${trace.join(" ")} lives=${rd(A.lives)}`);
    s.destroy?.();
}
