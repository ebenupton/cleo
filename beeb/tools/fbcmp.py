import json, sys, base64, numpy as np
from PIL import Image
S=sys.argv[1]; a=json.load(open(sys.argv[2])); b=json.load(open(sys.argv[3])); tag=sys.argv[4]
wa={w['f']:w for w in a['windows']}; wb={w['f']:w for w in b['windows']}
common=sorted(set(wa)&set(wb)); bad=[]
for f in common:
    x=np.frombuffer(base64.b64decode(wa[f]['win']),np.uint8); y=np.frombuffer(base64.b64decode(wb[f]['win']),np.uint8)
    if not np.array_equal(x&0x3F,y&0x3F): bad.append((f,int(((x&0x3F)!=(y&0x3F)).sum())))
print(f"{tag}: {len(common)} common rendered frames ({len(wa)}/{len(wb)}), {len(bad)} differ: {bad[:8]}")
BEEB=np.array([[0,0,0],[255,0,0],[0,255,0],[255,255,0],[0,0,255],[255,0,255],[0,255,255],[255,255,255]],np.uint8)
def img(buf):
    rows=27; im=np.zeros((rows*8,160,3),np.uint8)
    for r in range(rows):
        for c in range(80):
            for y in range(8):
                v=buf[r*640+c*8+y]
                l=((v>>1)&1)|(((v>>3)&1)<<1)|(((v>>5)&1)<<2); rr=(v&1)|(((v>>2)&1)<<1)|(((v>>4)&1)<<2)
                im[r*8+y,2*c]=BEEB[l]; im[r*8+y,2*c+1]=BEEB[rr]
    return im
for f,n in bad[:2]:
    x=np.frombuffer(base64.b64decode(wa[f]['win']),np.uint8); y=np.frombuffer(base64.b64decode(wb[f]['win']),np.uint8)
    ia=img(x); ib=img(y); d=ia.copy(); m=(ia!=ib).any(axis=2); d[m]=[255,0,255]
    sheet=np.concatenate([ia,ib,d],axis=0); Image.fromarray(sheet).resize((640,sheet.shape[0]*2),Image.NEAREST).save(f"{S}/fbdiff_{tag}_{f}.png")
    ys,xs=np.where(m); print(f"  frame {f}: {n} bytes differ; pixel bbox x {xs.min()}..{xs.max()} y {ys.min()}..{ys.max()}")
