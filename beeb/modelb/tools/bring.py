# Compare both rings in build/ram.bin against a reference render of the map.
import json, sys
st=json.load(open('build/state.json'))
ram=open('build/ram.bin','rb').read(); tiles=open('build/tiles.bin','rb').read(); mp=open('build/map.bin','rb').read()

print(st)
only=None
if len(sys.argv)>1 and sys.argv[1]=='cur': only=st['curbuf']
for buf,base in ((0,0x0a80),(1,0x4680)):
    if only is not None and buf!=only: continue
    wcx, wcy = st['bptx'][buf], st['bpty'][buf]
    bad=[]
    for r in range(22):
        cy=wcy+r
        for c in range(80):
            cx=wcx+c; tx,ty=cx>>2,cy>>1
            if ty>=32 or tx>=32: continue
            t=mp[ty*32+tx]
            o=t*64+(cy&1)*32+(cx&3)*8
            exp=tiles[o:o+8]
            rc=((cy%23)*80+cx)%1840
            if ram[base+rc*8: base+rc*8+8]!=exp: bad.append((r,c))
    print(f'buffer {buf}: {len(bad)} chars differ; {bad[:12]}')
