// Unit test for inrange: compare the 6502 result with the original 16-bit semantics.
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleo.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
let hit = false; const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false)); await s.runFor(80_000_000); h.remove();
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea); await s.runFor(9_000_000);
// read the limit table (biased) back to signed
const RX = 0xb6, RY = 0xb8, TRAP = 0x0900;   // rx/ry ZP; trap: a BRK-free spot we can return to
wr(TRAP, 0xea);
const quads = []; for (let i = 0; i < 16; i++) quads.push([0, 1, 2, 3].map((k) => rd(A.RNGTAB + i * 4 + k) - 128));
const call = (rx, ry, x) => {
    wr(RX, rx & 255); wr(RX + 1, (rx >> 8) & 255); wr(RY, ry & 255); wr(RY + 1, (ry >> 8) & 255);
    cpu.x = x * 4; cpu.s = 0xfd; wr(0x1fe, (TRAP - 1) & 255); wr(0x1ff, (TRAP - 1) >> 8); cpu.pc = A.inrange;
    for (let i = 0; i < 200 && cpu.pc !== TRAP; i++) cpu.execute(1);
    if (cpu.pc !== TRAP) throw new Error("no return");
    return cpu.p.c ? 1 : 0;
};
cpu.interrupt = 0; wr(0xfe4e, 0x7f);   // no IRQs while we single-step
let n = 0, bad = 0;
const vals = [-300, -257, -256, -255, -200, -129, -128, -127, -30, -25, -24, -23, -17, -16, -15, -9, -8, -7, -1, 0, 1, 2, 7, 8, 9, 11, 12, 13, 15, 16, 17, 19, 20, 21, 100, 127, 128, 129, 255, 256, 257, 300];
for (let q = 0; q < 16; q++) for (const rx of vals) for (const ry of vals) {
    const [lo, hi, lo2, hi2] = quads[q];
    const exp = rx > lo && rx < hi && ry > lo2 && ry < hi2 ? 1 : 0;
    const got = call(rx, ry, q); n++;
    if (got !== exp) { bad++; if (bad < 10) console.log(`quad ${q} ${quads[q]} rx=${rx} ry=${ry} exp ${exp} got ${got}`); }
}
console.log(`${n} tests, ${bad} mismatches`);
