// MODE 1 mask oracle: after draw_sprites, every sprite in the list is compared with the
// ring, byte by byte, against its data and mask plane: where the mask says both pixels
// opaque the ring byte must equal the data byte; where one pixel is opaque, that
// pixel's two dots must; where neither, nothing is checked.  Mirrored sprites are
// checked through the same four-dot reversal the blitter uses.
//   node tools/maskcheck.mjs <level> [frames]
import { open } from "./harness.mjs";
import { readFileSync } from "node:fs";
const lv=parseInt(process.argv[2]??"0"), N=parseInt(process.argv[3]??"12");
const H=await open({disc:"build/mode1/cleo.ssd",labels:"build/mode1/labels.txt",level:lv});
const tab=readFileSync("build/SPRTAB"), spr=readFileSync("build/SPR"), andy=readFileSync("build/SPRAND"), box=readFileSync("build/BOX"), sm=readFileSync("build/SPRMASK");
const bank=(flags,a)=>{ if(flags&0x10) return box[a-0xB000]; if((flags&4)&&a<0x9000) return andy[a-0x8000]; return spr[a-0x8000]; };
const swap=(b)=>((b&0x80)>>3)|((b&0x40)>>1)|((b&0x20)<<1)|((b&0x10)<<3)|((b&8)>>3)|((b&4)>>1)|((b&2)<<1)|((b&1)<<3);
const PAT="ssrrrrrrrrrrrrrrrrrrrrrrjrjrjrjssllllllllllllllljljljss"; const K={s:0,r:2,l:1,j:4,rj:6,lj:5};
let checked=0, bad=0, sprites=0;
for(let f=0;f<N;f++){ H.wr(H.A.keys,K[PAT[f%PAT.length]]??0); H.wr(H.A.hurt,1); H.wr(H.A.health,3); await H.runTo(H.A.frame_top);
  await H.runTo(H.A.copy_partial);
  const r16=(a)=>H.rd(a)|(H.rd(a+1)<<8); const wx=r16(H.A.wx), wy=r16(H.A.wy), wfine=H.rd(H.A.wfine), ringS=r16(H.A.ringS);
  const n=H.rd(H.A.NSPR);
  // rectangles of every sprite in draw order: bytes a later sprite covers are not this one's to answer for
  const rects=[]; for(let i=0;i<n;i++){ const e=H.A.SPRLIST+i*5; let id=H.rd(e); if(id>=118) id-=15; const x=r16(e+1), y=r16(e+3);
    const t=tab.subarray(id*8,id*8+8); const W=t[2], refx=t[4]<<24>>24, refy=t[5]<<24>>24, lines=t[7]; const c0=(x-refx-wx)>>1, lb0=2*(y-refy-wy)+wfine;
    rects.push({c0, c1:c0+W-1, l0:lb0, l1:lb0+lines-1}); }
  const covered=(i,sc,line)=>{ for(let j=i+1;j<n;j++){ const r=rects[j]; if(sc>=r.c0&&sc<=r.c1&&line>=r.l0&&line<=r.l1) return true; } return false; };
  for(let i=0;i<n;i++){ const e=H.A.SPRLIST+i*5; let id=H.rd(e); const x=r16(e+1), y=r16(e+3);
    if(id>=103) continue;                       // box stars: copy blitter, not this oracle
    const t=tab.subarray(id*8,id*8+8); const ptr=t[0]|(t[1]<<8), W=t[2], hpx=t[3], refx=t[4]<<24>>24, refy=t[5]<<24>>24, flags=t[6], lines=t[7];
    const mbase=sm[id*2]|(sm[id*2+1]<<8); if(!mbase) continue;
    const mirror=flags&1; sprites++;
    const sx=x-refx-wx, sy=y-refy-wy; const c0=sx>>1; const lb0=2*sy+wfine;   // c0: screen byte column of image column 0 (mirrored: of W-1)
    const groups=(W+3)>>2;
    for(let ic=0;ic<W;ic++){ const sc=mirror? c0+(W-1-ic) : c0+ic; if(sc<0||sc>=80) continue;
      for(let l=0;l<lines;l++){ const line=lb0+l; if(line<0||line>=31*8) continue; if(covered(i,sc,line)) continue;
        const row=line>>3, ra=line&7; const ch=(ringS+row*80+sc)%2560; const addr=0x3000+ch*8+ra;
        let data=bank(flags, ptr+ic*lines+l); const pr=l>>1; const mb=bank(flags, mbase+(ic>>2)*hpx+pr); const pair=(mb>>(6-2*(ic&3)))&3;
        let m = (pair&2?0:0xCC)|(pair&1?0:0x33);
        if(mirror){ data=swap(data); m=swap(m); }
        if(m===0xFF) continue;
        const got=H.rd(addr); checked++;
        if(((got^data)&~m&0xFF)!==0){ bad++; if(bad<=8) console.log(`frame ${f} id ${id}${mirror?'M':''} col ${ic} line ${l}: ring $${got.toString(16)} data $${data.toString(16)} mask $${m.toString(16)} pair ${pair}`); }
      } } }
}
console.log(`L${lv}: ${sprites} sprite draws, ${checked} opaque byte-pixels checked, ${bad} wrong`);
process.exit(0);
