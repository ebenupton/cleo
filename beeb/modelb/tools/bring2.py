# Compare both rings in build/ram.bin against a render of the map (the Master's tile
# ids: 254/255 are the solid fills), inside each buffer's last-drawn window, and the
# mirror against the ring's last slot row.
import json, sys
st=json.load(open('build/state.json'))
ram=open('build/ram.bin','rb').read(); tiles=open('build/tiles.bin','rb').read(); mp=open('build/map.bin','rb').read(); halves=open('build/halves.bin','rb').read()
inc=json.load(open('build/level.json'))          # bcheck2.mjs dumps the level's shape with its tiles and map
MAPW=int(inc['MAPW']); MAPH=int(inc['MAPH'])
RINGROWS, RINGCHARS = 23, 23*80
print(st)
assert inc['flat'][28:32] == [0x0F, 0x0F, 0, 0], ('FLATTAB in bank 5 is not the packer\'s: the solids are wrong', inc['flat'][28:32])
only = st['curbuf'] if len(sys.argv)>1 and sys.argv[1]=='cur' else None
for buf,base in ((0,0x0a80),(1,0x4680)):
    if only is not None and buf!=only: continue
    if not st['valid'][buf]: print(f'buffer {buf}: never drawn'); continue
    wcx, wcy = st['bufcx'][buf], st['bufcy'][buf]
    bad=[]
    kept=[k for k in st.get('kept',[]) if k['keep'] and buf==st['curbuf']]
    def inkept(cx,cy):
        return any(k['cx']<=cx<k['cx']+k['w'] and k['cy']<=cy<k['cy']+k['h'] for k in kept)
    for r in range(22):                      # the 21 visible rows and the composed one
        cy=wcy+r
        for c in range(80):
            cx=wcx+c; tx,ty=cx>>2,cy>>1
            if inkept(cx,cy): continue
            if ty>=MAPH or tx>=MAPW: continue
            t=mp[ty*MAPW+tx]
            if t>=240:                          # a flat tile (the solids among them): two
                p=inc['flat'][(t-240)*2:(t-240)*2+2]; exp=bytes(p*4)   # bytes alternating
            elif t>=inc['half0']:               # a half tile: one row stored, the other a
                k=t-inc['half0']; row=cy&1      # fill or the same row
                fill=(row==0 and k<inc['half1']-inc['half0']) or (row==1 and inc['half1']-inc['half0']<=k<inc['half2']-inc['half0'])
                if fill: p=inc['hpair'][k*2:k*2+2]; exp=bytes(p*4)
                else: o=k*32+(cx&3)*8; exp=halves[o:o+8]
            else:
                o=t*64+(cy&1)*32+(cx&3)*8; exp=tiles[o:o+8]
            rc=((cy%RINGROWS)*80+cx)%RINGCHARS
            if ram[base+rc*8: base+rc*8+8]!=exp: bad.append((r,c))
    print(f'buffer {buf}: window ({wcx},{wcy}) {len(bad)} chars differ; {bad[:12]}')
    mb=base-640; last=base+(RINGROWS-1)*640
    w0 = st['wcxm'] if buf==st['curbuf'] else 0
    mbad=[c for c in range(w0,80) if ram[mb+c*8:mb+c*8+8]!=ram[last+c*8:last+c*8+8]]
    if kept: print(f'  ({len(kept)} kept sprites excluded)')
    print(f'buffer {buf}: mirror differs in {len(mbad)} chars from {w0}; {mbad[:8]}')
