// Unit test for drawrect_clip: sweep rects against the window and compare the clamped
// rect with a model.  drawrect is stubbed to rts, so this tests the clip in isolation
// and covers the off-window branches a scripted run barely reaches.
//   node tools/cliptest.mjs [disc] [labels.txt]
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const [discA, labelsA] = process.argv.slice(2);
const disc = discA ?? "build/cleo.ssd", labels = labelsA ?? "build/labels.txt";
const A = {}; for (const m of readFileSync(labels, "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
{ const h = cpu.debugInstruction.add((pc) => pc === A.title_loop); await s.runFor(80_000_000); h.remove(); }
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea); await s.runFor(9_000_000);
cpu.interrupt = 0; wr(0xfe4e, 0x7f);                       // no IRQs while we single-step
const TRAP = 0x0900; wr(TRAP, 0xea);
wr(A.drawrect, 0x60);                                      // stub drawrect: we only want the clip
const ROWCHARS = 80, BUFROWS = 28;
const call = (wcx, wcy, x, y, w, h) => {
    wr(A.wcx, wcx & 255); wr(A.wcx + 1, wcx >> 8); wr(A.wcy, wcy);
    wr(A.rc_x, x & 255); wr(A.rc_x + 1, (x >> 8) & 255); wr(A.rc_y, y & 255);
    wr(A.rc_w, w); wr(A.rc_h, h);
    cpu.s = 0xfd; wr(0x1fe, (TRAP - 1) & 255); wr(0x1ff, (TRAP - 1) >> 8); cpu.pc = A.drawrect_clip;
    for (let i = 0; i < 400 && cpu.pc !== TRAP; i++) cpu.execute(1);
    if (cpu.pc !== TRAP) throw new Error("no return");
    return { x: rd(A.rc_x) | (rd(A.rc_x + 1) << 8), y: rd(A.rc_y), w: rd(A.rc_w), h: rd(A.rc_h) };
};
// model: intersect [x,x+w) x [y,y+h) with the window; drawn = non-empty intersection
const model = (wcx, wcy, x, y, w, h) => {
    const x0 = Math.max(x, wcx), x1 = Math.min(x + w, wcx + ROWCHARS);
    const y0 = Math.max(y, wcy), y1 = Math.min(y + h, wcy + BUFROWS);
    return x1 > x0 && y1 > y0 ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : null;
};
let n = 0, bad = 0;
const dxs = [-300, -200, -100, -81, -80, -79, -40, -5, -4, -3, -2, -1, 0, 1, 2, 40, 78, 79, 80, 81, 100, 200];
const dys = [-40, -30, -29, -28, -27, -16, -3, -2, -1, 0, 1, 2, 15, 26, 27, 28, 29, 40];
const ws = [1, 2, 3, 4, 5, 40, 79, 80];
const hs = [1, 2, 3, 16, 27, 28];
for (const wcx of [0, 1, 200, 255, 256, 300]) for (const wcy of [0, 5, 100]) {
    for (const dx of dxs) for (const dy of dys) for (const w of ws) for (const h of hs) {
        const x = wcx + dx, y = wcy + dy;
        if (x < 0 || y < 0 || y + h > 255 || x + w > 0xffff) continue;   // outside the engine's domain
        const exp = model(wcx, wcy, x, y, w, h);
        const got = call(wcx, wcy, x, y, w, h); n++;
        // a rejected rect leaves the args alone; detect "drawn" by whether the model says so
        const ok = exp === null ? true : (got.x === exp.x && got.y === exp.y && got.w === exp.w && got.h === exp.h);
        if (!ok) { bad++; if (bad <= 12) console.log(`wcx=${wcx} wcy=${wcy} rect=(${x},${y},${w},${h}) exp ${JSON.stringify(exp)} got ${JSON.stringify(got)}`); }
    }
}
console.log(`${n} clip tests, ${bad} mismatches`);
