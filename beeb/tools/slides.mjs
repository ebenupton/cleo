// Capture the displayed picture of a level, Cleo landed at the start, as a plain linear
// screen file (20480 bytes for $3000) a Model B can *LOAD in MODE 2 or MODE 1.
//   node tools/slides.mjs <disc> <labels> <level> <mode 1|2> <frames> <out>
// The framebuffer is read at frame_top like shot.mjs; the picture (bar + 30 rows) is the
// 256 scanlines from 32, i.e. the whole of a standard MODE 1/2 screen.
import { open } from "./harness.mjs";
import { writeFileSync } from "node:fs";
const [disc,labels,lvS,modeS,nS,out]=process.argv.slice(2);
const mode=parseInt(modeS), N=parseInt(nS);
const H=await open({disc,labels,level:parseInt(lvS)});
for(let f=0;f<N;f++){ H.wr(H.A.keys,0); H.wr(H.A.hurt,1); H.wr(H.A.health,3); await H.runTo(H.A.frame_top); }
const fb=H.s._completeFb8, W=1024, X0=200, TOP=32;
const px=(x,l)=>{ const i=((TOP+l)*2*W + X0 + x)*4; return [fb[i],fb[i+1],fb[i+2]]; };
const scr=Buffer.alloc(20480);
for(let l=0;l<256;l++){
  for(let c=0;c<80;c++){
    let b=0;
    if(mode===2){
      for(let k=0;k<2;k++){ const [r,g,bl]=px((c*2+k)*4, l); const col=(r>127?1:0)|(g>127?2:0)|(bl>127?4:0);
        for(let bit=0;bit<4;bit++) if(col>>bit&1) b|=1<<(2*bit+(1-k)); }
    } else {
      for(let i=0;i<4;i++){ const [r,g,bl]=px((c*4+i)*2, l); const cy=g>127&&bl>127&&r<128, mg=r>127&&bl>127&&g<128, ye=r>127&&g>127&&bl<128;
        const d=cy?1:mg?2:ye?3:0; b|=((d>>1)&1)<<(7-i); b|=(d&1)<<(3-i); }
    }
    scr[(l>>3)*640 + c*8 + (l&7)]=b;
  } }
writeFileSync(out, scr);
console.log(`wrote ${out}: level ${lvS} mode ${mode} frame ${N}, cleo at (${H.rd(H.A.px)|(H.rd(H.A.px+1)<<8)},${H.rd(H.A.py)|(H.rd(H.A.py+1)<<8)})`);
process.exit(0);
