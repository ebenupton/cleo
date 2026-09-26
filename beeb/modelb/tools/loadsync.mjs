// NOTE: the patched title leaves the chain out of phase before the load, so the frames
// around the switch measure that, not the switch: tools/loadsync2.mjs starts from the real
// menu, in sync, and is the one to trust.
// Model B: the frame period across a level load (display.s ldstop5, disc.s ld_begin);
// the Master's tools/loadsync.mjs, for the Model B disc.  Run from beeb/modelb.
//   node tools/loadsync.mjs
// Model B: boot to the title, then through the level load, logging every vsync
// acknowledge and every CRTC R4/R6/R7/R12 write with the CRTC's position.
import { findJsbeeb, loadLabels } from "../../tools/harness.mjs";
import { pathToFileURL } from "node:url"; import path from "node:path";
process.chdir("/Users/ebenupton/cleo/beeb/modelb");
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = loadLabels("build/labels.txt");
const s = new MachineSession("B-DFS1.2"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve("build/cleob.ssd"));
const cpu = s._machine.processor, v=s._video;
const P = cpu.model.swram.map((r, i) => (r ? i : -1)).filter((i) => i >= 0).slice(0, 4);
const PB = (b) => (b >= 4 && b <= 7 ? P[b - 4] : b);
const bank = (b, f) => { const was = cpu.readmem(0xf4); cpu.writemem(0xf4, PB(b)); cpu.writemem(0xfe30, PB(b)); const r = f(); cpu.writemem(0xf4, was); cpu.writemem(0xfe30, was); return r; };
const cyc = () => cpu.currentCycles + cpu.cycleSeconds * 2_000_000;
// hardware-side: jsbeeb paints at each CRTC vsync, and forces a paint when a frame passes with none
const HV=[]; let forced=0; { const v0=s._video; const opc=v0.paintAndClear.bind(v0);
  const FT=[]; v0.paintAndClear=function(){ if(v0.bitmapY>=768){ forced++; FT.push(cyc()); } HV.push(cyc()); return opc(); }; globalThis.FT=FT; }

async function runTo(pc, b, budget = 3000) { const pb = PB(b); const h = cpu.debugInstruction.add((p) => p === pc && cpu.readmem(0xf4) === pb);
  try { for (let i = 0; i < budget; i++) { await s.runFor(20000); if (cpu.pc === pc && cpu.readmem(0xf4) === pb) return; } } finally { h.remove(); } throw new Error(`B: runTo ${pc.toString(16)} timed out`); }
s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await runTo(A.title_loop, 7);
bank(7, () => { for (let i = 0; i < 6; i++) cpu.writemem(A.title_loop + i, 0xea); cpu.writemem(A.title_loop + 3, 0xa9); cpu.writemem(A.title_loop + 4, 0);
  for (let a = A.level_loop; a < A.level_loop + 24; a++) if (cpu.readmem(a) === 0xa6 && cpu.readmem(a + 1) === (A.level & 255)) { cpu.writemem(a, 0xa2); cpu.writemem(a + 1, 0); break; } });
let idx=-1, vs=[], regs=[], lastVs=null;
const h=cpu.debugWrite.add((addr,val)=>{ if(addr===0xfe00) idx=val;
  else if(addr===0xfe01 && (idx===4||idx===7||idx===6||idx===12)) regs.push({t:cyc(), r:idx, val, vc:v.vertCounter, sc:v.scanlineCounter, hc:v.horizCounter});
  else if(addr===0xfe4d && (val&2)) { const t=cyc(); vs.push({d: lastVs===null?0:t-lastVs, vc:v.vertCounter}); lastVs=t; }
  return false; });
await runTo(A.level_init, 7, 60000);
bank(7, () => cpu.writemem(A.scan_keys, 0x60));
await runTo(A.frame_top, 7);
for(let f=0;f<6;f++){ bank(7,()=>{cpu.writemem(A.keys,0); cpu.writemem(A.hurt,1); cpu.writemem(A.health,3);}); await runTo(A.frame_top,7); }
h.remove();
const bad=vs.filter(e=>e.d && (e.d<39800||e.d>40100));
console.log('vsync acks:',vs.length,' intervals outside 39936+-160:',bad.length, bad.slice(0,10).map(e=>`${e.d}@vc${e.vc}`).join(' '));
console.log('R4/R6/R7/R12 writes (value@row.line:char):'); console.log(regs.map(e=>`R${e.r}=${e.val}@${e.vc}.${e.sc}:${e.hc}`).join(' '));
const iv=[]; for(let i=1;i<HV.length;i++) iv.push(HV[i]-HV[i-1]);
const odd=iv.filter(d=>d!==39936); const sw=regs.filter(e=>e.r===4&&e.val===38); console.log('switch at',sw.length?sw[0].t:'-','resume (next R4 write) at', sw.length? (regs.find(e=>e.r===4&&e.t>sw[0].t+100000)||{}).t : '-', 'forced repaints at', globalThis.FT.join(' '), 'load span frames', HV.filter(t=>sw.length&&t>sw[0].t&&t<((regs.find(e=>e.r===4&&e.t>sw[0].t+100000)||{}).t||0)).length);
{ const t0=sw.length?sw[0].t:0, t1=(regs.find(e=>e.r===4&&e.t>t0+100000)||{t:0}).t; const inside=[]; for(let i=1;i<HV.length;i++) if(HV[i-1]>=t0-50000 && HV[i]<=t1+100000) inside.push(HV[i]-HV[i-1]); { const t0=sw.length?sw[0].t:0, t1=(regs.find(e=>e.r===4&&e.t>t0+100000)||{t:0}).t; for(let i=1;i<HV.length;i++){ const d=HV[i]-HV[i-1]; if(HV[i]>=t0-80000 && HV[i]<=t1+200000 && (d<39900||d>39960)) console.log(`ODD frame ${d} cycles ending ${HV[i]-t0} after the switch, ${HV[i]-t1} after the resume`); } }
console.log('LOAD WINDOW (switch-1 frame .. resume+2 frames):',inside.length,'frames, period min/max',Math.min(...inside),Math.max(...inside)); }
console.log('HARDWARE frames:',HV.length,'min/max interval',Math.min(...iv),Math.max(...iv),'forced repaints (a frame with no vsync):',forced,'| intervals not 39936:',odd.length, odd.slice(0,12).join(' '));
process.exit(0);
