import json
st=json.load(open('build/state.json'))
ram=open('build/ram.bin','rb').read(); tiles=open('build/tiles.bin','rb').read(); mp=open('build/map.bin','rb').read()
def expect(cx,cy):
    tx,ty=cx>>2,cy>>1
    if ty>=32 or tx>=32: return None
    t=mp[ty*32+tx]; o=t*64+(cy&1)*32+(cx&3)*8
    return tiles[o:o+8]
buf=st['curbuf']; base=(0x0a80,0x4680)[buf]
wcx,wcy=st['bptx'][buf],st['bpty'][buf]
# index every map char by its expected bytes
idx={}
for cy in range(64):
    for cx in range(128):
        e=expect(cx,cy)
        if e: idx.setdefault(bytes(e),[]).append((cx,cy))
n=0
for r in range(22):
    cy=wcy+r
    for c in range(80):
        cx=wcx+c; e=expect(cx,cy)
        if e is None: continue
        rc=((cy%23)*80+cx)%1840
        got=ram[base+rc*8:base+rc*8+8]
        if got!=e:
            n+=1
            if n<=8:
                cand=idx.get(bytes(got),[])[:4]
                print(f'win({r},{c}) map({cx},{cy}) slot {rc}: got {got.hex()} want {bytes(e).hex()} matches {cand}')
print('total',n)
