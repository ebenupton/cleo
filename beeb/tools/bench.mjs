// Cleo render benchmark -- our standard frame-budget set.
//   node tools/bench.mjs <level 0-7> [out.json]
// Measures the render cost (cycles from render_frame to render_done) at the fixed
// standing locations in tools/bench_locations.json for one level, under a jump
// (vertical scroll, 2nd frame of the rise) and a full-speed run (horizontal scroll,
// once |vx| reaches 80% of the 766-unit cap).  Fixed locations, so numbers are
// directly comparable across builds -- run all eight levels and combine to score.
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
const s=new MachineSession("Master");await s.initialise();await s.boot(30);s.loadDisc(path.resolve("build/cleo.ssd"));
s.keyDown(16);s.reset(true);await s.runFor(2_000_000);s.keyUp(16);
const cpu=s._machine.processor,rd=a=>cpu.readmem(a),wr=(a,v)=>cpu.writemem(a,v);
const w16=a=>rd(a)|(rd(a+1)<<8), s16=a=>{const v=w16(a);return v>=32768?v-65536:v;}, w16w=(a,v)=>{wr(a,v&255);wr(a+1,(v>>8)&255);};
let hit=false;const h=cpu.debugInstruction.add(pc=>(pc===A.title_loop?(hit=true):false));await s.runFor(80_000_000);h.remove();
wr(A.title_loop,0xa9);wr(A.title_loop+1,0);wr(A.title_loop+2,0xea);
for(let a=A.level_loop;a<A.level_loop+16;a++)if(rd(a)===0xa6&&rd(a+1)===(A.level&255)){wr(a,0xa2);wr(a+1,lv);break;}
await s.runFor(9_000_000);
wr(A.scan_keys,0x60);

// render cost = cycles from render_frame to render_done, captured per frame
let rfCyc=-1,lastRender=0,fcount=0;
cpu.debugInstruction.add(pc=>{
  if(pc===A.render_frame){rfCyc=cpu.currentCycles;fcount++;}
  else if(pc===A.render_done&&rfCyc>=0){let d=cpu.currentCycles-rfCyc;if(d<0)d+=2_000_000;lastRender=d;rfCyc=-1;}
  return false;});
async function frames(keys,n){const start=fcount;const costs=[];let last=fcount,guard=0;
  while(fcount-start<n && guard++<300){wr(A.keys,keys);await s.runFor(20_000);if(fcount>last){costs.push(lastRender);last=fcount;}}
  return costs;}   // guard: a death screen stops render_frame; bail rather than hang

const samples=[];
for(const loc of LOCS){
  w16w(A.px,loc.px);w16w(A.py,loc.py);w16w(A.vx,0);w16w(A.vy,0);
  await frames(0,30);                                   // settle onto the ground
  if(rd(A.health)===0){samples.push({px:loc.px,py:loc.py,jumpCost:null,runCost:null,dead:1});
    wr(A.keys,0);await frames(0,40);continue;}          // fell into a pit: skip, let it respawn
  const landPx=w16(A.px), landPy=w16(A.py);
  const jc=await frames(4,2);                           // jump: read the 2nd frame
  const jumpCost=jc.length>=2?jc[1]:(jc[0]||0);
  await frames(0,20);
  w16w(A.px,landPx);w16w(A.py,landPy);w16w(A.vx,0);w16w(A.vy,0);await frames(0,20);
  let dir=(landPx<((1<<8)*8/2))?2:1, runCost=null;      // whichever way has room
  for(const d of [dir,dir===2?1:2]){
    for(let f=0;f<40;f++){const c=await frames(d,1);if(Math.abs(s16(A.vx))>=THRESH){runCost=c[0];break;}}
    if(runCost!==null)break;
    w16w(A.px,landPx);w16w(A.py,landPy);w16w(A.vx,0);w16w(A.vy,0);await frames(0,15);
  }
  samples.push({px:landPx,py:landPy,jumpCost,runCost});
}
writeFileSync(out,JSON.stringify({lv,MAXVX,THRESH,samples}));
const m=a=>{a=a.filter(x=>x!=null).sort((x,y)=>x-y);return a.length?a[a.length>>1]:0;};
console.log(`L${lv}: ${samples.length} locations; jump med=${m(samples.map(x=>x.jumpCost))} run med=${m(samples.map(x=>x.runCost))} cy`);
