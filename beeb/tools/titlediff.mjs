// Compare the title screen and menus between two builds.
//   node tools/titlediff.mjs <discA> <discB>
//
// tools/pixdiff.mjs only ever looks at gameplay, because the harness drives a level.
// The title screen and the menus go through the same sprite blitter by a different
// route -- drawsprite's @titledir path, with the directory and data in the title bank
// rather than in main RAM and bank 4 -- so a blitter change can be perfect in-level and
// wrong here.  This runs both builds through the attract loop and compares the painted
// frame every 2M cycles.
import { readdirSync, existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url"; import { homedir } from "node:os"; import path from "node:path";
function findJsbeeb(){const npx=path.join(homedir(),".npm","_npx");for(const d of readdirSync(npx)){const p=path.join(npx,d,"node_modules","jsbeeb","src","machine-session.js");if(existsSync(p))return p;}throw new Error();}
const { MachineSession } = await import(pathToFileURL(findJsbeeb()));
async function boot(disc){
  const s=new MachineSession("Master"); await s.initialise(); await s.boot(30); s.loadDisc(path.resolve(disc));
  s.keyDown(16); s.reset(true); await s.runFor(2_000_000); s.keyUp(16);
  return s;
}
const [dA,dB]=process.argv.slice(2);
const A=await boot(dA), B=await boot(dB);
const fa=A._completeFb8, fb=B._completeFb8;
const diff=()=>{let n=0;for(let i=0;i<fa.length;i+=4)if(fa[i]!==fb[i]||fa[i+1]!==fb[i+1]||fa[i+2]!==fb[i+2])n++;return n;};
let bad=0;
for (let step=0; step<40; step++){
  await A.runFor(2_000_000); await B.runFor(2_000_000);
  const d=diff();
  if(d){ bad++; if(bad<=3) console.log(`  after ${(step+1)*2}M cycles: ${d}/640000 pixels differ`); }
}
console.log(bad? `title/menu: DIFFERS on ${bad}/40 samples` : "title/menu: pixel-identical over 80M cycles (attract loop, menus)");
process.exit(bad?1:0);
