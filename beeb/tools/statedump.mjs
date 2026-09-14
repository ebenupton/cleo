import { open } from "/Users/ebenupton/cleo/beeb/tools/harness.mjs";
const lv=parseInt(process.argv[2]??"0"), N=parseInt(process.argv[3]??"12");
const H=await open({disc:"build/cleo.ssd",labels:"build/labels.txt",level:lv});
for(let f=0;f<N;f++){ H.wr(H.A.keys,0); H.wr(H.A.hurt,1); H.wr(H.A.health,3); await H.runTo(H.A.frame_top); }
await H.runTo(H.A.copy_partial);
const r16=(a)=>H.rd(a)|(H.rd(a+1)<<8);
const out={frame:N, wx:r16(H.A.wx), wy:r16(H.A.wy), px:r16(H.A.px), py:r16(H.A.py), facing:H.rd(H.A.facing), lives:H.rd(H.A.lives), health:H.rd(H.A.health), stars:H.rd(H.A.stars), score:r16(H.A.score), level:H.rd(H.A.level), nspr:H.rd(H.A.NSPR), sprites:[]};
for(let i=0;i<out.nspr;i++){ const y=i*5; out.sprites.push({id:H.rd(H.A.SPRLIST+y), x:r16(H.A.SPRLIST+y+1), y:r16(H.A.SPRLIST+y+3)}); }
console.log(JSON.stringify(out));
