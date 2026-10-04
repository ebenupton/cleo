// A write-select board's one rule, checked through a whole session: every store the
// game makes into sideways RAM goes to the bank paged for reading (boards.mjs boardEmu
// counts the ones that do not, by PC).  No patches: boots a jsbeeb Model B from the
// disc with the board emulated (SHIFT-BREAK), waits 12 s through the title and its
// tune, presses DOWN and RETURN (the help page), RETURN (back), UP and RETURN (start:
// level 0, its load, 12 s -- a fresh boot has no level select), then plays for
// play-seconds, a quarter second a key, cycling idle, X (right), Z (left), RETURN
// (fire) and / (down); then lists the offending stores by PC and nearest label.
//   node test/boardcheck.mjs watford|solidisk <disc> <labels> [play-seconds=20]
// BMODEL=B1770 for the 1770 machine (default B-DFS1.2).
// Output: up to 20 sites (stores, pc, label+offset), then "board <kind>: MISMATCHED
// stores from <n> sites" or "every store to the bank paged"; exit 1 on a mismatch.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { findJsbeeb, loadLabels } from "./harness.mjs";
import { boardEmu } from "./bopen.mjs";
const [kind, disc, labels, secs = "20"] = process.argv.slice(2);
if (!labels) { console.log("usage: node test/boardcheck.mjs watford|solidisk <disc> <labels> [play-seconds]"); process.exit(2); }
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = loadLabels(labels);
const names = Object.entries(A).sort((p, q) => p[1] - q[1]);
const nameOf = (pc) => { let b = null; for (const [n, a] of names) if (a <= pc && (!b || a > b[1])) b = [n, a]; return b ? `${b[0]}+${(pc - b[1]).toString(16)}` : "?"; };
const s = new MachineSession(process.env.BMODEL ?? "B-DFS1.2");
await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
const cpu = s._machine.processor;
boardEmu(cpu, kind);
const run = async (sec) => { for (let i = 0; i < sec * 20; i++) await s.runFor(100_000); };
const tap = async (key, sec = 0.3) => { s.keyDown(key); await run(0.1); s.keyUp(key); await run(sec); };
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await run(12);                                          // boot, the title, the tune
await tap(40, 1); await tap(13, 3); await tap(13, 2);   // DOWN to help, RETURN in, RETURN out
await tap(38, 1); await tap(13, 12);                    // UP: start a game (its load)
let t = 0;
const keys = [0, 88, 90, 13, 191];                       // idle, X right, Z left, RETURN fire, / down
for (let i = 0; i < +secs * 4; i++) { const k = keys[i % keys.length]; if (k) s.keyDown(k); await run(0.25); if (k) s.keyUp(k); t++; }
const bad = [...cpu.boardMismatch].sort((p, q) => q[1] - p[1]);
for (const [pc, n] of bad.slice(0, 20)) console.log(`  ${String(n).padStart(6)} stores  pc $${pc.toString(16)}  ${nameOf(pc)}`);
console.log(`board ${kind}: ${bad.length ? `MISMATCHED stores from ${bad.length} sites` : "every store to the bank paged"}`);
process.exit(bad.length ? 1 : 0);
