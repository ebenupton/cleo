// Diagnose the bar fragment seen below the status bar during vertical scroll.
// Each vsync: reconstruct what the displayed buffer's memory says the 8 scanlines under the
// bar should show (A row / row 0 / row 1 per wfine) and compare with the framebuffer.
//   node tools/barfrag.mjs build/cleo.ssd      (addresses come from build/labels.txt)
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
import { readFileSync } from "node:fs";
// all addresses from build/labels.txt (ZP layout moves whenever a variable is added)
const A = {};
for (const m of readFileSync(path.join(path.dirname(process.argv[2]), "labels.txt"), "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const K = { SHIFT: 16, RETURN: 13, LEFT: 37, UP: 38, RIGHT: 39 };
const ZP = { wcx: A.wcx, wcy: A.wcy, wfine: A.wfine, curbuf: A.curbuf, ringS: A.ringS, barq: A.barq, vsyncs: A.vsyncs };
const s = new MachineSession("Master");
await s.initialise();
await s.boot(30);
s.loadDisc(path.resolve(process.argv[2]));
s.keyDown(K.SHIFT); s.reset(true); await s.runFor(2_000_000); s.keyUp(K.SHIFT);
const cpu = s._machine.processor;
const rd = (a) => cpu.readmem(a);
const wr = (a, v) => cpu.writemem(a, v);
let hit = false;
const h1 = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false));
await s.runFor(80_000_000);
h1.remove();
if (!hit) throw new Error("title_loop not reached");
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea);
await s.runFor(9_000_000);

// ---- helpers
const FBW = 1024;
const fb = s._completeFb8;
const v = s._video;
const idx = (r, g, b) => (r > 128 ? 1 : 0) | (g > 128 ? 2 : 0) | (b > 128 ? 4 : 0);
const glyph = ".RGYBMCW";
const pxw = (FBW - v.leftBorder - v.rightBorder) / 160;
function fbLine(y, left, npix) {
    let out = "";
    for (let p = 0; p < npix; p++) {
        const x = Math.round(left + (p + 0.5) * pxw);
        const o = (y * FBW + x) * 4;
        out += glyph[idx(fb[o], fb[o + 1], fb[o + 2])];
    }
    return out;
}
function px(b) {
    const l = ((b >> 1) & 1) | (((b >> 3) & 1) << 1) | (((b >> 5) & 1) << 2);
    const r = (b & 1) | (((b >> 2) & 1) << 1) | (((b >> 4) & 1) << 2);
    return glyph[l] + glyph[r];
}
const ring = (a) => 0x3000 + (((a % 20480) + 20480) % 20480);
function memLine(base, l, nchars) {
    let t = "";
    for (let c = 0; c < nchars; c++) t += px(cpu.videoRead(ring(base + c * 8 + l)));
    return t;
}
function findTop() {
    for (let y = 0; y < 625; y++) for (let x = 0; x < FBW; x += 4) {
        const o = (y * FBW + x) * 4;
        if (fb[o] | fb[o + 1] | fb[o + 2]) return y;
    }
    return -1;
}
function findLeft(y) {
    for (let x = 0; x < FBW; x++) { const o = (y * FBW + x) * 4; if (fb[o] | fb[o + 1] | fb[o + 2]) return x; }
    return -1;
}

// ---- record camera state per render (at build_sections: everything for this buffer is final)
const state = [{}, {}];
cpu.debugInstruction.add((pc) => {
    if (pc === A.copy_partial) {
        const b = rd(ZP.curbuf);
        const n = rd(A.NSPR), spr = [];
        for (let i = 0; i < n; i++) { const o = A.SPRLIST + i * 5; spr.push({ id: rd(o), x: rd(o + 1) | (rd(o + 2) << 8), y: rd(o + 3) | (rd(o + 4) << 8) }); }
        state[b] = { vs: rd(ZP.vsyncs), wfine: rd(ZP.wfine), wcx: rd(ZP.wcx) | (rd(ZP.wcx + 1) << 8), wcy: rd(ZP.wcy), ringS: rd(ZP.ringS) | (rd(ZP.ringS + 1) << 8), barq: rd(ZP.barq), wx: rd(A.wx) | (rd(A.wx + 1) << 8), wy: rd(A.wy) | (rd(A.wy + 1) << 8), spr };
    }
    return false;
});
function findRight(y) {
    for (let x = FBW - 1; x >= 0; x--) { const o = (y * FBW + x) * 4; if (fb[o] | fb[o + 1] | fb[o + 2]) return x; }
    return -1;
}
// analyse at paint time: the framebuffer is the frame just completed and the display page
// (and its memory) is still the one it was drawn from
let nbad = 0, nfr = 0;
const out = [], extra = [];
const orig = v.paint_ext;
v.paint_ext = (...args) => {
    orig(...args);
    const disp = cpu.videoDisplayPage ? 1 : 0;
    const f = state[disp];
    if (f.ringS === undefined) return;
    const top = findTop();
    if (top < 0) return;
    let left = FBW, right = 0;
    for (let y = top; y < top + 80; y++) { const l = findLeft(y), r = findRight(y); if (l >= 0 && l < left) left = l; if (r > right) right = r; }
    const pw = (right - left + 1) / 160;
    nfr++;
    const S = f.ringS * 8, fine = f.wfine;
    const exp = [], got = [], bar = [];
    for (let k = 0; k < 8; k++) {
        let base, l;
        if (fine === 0) { base = S; l = k; }
        else if (k < 8 - fine) { base = S - 640; l = k; }
        else { base = S + 640; l = k - (8 - fine); }
        exp.push(memLine(base, l, 80));
        let g = "";
        for (let p = 0; p < 160; p++) { const x = Math.round(left + (p + 0.5) * pw); const o = ((top + 32 + 2 * k) * FBW + x) * 4; g += glyph[idx(fb[o], fb[o + 1], fb[o + 2])]; }
        got.push(g);
    }
    for (let k = 0; k < 8; k++) bar.push(memLine(((f.barq - 2) & 31) * 640, k, 80));
    const differs = (e, g) => { for (let p = 1; p < 159; p++) if (e[p] !== g[p]) return true; return false; };
    // bottom edge: how many scanlines are lit below the bar top? (expect 16 + 216 = 232)
    let bottom = top;
    for (let y = top; y < 625; y++) if (findLeft(y) >= 0) bottom = y;
    const nlines = Math.round((bottom - top + 1) / 2);
    if (nlines !== 232) {
        let g = ""; for (let p = 0; p < 160; p++) { const x = Math.round(left + (p + 0.5) * pw); const o = (bottom * FBW + x) * 4; g += glyph[idx(fb[o], fb[o + 1], fb[o + 2])]; }
        const b0 = memLine(((f.barq - 3) & 31) * 640, 0, 80);
        const below = memLine(S + 27 * 640, 0, 80);   // row wcy+27 line 0 (what P2/Q would show)
        extra.push(`vs${rd(ZP.vsyncs)} wfine=${fine} lines=${nlines} last line: ${g.slice(0, 50)}...  ${g === b0 ? "== BAR ROW 0 LINE 0" : g === below ? "== row wcy+27 line 0" : "(neither bar line 0 nor row wcy+27)"}`);
    }
    if (!exp.some((e, k) => differs(e, got[k]))) return;
    nbad++;
    const lines = [`vs${rd(ZP.vsyncs)} disp=buf${disp} rendered@vs${f.vs} wfine=${fine} wcy=${f.wcy} wcx=${f.wcx} q=${f.barq} off=${f.ringS % 80} pw=${pw.toFixed(2)}`];
    for (let k = 0; k < 8; k++) if (differs(exp[k], got[k])) {
        let m = ""; for (let p = 0; p < 160; p++) m += exp[k][p] === got[k][p] ? " " : "^";
        lines.push(`  sl${16 + k} exp ${exp[k]}\n       got ${got[k]}\n           ${m}`);
        const hitsBar = bar.findIndex((b) => { let n = 0; for (let p = 0; p < 160; p++) if (b[p] !== "." && b[p] === got[k][p] && exp[k][p] !== got[k][p]) n++; return n > 3; });
        if (hitsBar >= 0) lines.push(`       (differing pixels match bar row 1 line ${hitsBar})`);
    }
    out.push(lines.join("\n"));
};
// exact MCP scenario: RETURN held 500K cycles after 2.5M of RIGHT; dump the frame + memory
import { writeFileSync } from "node:fs";
await s.runFor(600_000);                       // static camera first (wfine = 0 at the level start)
s.keyDown(K.RIGHT); await s.runFor(2_500_000);
s.keyDown(K.RETURN); await s.runFor(500_000);
{
    const disp = cpu.videoDisplayPage ? 1 : 0;
    const f = state[disp];
    const top = findTop();
    let left = FBW, right = 0;
    for (let y = top; y < top + 80; y++) { const l = findLeft(y), r = findRight(y); if (l >= 0 && l < left) left = l; if (r > right) right = r; }
    const pw = (right - left + 1) / 160;
    console.log(`SNAP disp=buf${disp} rendered@vs${f.vs} now vs${rd(ZP.vsyncs)} wfine=${f.wfine} wcy=${f.wcy} wcx=${f.wcx} q=${f.barq} off=${f.ringS % 80} pw=${pw.toFixed(2)} top=${top}`);
    for (let k = 0; k < 24; k++) {
        let g = "";
        for (let p = 0; p < 160; p++) { const x = Math.round(left + (p + 0.5) * pw); const o = ((top + 2 * k) * FBW + x) * 4; g += glyph[idx(fb[o], fb[o + 1], fb[o + 2])]; }
        console.log(`fb sl${String(k).padStart(2)} ${g}`);
    }
    const S = f.ringS * 8;
    for (const [name, base] of [["bar0", ((f.barq - 3) & 31) * 640], ["bar1", ((f.barq - 2) & 31) * 640], ["A   ", S - 640], ["row0", S], ["row1", S + 640]])
        for (let l = 0; l < 8; l++) console.log(`mem ${name} l${l} ${memLine(base, l, 80)}`);
    writeFileSync(process.env.SNAP || "/tmp/snap.png", await s.screenshotActive({ scale: 2 }));
    console.log(`wx=${f.wx} wy=${f.wy} sprites:`);
    for (const sp of f.spr) {
        const t = A.SPR_TABLE + sp.id * 8;
        const sx = (v) => (v & 0x80 ? v - 256 : v);
        const w = rd(t + 2), refx = sx(rd(t + 4)), refy = sx(rd(t + 5)), lines = rd(t + 7);
        const c0 = ((sp.x - refx - f.wx) >> 1), lb0 = 2 * (sp.y - refy - f.wy) + f.wfine;
        console.log(`  id${String(sp.id).padStart(3)} x${sp.x} y${sp.y} w${w} lines${lines} ref(${refx},${refy}) -> col${c0} line${lb0}..${lb0 + lines - 1}`);
    }
}
s.keyUp(K.RETURN); await s.runFor(6_000_000);   // whole jump + landing: wfine cycles through 0,2,4,6
console.log(`${nfr} frames checked, ${nbad} with mismatches; ${extra.length} frames with an odd line count`);
const agg = {};
for (const e of extra) { const k = e.replace(/^vs\d+ /, "").replace(/last line: .*?\.\.\.  /, ""); agg[k] = (agg[k] || 0) + 1; }
console.log(Object.entries(agg).map(([k, n]) => `${n}x ${k}`).join("\n"));
console.log(out.slice(0, 10).join("\n\n"));
