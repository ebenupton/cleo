// Verifies the music hidden in the tile data: music_tab (decoded at start-up by musbyte) must
// equal the first 144 bytes of build/MUSIC, and bit 6 of bank 5 must reassemble the sequence.
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import path from "node:path";
function findJsbeeb() { const npx = path.join(homedir(), ".npm", "_npx"); for (const d of readdirSync(npx)) { const p = path.join(npx, d, "node_modules", "jsbeeb", "src", "machine-session.js"); if (existsSync(p)) return p; } throw new Error("no jsbeeb"); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = {}; for (const m of readFileSync("build/labels.txt", "utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm)) A[m[2]] = parseInt(m[1], 16);
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleo.ssd"));
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
const cpu = s._machine.processor, rd = (a) => cpu.readmem(a);
let hit = false; const h = cpu.debugInstruction.add((pc) => (pc === A.title_loop ? (hit = true) : false)); await s.runFor(80_000_000); h.remove();
const mus = readFileSync("build/MUSIC");
let bad = 0; for (let i = 0; i < 144; i++) if (rd(A.music_tab + i) !== mus[i]) bad++;
console.log(`music_tab: ${bad} of 144 bytes differ from build/MUSIC`);
const romRead = (n, a) => { const r = cpu.romsel; cpu.writemem(0xfe30, n); const v = cpu.readmem(a); cpu.writemem(0xfe30, r); return v; };
let sbad = 0; for (let i = 144; i < mus.length; i++) { let v = 0; for (let k = 0; k < 8; k++) v = (v << 1) | ((romRead(5, 0x8000 + 8 * i + k) >> 6) & 1); if (v !== mus[i]) sbad++; }
console.log(`sequence: ${sbad} of ${mus.length - 144} bytes differ when decoded from bank 5`);
