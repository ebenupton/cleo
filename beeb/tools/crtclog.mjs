// CRTC register writes over one frame, each with the CRTC's row, scanline and character at
// the moment of the write: which scanline of a section the chain's writes land in.
//   PY=<player y> S=<dir> node tools/crtclog.mjs   (DISC, LABELS override the build)
import { open } from "./harness.mjs";
const H=await open({disc:process.env.DISC||"build/cleo.ssd",labels:process.env.LABELS||"build/labels.txt",level:0});
const A=H.A, cpu=H.cpu, v=H.s._video;
// put the window at a non-zero fine scroll (wy mod 4 != 0): Cleo standing on the lower pier gives wy=124 -> wfine 0; use py 168 -> wy 122
H.wr16(A.px,370); H.wr16(A.py,parseInt(process.env.PY||'168'));
for(let f=0;f<30;f++){ H.wr(A.keys,0); H.wr(A.hurt,1); H.wr(A.health,3); await H.runTo(A.frame_top); }
console.log('wx',H.rd16(A.wx),'wy',H.rd16(A.wy),'wfine',H.rd(A.wfine));
let idx=-1, log=[], lastRestart=null, on=false;
const h=cpu.debugWrite.add((addr,val)=>{ if(!on) return false;
  if(addr===0xfe00) idx=val;
  else if(addr===0xfe01) log.push({t:H.cyc(), r:idx, val, vc:v.vertCounter, sc:v.scanlineCounter, hc:v.horizCounter});
  return false; });
on=true; await H.runTo(A.frame_top); await H.runTo(A.frame_top); on=false; h.remove();
// print grouped by T1 step: a new group when R9 is written
let t0=null;
for(const e of log){ if(e.r===9){ t0=e.t; console.log('--- step (R9 write) at vc',e.vc,'sc',e.sc,'hc',e.hc); }
  console.log(`  R${String(e.r).padStart(2)} = $${e.val.toString(16).padStart(2,'0')}  vc=${e.vc} sc=${e.sc} hc=${e.hc}` + (t0!==null?`  (+${e.t-t0} cy after R9)`:'')); }
process.exit(0);
