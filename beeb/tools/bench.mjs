// Cleo render benchmark -- our standard frame-budget set.
//   node tools/bench.mjs <level 0-7> [out.json]
// Measures the render WORK (cycles from select_backbuf to render_done) at the fixed
// standing locations in tools/bench_locations.json for one level, under a jump
// (vertical scroll: mean of rise frames 2-5) and a full-speed run (horizontal
// scroll: mean of the 4 frames after |vx| reaches 80% of the 766-unit cap).
// Fixed locations, so numbers are directly comparable across builds -- run all
// eight levels and combine to score.
//
// Three measurement traps this tool now avoids (each silently skewed earlier runs):
//   1. render_frame begins with wait_flip, an idle spin for the previous flip that
//      is 6-23k cycles and flips with buffer parity: it is not rendering work, so the
//      window starts at select_backbuf (the first instruction after it).
//   2. The player spawns invulnerable ('hurt' set, cleared at game frame >= 65) and
//      while hurt she is drawn only every 4th frame -- so a naive settle measures a
//      blinking, 3/4-absent player (~20k/frame light) whose draw always lands on one
//      buffer.  We patch the blink test out (see patchBlink) so she is always drawn.
//   3. Rendering ping-pongs between two buffers whose per-frame cost differs, so a
//      single frame is a +-15% coin flip on parity.  Average an even frame count.
import { readdirSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url"; import { homedir } from "node:os"; import path from "node:path";
function findJsbeeb(){const npx=path.join(homedir(),".npm","_npx");for(const d of readdirSync(npx)){const p=path.join(npx,d,"node_modules","jsbeeb","src","machine-session.js");if(existsSync(p))return p;}throw new Error("jsbeeb not found");}
const {MachineSession}=await import(pathToFileURL(findJsbeeb()));

const lv=parseInt(process.argv[2]);
const out=process.argv[3]||`build/bench_L${lv}.json`;
const HERE=path.dirname(new URL(import.meta.url).pathname);
const LOCS=JSON.parse(readFileSync(path.join(HERE,"bench_locations.json"),"utf8")).filter(l=>l.lv===lv);
const A={};for(const m of readFileSync("build/labels.txt","utf8").matchAll(/^al ([0-9A-F]+) \.(\w+)$/gm))A[m[2]]=parseInt(m[1],16);

const MAXVX=766, THRESH=Math.round(0.8*MAXVX);
const AVG_FRAMES=4;                 // even: two frames per buffer
const s=new MachineSession("Master");await s.initialise();await s.boot(30);s.loadDisc(path.resolve("build/cleo.ssd"));
s.keyDown(16);s.reset(true);await s.runFor(2_000_000);s.keyUp(16);
const cpu=s._machine.processor,rd=a=>cpu.readmem(a),wr=(a,v)=>cpu.writemem(a,v);
const w16=a=>rd(a)|(rd(a+1)<<8), s16=a=>{const v=w16(a);return v>=32768?v-65536:v;}, w16w=(a,v)=>{wr(a,v&255);wr(a+1,(v>>8)&255);};
let hit=false;const h=cpu.debugInstruction.add(pc=>(pc===A.title_loop?(hit=true):false));await s.runFor(80_000_000);h.remove();
wr(A.title_loop,0xa9);wr(A.title_loop+1,0);wr(A.title_loop+2,0xea);
for(let a=A.level_loop;a<A.level_loop+16;a++)if(rd(a)===0xa6&&rd(a+1)===(A.level&255)){wr(a,0xa2);wr(a+1,lv);break;}
await s.runFor(9_000_000);
wr(A.scan_keys,0x60);

// Disable the invulnerability blink so the player is drawn on every frame.
// While 'hurt' is set, logic.s draws her only when (frame & 3) == 0:
//     lda hurt / beq @drawp / lda frame / and #3 / bne @boom
// Patching 'lda hurt' (A5 hurt) to 'lda #0' (A9 00) makes the beq always taken, so
// the draw is unconditional.  Zeroing the 'hurt' variable instead would also strip
// her invulnerability and let an enemy damage her every frame, so we leave it alone
// and only remove the blink.  The code lives in LOGIC (bank 7, above $8900), which
// level loads do not overwrite, so one patch holds for the whole run.
function patchBlink(){
  const ROMSEL=0xFE30, keep=rd(0xF4);
  wr(ROMSEL,7);
  const hits=[];
  for(let a=0x8000;a<0xC000-8;a++)
    if(rd(a)===0xA5&&rd(a+1)===A.hurt&&rd(a+2)===0xF0&&rd(a+4)===0xA5&&
       rd(a+5)===(A.frame&255)&&rd(a+6)===0x29&&rd(a+7)===0x03&&rd(a+8)===0xD0) hits.push(a);
  for(const a of hits){wr(a,0xA9);wr(a+1,0x00);}
  wr(ROMSEL,keep);
  return hits;
}
const blinkPatch=patchBlink();
if(blinkPatch.length!==1) console.error(`WARNING: blink test matched ${blinkPatch.length} sites (expected 1) -- player may still blink`);

// render work = cycles from select_backbuf (just past wait_flip) to render_done
let inFrame=false,wkCyc=-1,lastRender=0,fcount=0;
cpu.debugInstruction.add(pc=>{
  if(pc===A.render_frame){inFrame=true;wkCyc=-1;}
  else if(pc===A.select_backbuf&&inFrame&&wkCyc<0){wkCyc=cpu.currentCycles;}
  else if(pc===A.render_done&&inFrame){let d=cpu.currentCycles-(wkCyc>=0?wkCyc:cpu.currentCycles);if(d<0)d+=2_000_000;
    lastRender=d;inFrame=false;fcount++;}
  return false;});
async function frames(keys,n){const start=fcount;const costs=[];let last=fcount,guard=0;
  while(fcount-start<n && guard++<300){wr(A.keys,keys);await s.runFor(20_000);if(fcount>last){costs.push(lastRender);last=fcount;}}
  return costs;}   // guard: a death screen stops render_frame; bail rather than hang
// settle: drop to the ground and come to rest.  With the blink patched out the hurt
// state no longer changes what is drawn, so there is nothing to wait out beyond the fall.
async function settle(){await frames(0,12);let n=0;
  while(n++<120){if(rd(A.health)!==0&&s16(A.vy)===0)break;await frames(0,1);}
  await frames(0,4);return rd(A.health)!==0;}
const mean=a=>a.length?Math.round(a.reduce((x,y)=>x+y,0)/a.length):null;

const samples=[];
for(const loc of LOCS){
  w16w(A.px,loc.px);w16w(A.py,loc.py);w16w(A.vx,0);w16w(A.vy,0);
  await settle();
  if(rd(A.health)===0){samples.push({px:loc.px,py:loc.py,jumpCost:null,runCost:null,dead:1});
    wr(A.keys,0);await frames(0,40);continue;}          // fell into a pit: skip, let it respawn
  const landPx=w16(A.px), landPy=w16(A.py);
  const jc=await frames(4,1+AVG_FRAMES);                // jump: mean of rise frames 2..5
  const jumpCost=mean(jc.slice(1,1+AVG_FRAMES));
  await frames(0,20);
  w16w(A.px,landPx);w16w(A.py,landPy);w16w(A.vx,0);w16w(A.vy,0);await settle();
  let dir=(landPx<((1<<8)*8/2))?2:1, runCost=null;      // whichever way has room
  for(const d of [dir,dir===2?1:2]){
    for(let f=0;f<40;f++){await frames(d,1);if(Math.abs(s16(A.vx))>=THRESH){runCost=mean(await frames(d,AVG_FRAMES));break;}}
    if(runCost!==null)break;
    w16w(A.px,landPx);w16w(A.py,landPy);w16w(A.vx,0);w16w(A.vy,0);await settle();
  }
  samples.push({px:landPx,py:landPy,jumpCost,runCost,hurt:rd(A.hurt)});
}
writeFileSync(out,JSON.stringify({lv,MAXVX,THRESH,blinkPatched:blinkPatch.length,
  method:"work=select_backbuf..render_done; blink patched out (player drawn every frame); mean of "+AVG_FRAMES+" frames",samples}));
const m=a=>{a=a.filter(x=>x!=null).sort((x,y)=>x-y);return a.length?a[a.length>>1]:0;};
console.log(`L${lv}: ${samples.length} locations; jump med=${m(samples.map(x=>x.jumpCost))} run med=${m(samples.map(x=>x.runCost))} cy (work, no-blink, ${AVG_FRAMES}-frame mean)`);
