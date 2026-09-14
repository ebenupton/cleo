// Dump the painted frame at a frame boundary as a PNG, from the same harness the
// comparators use -- so what is looked at is what was measured, not an emulator window
// caught mid-frame.   node tools/shot.mjs <disc> <labels> <level> <frames> <out.png>
import { open } from "./harness.mjs";
import { writeFileSync } from "node:fs";
import { deflateSync } from "node:zlib";
const [disc,labels,lvS,nS,out]=process.argv.slice(2);
const H=await open({disc,labels,level:parseInt(lvS??"0")});
const PAT="ssrrrrrrrrrrrrrrrrrrrrrrjrjrjrjssllllllllllllllljljljss";
const K={s:0,r:2,l:1,j:4,rj:6,lj:5};
for(let f=0;f<parseInt(nS??"40");f++){ H.wr(H.A.keys,K[PAT[f%PAT.length]]??0); H.wr(H.A.hurt,1); H.wr(H.A.health,3); await H.runTo(H.A.frame_top); }
const fb=H.s._completeFb8, W=1024, X0=200, X1=840, Y0=parseInt(process.env.SHOT_Y0??"80"), Y1=parseInt(process.env.SHOT_Y1??"620"), w=X1-X0, h=Y1-Y0;
const raw=Buffer.alloc((w*3+1)*h);
for(let y=0;y<h;y++){ raw[y*(w*3+1)]=0; for(let x=0;x<w;x++){ const i=((Y0+y)*W+X0+x)*4, o=y*(w*3+1)+1+x*3; raw[o]=fb[i]; raw[o+1]=fb[i+1]; raw[o+2]=fb[i+2]; } }
const crcT=new Int32Array(256); for(let n=0;n<256;n++){ let c=n; for(let k=0;k<8;k++) c=c&1?0xEDB88320^(c>>>1):c>>>1; crcT[n]=c; }
const crc=(b)=>{ let c=-1; for(const x of b) c=crcT[(c^x)&255]^(c>>>8); return (c^-1)>>>0; };
const chunk=(t,d)=>{ const tb=Buffer.from(t), len=Buffer.alloc(4); len.writeUInt32BE(d.length); const cb=Buffer.alloc(4); cb.writeUInt32BE(crc(Buffer.concat([tb,d]))); return Buffer.concat([len,tb,d,cb]); };
const ihdr=Buffer.alloc(13); ihdr.writeUInt32BE(w,0); ihdr.writeUInt32BE(h,4); ihdr[8]=8; ihdr[9]=2;
writeFileSync(out, Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk("IHDR",ihdr), chunk("IDAT",deflateSync(raw)), chunk("IEND",Buffer.alloc(0))]));
console.log(`wrote ${out} (${w}x${h}) at frame ${nS}, wcy=${H.rd(H.A.wcy)} wfine=${H.rd(H.A.wfine)}`);
