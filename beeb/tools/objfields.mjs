// What is the actual range of every object field, per type?
//   node tools/objfields.mjs <level> [frames]
// The rule is that a field is 8-bit unless it can be proved otherwise, so this reports
// the observed min/max per (type, field) and, separately, whether the high byte is ever
// anything but 0 or $FF -- 0/$FF only means it is a sign extension, not a 16-bit value.
import { open } from "./harness.mjs";
const lv=parseInt(process.argv[2]??"0"), N=parseInt(process.argv[3]??"250");
const H=await open({disc:"build/cleo.ssd",labels:"build/labels.txt",level:lv});
const OBJN=149, BASE=0xB000, ROMSEL=0xFE30, BANK_LVL=7;
const O=(k)=>BASE+OBJN*k;
const F={X:[O(2),O(3)],Y:[O(4),O(5)],A:[O(6),O(7)],B:[O(8),O(9)],C:[O(10),O(11)],D:[O(12),O(13)],E:[O(14),O(15)]};
const T=O(1);
const rd=(a)=>{const k=H.rd(0xF4);H.wr(ROMSEL,BANK_LVL);const v=H.rd(a);H.wr(ROMSEL,k);return v;};
const per={};
const PAT="ssrrrrrrrrrrrrrrrrrrrrrrjrjrjrjssllllllllllllllljljljss";
const K={s:0,r:2,l:1,j:4,rj:6,lj:5};
for(let f=0;f<N;f++){
  H.wr(H.A.keys,K[PAT[f%PAT.length]]??0); H.wr(H.A.hurt,1); H.wr(H.A.health,3);
  await H.runTo(H.A.frame_top);
  for(let i=0;i<OBJN;i++){
    const t=rd(T+i); if(t===0&&rd(F.X[0]+i)===0) continue;
    const e=(per[t] ??= {});
    for(const [n,[lo,hi]] of Object.entries(F)){
      if(n==="X"||n==="Y") continue;
      const l=rd(lo+i), hb=rd(hi+i);
      const v16=l|(hb<<8), sv=v16>=32768? v16-65536 : v16;
      const g=(e[n] ??= {min:1e9,max:-1e9,hi:new Set()});
      g.min=Math.min(g.min,sv); g.max=Math.max(g.max,sv); g.hi.add(hb);
    }
  }
}
const NAME={0:"star",1:"tramp",2:"snake",3:"rsnake",4:"bat",5:"walker",6:"walker2",7:"spike",9:"flame",10:"powerup",11:"vanish",12:"switch"};
for(const t of Object.keys(per).map(Number).sort((a,b)=>a-b)){
  const parts=[];
  for(const n of ["A","B","C","D","E"]){
    const g=per[t][n]; if(!g) continue;
    const his=[...g.hi];
    const wide = his.some(h=>h!==0&&h!==255);
    parts.push(`${n} ${String(g.min).padStart(6)}..${String(g.max).padStart(5)}${wide?" *16BIT*":(his.length>1?" (signed)":"")}`);
  }
  console.log(`L${lv} t${String(t).padStart(2)} ${(NAME[t]||"?").padEnd(8)} ${parts.join("  ")}`);
}
