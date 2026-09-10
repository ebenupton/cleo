// Log per-logic-frame game state and per-render sprite lists for a scripted run, to diff two builds.
//   node tools/statelog.mjs <disc> <labels.txt> <out.json> [level]
import { readdirSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const [disc, labels, out, lvlS] = process.argv.slice(2);
const A = {}; for (const m of readFileSync(labels, "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const lvl = parseInt(lvlS ?? "0");
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
let hit = false; const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false)); await s.runFor(80_000_000); h.remove();
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea); { let ok = false; for (let a = A.level_loop; a < A.level_loop + 16; a++) if (rd(a) === 0xa6 && rd(a + 1) === (A.level & 255)) { wr(a, 0xa2); wr(a + 1, lvl); ok = true; break; } if (!ok) throw new Error("ldx level not found"); }
await s.runFor(9_000_000);
// deterministic input: scan_keys -> rts, and the key mask is poked per logic frame
wr(A.scan_keys, 0x60);
const K = { LEFT: 1, RIGHT: 2, UP: 4, FIRE: 16 };
// keyed on the absolute frame counter so two builds get identical input regardless of where the run-in stops
const script = (n) => (n < 100 ? 0 : n < 230 ? K.RIGHT : n < 240 ? K.RIGHT | K.UP : n < 300 ? K.RIGHT : n < 310 ? K.FIRE : n < 380 ? K.LEFT : n < 390 ? K.LEFT | K.UP : 0);
let nstep = 0, lastf = -1, f0 = -1;
const OBJN = 149, OB = 0xb000;   // LV_OBJST: stamp,type,xl,xh,yl,yh,al,ah,bl,bh,cl,ch,dl,dh,el,eh (149 each)
const OBJ = { xl: OB + 2 * OBJN, xh: OB + 3 * OBJN, yl: OB + 4 * OBJN, yh: OB + 5 * OBJN, al: OB + 6 * OBJN, ah: OB + 7 * OBJN, bl: OB + 8 * OBJN, cl: OB + 10 * OBJN, dl: OB + 12 * OBJN, el: OB + 14 * OBJN };
const romRead = (n, a) => { const r = cpu.romsel; cpu.writemem(0xfe30, n); const v = cpu.readmem(a); cpu.writemem(0xfe30, r); return v; };
const bank = (n) => () => {};
const frames = [], renders = [];
const w16 = (a) => rd(a) | (rd(a + 1) << 8);
cpu.debugInstruction.add((pc) => {
    if (pc === A.game_frame) {
        // the hook can fire twice for one entry (IRQ taken at this PC), so key off the frame counter
        const f = w16(A.frame); if (f === lastf) return false; if (f0 < 0) f0 = f; lastf = f; nstep = f;
        wr(A.keys, script(nstep));
        const restore = bank(7); const nobj = rd(A.nobj); const objs = [];
        for (let i = 0; i < nobj; i++) objs.push([OBJ.xl, OBJ.xh, OBJ.yl, OBJ.yh, OBJ.al, OBJ.ah, OBJ.bl, OBJ.cl, OBJ.dl, OBJ.el].map((b) => romRead(7, b + i)).join(","));
        restore();
        frames.push({ f: w16(A.frame), px: w16(A.px), py: w16(A.py), vx: w16(A.vx), vy: w16(A.vy), h: rd(A.health), st: rd(A.stars), sc: w16(A.score), objs: objs.join("|") });
    } else if (pc === A.draw_sprites) {
        const n = rd(A.NSPR), spr = [];
        for (let i = 0; i < n; i++) { const o = A.SPRLIST + i * 5; spr.push(`${rd(o)}@${rd(o + 1) | (rd(o + 2) << 8)},${rd(o + 3) | (rd(o + 4) << 8)}`); }
        renders.push({ f: w16(A.frame), spr: spr.sort().join(" ") });
    }
    return false;
});
while (nstep < 470) await s.runFor(500_000);
writeFileSync(out, JSON.stringify({ frames, renders }));
console.log(`${frames.length} logic frames, ${renders.length} renders`);
