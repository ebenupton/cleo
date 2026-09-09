// Log every drawsprite call per render while Cleo interacts with a collapsing block (level 1).
//   node tools/spritelog.mjs build/cleo.ssd
import { readdirSync, existsSync } from "node:fs";
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
const A = Object.fromEntries(process.argv.slice(3).map(s => s.split("=")).map(([k, v]) => [k, parseInt(v, 16)]));
const s = new MachineSession("Master");
await s.initialise();
await s.boot(30);
s.loadDisc(path.resolve(process.argv[2]));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor;
const rd = (a) => cpu.readmem(a);
const wr = (a, v) => cpu.writemem(a, v);
// stop at title_loop, then patch: jsr title_menu -> lda #0 / nop (START), ldx level -> ldx #2 (level 1 main)
let hit = false;
const h1 = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false));
await s.runFor(80_000_000);
h1.remove();
if (!hit) throw new Error("title_loop not reached");
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea);
wr(A.level_loop + 3, 0xa2); wr(A.level_loop + 4, 0x02);   // ldx level sits after jsr blank_palette
await s.runFor(9_000_000);                       // load + spawn
console.log("nobj", rd(0x85), "level", rd(0x88), "frame", rd(0x5e) | (rd(0x5f) << 8));
await s.runFor(20_000_000);                      // let spawn invulnerability expire
// teleport above the block at tile (39,28): px=316, py=196
wr(0x60, 316 & 255); wr(0x61, 316 >> 8); wr(0x62, 196); wr(0x63, 0);
// ---- log
const log = [];
let cur = null;
cpu.debugInstruction.add((pc) => {
    if (pc === A.render_frame) {
        cur = { frame: rd(0x5e) | (rd(0x5f) << 8), buf: rd(A.curbuf), px: rd(0x60) | (rd(0x61) << 8), py: rd(0x62) | (rd(0x63) << 8), hurt: rd(0x6e), nspr: rd(A.NSPR), drawn: [], kept: [] };
        log.push(cur);
    } else if (pc === A.draw_sprites && cur) {
        cur.nspr = rd(A.NSPR);
        cur.kept = Array.from({ length: cur.nspr }, (_, i) => rd(A.KEEP + i));
    } else if (pc === A.drawsprite && cur) {
        cur.drawn.push(cpu.a);
    }
    return false;
});
await s.runFor(5_000_000);
for (const r of log) console.log(`f${String(r.frame).padStart(4)} buf${r.buf} px${r.px} py${r.py} hurt${r.hurt} nspr${r.nspr} kept[${r.kept.join("")}] drawn[${r.drawn.join(",")}]`);
