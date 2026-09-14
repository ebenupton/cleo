// Is a title-screen difference a drawing bug, or the attract loop being a frame ahead?
//   node tools/titlephase.mjs <discA> <discB> [sampleCycles] [stepCycles] [window]
//
// titlediff.mjs compares the PAINTED frame at a fixed cycle count, which is the DISPLAY,
// not the drawn buffer -- the same distinction pixdiff.mjs draws, and for the same
// reason: a build whose render is 2000 cycles shorter reaches a given point in an
// animation sooner.  So when it reports a difference, ask whether B's frame at some
// nearby offset matches A's frame exactly.  If it does, nothing is drawn wrongly and
// the two builds are simply not at the same instant.
import { readdirSync, existsSync } from "node:fs";
import { pathToFileURL } from "node:url"; import { homedir } from "node:os"; import path from "node:path";
function findJsbeeb(){const npx=path.join(homedir(),".npm","_npx");for(const d of readdirSync(npx)){const p=path.join(npx,d,"node_modules","jsbeeb","src","machine-session.js");if(existsSync(p))return p;}throw new Error();}
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
const [dA,dB,sC,stC,wN]=process.argv.slice(2);
const SAMPLE=parseInt(sC??"6000000"), STEP=parseInt(stC??"2000"), WIN=parseInt(wN??"60");
async function boot(disc){                       // same sequence titlediff.mjs uses
  const s=new MachineSession("Master"); await s.initialise(); await s.boot(30);
  s.loadDisc(path.resolve(disc));
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  return s;
}
const A=await boot(dA), B=await boot(dB);
await A.runFor(SAMPLE);
const snap=(m)=>Uint8Array.from(m._completeFb8);
const a=snap(A);
const cmp=(x,y)=>{let n=0;for(let i=0;i<x.length;i+=4)if(x[i]!==y[i]||x[i+1]!==y[i+1]||x[i+2]!==y[i+2])n++;return n;};
await B.runFor(SAMPLE);
const b0=snap(B);
let best={d:cmp(a,b0),off:0,who:"-"};
console.log(`at the same instant: ${best.d} pixels differ`);
if(best.d===0){ console.log("nothing to explain: the frames are already identical"); process.exit(0); }
// Search BOTH directions.  Either build may be the one that is ahead, and advancing only
// the faster of the two can never close the gap -- which reads as "not phase" when it is.
for(let k=1;k<=WIN;k++){
  await B.runFor(STEP);
  const d=cmp(a,snap(B));
  if(d<best.d) best={d,off:k*STEP,who:"B"};
  if(d===0) break;
}
if(best.d){
  for(let k=1;k<=WIN;k++){
    await A.runFor(STEP);
    const d=cmp(snap(A),b0);
    if(d<best.d) best={d,off:k*STEP,who:"A"};
    if(d===0) break;
  }
}
console.log(best.off===0
  ? `no offset within +/-${WIN*STEP} cycles improves on it: the difference is NOT phase`
  : `${best.who} matches the other to ${best.d} pixels when advanced ${best.off} cycles` +
    (best.d===0 ? " -- exactly. The builds draw the same thing at different times." : ""));
