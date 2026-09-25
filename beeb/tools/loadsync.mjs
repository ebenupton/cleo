// The frame period across a level load (the load mode: engine.s load_begin).  Boots to
// the title, runs through the load into play, and reports: software vsync acknowledges,
// the R4/R6/R7 writes with the CRTC row they landed on, and jsbeeb's own frame
// timing -- paintAndClear at every vsync, or forced when a frame passes without one.
//   node tools/loadsync.mjs   (DISC, LABELS override the build)
// Master: boot to the title, then run through the level load logging every vsync
// acknowledge (a write of $02 to the system VIA IFR) and every CRTC R4/R7 write, so
// the frame period across the load can be seen.
import { findJsbeeb, loadLabels, Harness, patchBlink } from "./harness.mjs";
import { pathToFileURL } from "node:url"; import path from "node:path";
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const A = loadLabels(process.env.LABELS||"build/labels.txt");
const s = new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(process.env.DISC||"build/cleo.ssd"));
const H = new Harness(s, A), cpu=H.cpu, v=s._video;
// hardware-side: jsbeeb paints at each CRTC vsync, and forces a paint when a frame passes with none
const HV=[]; let forced=0; { const v0=s._video; const opc=v0.paintAndClear.bind(v0);
  const FT=[]; v0.paintAndClear=function(){ if(v0.bitmapY>=768){ forced++; FT.push(H.cyc()); } HV.push(H.cyc()); return opc(); }; globalThis.FT=FT; }

s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
await H.runTo(A.title_loop, 120_000_000);
H.wr(A.title_loop, 0xa9); H.wr(A.title_loop + 1, 0); H.wr(A.title_loop + 2, 0xea);
for (let a = A.level_loop; a < A.level_loop + 16; a++) if (H.rd(a) === 0xa6 && H.rd(a + 1) === (A.level & 255)) { H.wr(a, 0xa2); H.wr(a + 1, 0); break; }
let idx=-1, vs=[], regs=[], lastVs=null;
const h=cpu.debugWrite.add((addr,val)=>{ if(addr===0xfe00) idx=val;
  else if(addr===0xfe01 && (idx===4||idx===7||idx===6)) regs.push({t:H.cyc(), r:idx, val, vc:v.vertCounter, sc:v.scanlineCounter});
  else if(addr===0xfe4d && (val&2)) { const t=H.cyc(); vs.push({t, d: lastVs===null?0:t-lastVs, vc:v.vertCounter}); lastVs=t; }
  return false; });
const t0=H.cyc();
await H.runTo(A.level_init, 40_000_000);
const tLoad=H.cyc();
H.wr(A.scan_keys, 0x60); patchBlink(H);
await H.runTo(A.frame_top, 40_000_000);
for(let f=0;f<6;f++){ H.wr(A.keys,0); H.wr(A.hurt,1); H.wr(A.health,3); await H.runTo(A.frame_top); }
h.remove();
const t1=H.cyc();
console.log('vsync intervals (cycles; 39936 = a 312-line frame), from title through the load to play:');
console.log(vs.map(e=>e.d).join(' '));
const bad=vs.filter(e=>e.d && e.d!==39936); console.log('intervals != 39936:', bad.length, bad.slice(0,8).map(e=>`${e.d}@vc${e.vc}`).join(' '));
console.log('R4/R6/R7 writes around the load (value@row):'); console.log(regs.map(e=>`R${e.r}=${e.val}@${e.vc}.${e.sc}`).join(' '));
const iv=[]; for(let i=1;i<HV.length;i++) iv.push(HV[i]-HV[i-1]);
const odd=iv.filter(d=>d!==39936); const sw=regs.filter(e=>e.r===4&&e.val===38); console.log('switch at',sw.length?sw[0].t:'-','resume (next R4 write) at', sw.length? (regs.find(e=>e.r===4&&e.t>sw[0].t+100000)||{}).t : '-', 'forced repaints at', globalThis.FT.join(' '), 'load span frames', HV.filter(t=>sw.length&&t>sw[0].t&&t<((regs.find(e=>e.r===4&&e.t>sw[0].t+100000)||{}).t||0)).length);
{ const t0=sw.length?sw[0].t:0, t1=(regs.find(e=>e.r===4&&e.t>t0+100000)||{t:0}).t; const inside=[]; for(let i=1;i<HV.length;i++) if(HV[i-1]>=t0-50000 && HV[i]<=t1+100000) inside.push(HV[i]-HV[i-1]); console.log('LOAD WINDOW (switch-1 frame .. resume+2 frames):',inside.length,'frames, period min/max',Math.min(...inside),Math.max(...inside)); }
console.log('HARDWARE frames:',HV.length,'min/max interval',Math.min(...iv),Math.max(...iv),'forced repaints (a frame with no vsync):',forced,'| intervals not 39936:',odd.length, odd.slice(0,12).join(' '));
process.exit(0);
