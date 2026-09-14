// Compare what the WINDOW shows in two hardware-wrapped builds whose ring geometry
// differs, cell by cell, and say WHERE the first disagreement is.
//   node tools/ringdiff.mjs <discA> <labelsA> <discB> <labelsB> <level> [frames] [rows]
// Displayed row r, column c is ring char (ringS + r*80 + c) mod RINGCHARS, at
// RINGBASE + char*8.  Valid only for builds where the ring IS what is displayed -- the
// old mirror build served straddling rows from a copy, and its ring tail lies.
import { open } from "./harness.mjs";
const [dA,lA,dB,lB,lvS,nS,rS]=process.argv.slice(2);
const lv=parseInt(lvS??"0"), N=parseInt(nS??"80"), ROWS=parseInt(rS??"27");
const A=await open({disc:dA,labels:lA,level:lv}), B=await open({disc:dB,labels:lB,level:lv});
const geom=(H)=>{ const rows=[]; for(let r=0;r<32;r++){ const a=H.rd(H.A.RINGLO+r)|(H.rd(H.A.RINGHI+r)<<8); if(a<0x3000||a>=0x8000) break; rows.push(a);} return {base:rows[0], n:rows.length*80}; };
const PAT="ssrrrrrrrrrrrrrrrrrrrrrrjrjrjrjssllllllllllllllljljljss"; const K={s:0,r:2,l:1,j:4,rj:6,lj:5};
let bad=0, shown=0;
for(let f=0;f<N;f++){
  for(const H of [A,B]){ H.wr(H.A.keys,K[PAT[f%PAT.length]]??0); H.wr(H.A.hurt,1); H.wr(H.A.health,3); await H.runTo(H.A.frame_top); }
  const ga=geom(A), gb=geom(B);
  const sA=A.rd(A.A.ringS)|(A.rd(A.A.ringS+1)<<8), sB=B.rd(B.A.ringS)|(B.rd(B.A.ringS+1)<<8);
  const runs=[]; let d=0;
  for(let r=0;r<ROWS;r++){ let run=null;
    for(let c=0;c<80;c++){ const ca=(sA+r*80+c)%ga.n, cb=(sB+r*80+c)%gb.n; let dd=0;
      for(let y=0;y<8;y++) if(A.rd(ga.base+ca*8+y)!==B.rd(gb.base+cb*8+y)) dd++;
      if(dd){ d+=dd; if(run&&run.c1===c-1) run.c1=c; else { run={r,c0:c,c1:c}; runs.push(run);} } } }
  if(d){ bad++; if(shown<3){ shown++;
    console.log(`frame ${f}: ${d} bytes differ; wfine A=${A.rd(A.A.wfine)} B=${B.rd(B.A.wfine)} barq A=${A.rd(A.A.barq)} B=${B.rd(B.A.barq)}`);
    for(const q of runs.slice(0,8)) console.log(`   row ${q.r} cols ${q.c0}-${q.c1}`); } }
}
console.log(bad?`L${lv}: WINDOW DIFFERS on ${bad}/${N} frames`:`L${lv}: window contents identical over ${N} frames (${ROWS} rows)`);
