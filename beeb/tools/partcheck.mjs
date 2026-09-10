// Checks copy_partial: at every painted frame the A row (S-640, lines wfine..7 shifted up by
// wfine) of the displayed buffer must equal row wcy's lines wfine..7.
//   node tools/partcheck.mjs <disc> <labels.txt> [level]
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const [disc, labels, lvlS] = process.argv.slice(2);
const A = {}; for (const m of readFileSync(labels, "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const lvl = parseInt(lvlS ?? "0");
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a), wr = (a, v) => cpu.writemem(a, v);
let hit = false; const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false)); await s.runFor(80_000_000); h.remove();
wr(A.title_loop, 0xa9); wr(A.title_loop + 1, 0x00); wr(A.title_loop + 2, 0xea); { let ok = false; for (let a = A.level_loop; a < A.level_loop + 16; a++) if (rd(a) === 0xa6 && rd(a + 1) === (A.level & 255)) { wr(a, 0xa2); wr(a + 1, lvl); ok = true; break; } if (!ok) throw new Error("ldx level not found"); }
await s.runFor(9_000_000);
const ring = (a) => 0x3000 + (((a % 20480) + 20480) % 20480);
const state = [{}, {}];
cpu.debugInstruction.add((pc) => {
    if (pc === A.build_sections) { const b = rd(A.curbuf); state[b] = { wfine: rd(A.wfine), wcy: rd(A.wcy), S: (rd(A.ringS) | (rd(A.ringS + 1) << 8)) * 8, vs: rd(A.vsyncs) }; }
    return false;
});
let nfr = 0, nbad = 0, nchk = 0; const bad = [];
const v = s._video, orig = v.paint_ext;
v.paint_ext = (...args) => {
    orig(...args);
    const disp = cpu.videoDisplayPage ? 1 : 0, f = state[disp];
    nfr++;
    if (f.S === undefined || f.wfine === 0) return;
    nchk++;
    let diff = 0, first = -1;
    for (let c = 0; c < 80; c++) for (let y = f.wfine; y < 8; y++) {
        const a = cpu.videoRead(ring(f.S + c * 8 + y)), b = cpu.videoRead(ring(f.S - 640 + c * 8 + y - f.wfine));
        if (a !== b) { diff++; if (first < 0) first = c; }
    }
    if (diff) { nbad++; if (bad.length < 6) bad.push(`vs${rd(A.vsyncs)} buf${disp} wcy=${f.wcy} wfine=${f.wfine} ${diff} bytes differ from column ${first}`); }
};
s.keyDown(39); await s.runFor(4_000_000);
s.keyDown(13); await s.runFor(300_000); s.keyUp(13); await s.runFor(2_500_000);
s.keyUp(39); await s.runFor(1_500_000);
s.keyDown(13); await s.runFor(300_000); s.keyUp(13); await s.runFor(2_000_000);
s.keyDown(37); await s.runFor(3_000_000); s.keyUp(37); await s.runFor(1_000_000);
console.log(`${nfr} frames painted, ${nchk} with a partial row, ${nbad} with a stale A row`); console.log(bad.join("\n"));
