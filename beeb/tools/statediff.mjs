// Compare the whole object-state array between two builds, frame by frame.
//   node tools/statediff.mjs <discA> <labelsA> <discB> <labelsB> <level> [frames]
//
// process_object loads 14 bytes of per-object state into zero page, dispatches, and
// stores 10 back, for every object every step -- whatever the handler actually uses.
// Trimming that per type is worth ~1% of the frame, but it breaks quietly: a field the
// handler writes and the epilogue no longer stores just stops advancing, and a pixel
// diff will not see it until the object drifts.  So check the state itself: all 16
// O_* arrays x 149 objects, every frame, byte for byte.
import { open } from "./harness.mjs";
const [dA,lA,dB,lB,lvS,nS]=process.argv.slice(2);
const lv=parseInt(lvS??"0"), N=parseInt(nS??"200");
const OBJN=149, BASE=0xB000, NARR=16, ROMSEL=0xFE30, BANK_LVL=7;
const A=await open({disc:dA,labels:lA,level:lv}), B=await open({disc:dB,labels:lB,level:lv});
const snap=(H)=>{const k=H.rd(0xF4);H.wr(ROMSEL,BANK_LVL);
  const b=Buffer.alloc(OBJN*NARR); for(let i=0;i<b.length;i++) b[i]=H.rd(BASE+i);
  H.wr(ROMSEL,k); return b;};
const NAMES=["STAMP","TYPE","XL","XH","YL","YH","AL","AH","BL","BH","CL","CH","DL","DH","EL","EH"];
// STATEDIFF_IGNORE=AH,BH masks whole arrays.  Converting a field to 8 bits stops its
// high half being written, so it holds 0 rather than a sign extension: the value is
// unchanged and the array is dead, but every frame would otherwise report a difference
// and drown the signal this tool exists to give.
const IGN = new Set((process.env.STATEDIFF_IGNORE || "").split(",").filter(Boolean));
const MASK = Buffer.alloc(OBJN * NARR, 1);
for (const n of IGN) { const i = NAMES.indexOf(n); if (i < 0) throw new Error(`unknown array ${n}`); MASK.fill(0, i * OBJN, (i + 1) * OBJN); }
const PAT="ssrrrrrrrrrrrrrrrrrrrrrrjrjrjrjssllllllllllllllljljljss";
const K={s:0,r:2,l:1,j:4,rj:6,lj:5};
let bad=0,first=-1,worst="";
for(let f=0;f<N;f++){
  for(const H of [A,B]){H.wr(H.A.keys,K[PAT[f%PAT.length]]??0);H.wr(H.A.hurt,1);H.wr(H.A.health,3);await H.runTo(H.A.frame_top);}
  const sa=snap(A), sb=snap(B);
  if(IGN.size) for(let i=0;i<sa.length;i++) if(!MASK[i]) sb[i]=sa[i];
  if(!sa.equals(sb)){
    bad++; if(first<0){first=f;
      const diff={};
      for(let i=0;i<sa.length;i++) if(sa[i]!==sb[i]){const arr=NAMES[(i/OBJN)|0],o=i%OBJN;(diff[arr]??=[]).push(`obj${o} ${sa[i]}->${sb[i]}`);}
      worst=Object.entries(diff).map(([k,v])=>`${k}: ${v.slice(0,4).join(", ")}${v.length>4?` (+${v.length-4})`:""}`).join(" | ");
    }}
}
if(IGN.size) console.log(`  (ignoring ${[...IGN].join(",")})`);
console.log(bad? `L${lv}: OBJECT STATE DIVERGES on ${bad}/${N} frames, first at ${first}\n   ${worst}`
               : `L${lv}: object state identical over ${N} frames (${OBJN*NARR} bytes each)`);
process.exit(bad?1:0);
