# Render the original Cleo (v500, 176x184) view of a level state, from the original
# assets, the way b.d()/a.a() paint it: $111111 fill, TiledLayer, sprites by ref pixel,
# the bar composed from bar.png as b.c() does.  State comes from the port's harness.
import json, struct, sys
import numpy as np
from PIL import Image
SRC='/Users/ebenupton/cleo/v500/'
st=json.load(open(sys.argv[1])); out=sys.argv[2]
def load(name):
    im=Image.open(SRC+name); pal=np.array(im.getpalette(),np.uint8).reshape(-1,3); return np.array(im), pal, im.info.get('transparency')
til,tpal,_=load('til.png'); spr,spal,str_=load('spr.png'); bar,bpal,_=load('bar.png')
dim=[struct.unpack('BBBBbb',open(SRC+'dim','rb').read()[i*6:i*6+6]) for i in range(103)]
d=open(SRC+str(st['level']),'rb').read(); p=[2115,2119,2108,2129,2104,2128,2118,2134][st['level']]
lw,lh=d[p],d[p+1]; W,H=1<<lw,1<<lh; m=np.array(struct.unpack('>%dh'%(W*H),d[p+2:p+2+2*W*H]),np.int32).reshape(H,W)
VW,VH,BARH=176,168,16
cx,cy=st['px'],st['py']
wx=min(max(cx-88,0),W*8-160); wy=min(max(cy-84,0),H*8-152)
img=np.zeros((BARH+VH,VW,3),np.uint8); img[:]=(0x11,0x11,0x11)
# tiles
for ty in range(VH//8+2):
    for tx in range(VW//8+2):
        mx,my=wx//8+tx, wy//8+ty
        if not (0<=mx<W and 0<=my<H): continue
        t=int(m[my,mx])
        if t<0: continue
        x0,y0=mx*8-wx, my*8-wy+BARH
        cell=tpal[til[t*8:t*8+8]]
        xs,ys=max(0,x0),max(BARH,y0); xe,ye=min(VW,x0+8),min(BARH+VH,y0+8)
        if xe>xs and ye>ys: img[ys:ye,xs:xe]=cell[ys-y0:ye-y0, xs-x0:xe-x0]
# sprites: box stars (103..114, aliases +15) are the port's pre-composited star frames
def blit(idx_img,pal,tr,x0,y0,y1=BARH):
    h,w=idx_img.shape
    for yy in range(h):
        sy=y0+yy
        if sy<y1 or sy>=BARH+VH: continue
        for xx in range(w):
            sx=x0+xx
            if 0<=sx<VW and idx_img[yy,xx]!=tr: img[sy,sx]=pal[idx_img[yy,xx]]
def orig_id(i):
    if i>=118: i-=15
    if 103<=i<=114: return 34+(i-103)%6
    if 115<=i<=117: return 43+(i-115)
    return i
for s in reversed(st['sprites']):          # the original pops its list from the end
    i=orig_id(s['id']); x,y,w,h,rx,ry=dim[i]
    blit(spr[y:y+h,x:x+w], spal, str_, s['x']-rx-wx, s['y']-ry-wy+BARH)
# the bar, as b.c() composes it into a 176x16 image, then the counters
barimg=np.zeros((16,176,3),np.uint8)
def bclip(cx0,cy0,cw,ch,ix,iy):            # setClip(cx0,cy0,cw,ch); drawImage(bar, ix, iy)
    for yy in range(cy0,cy0+ch):
        for xx in range(cx0,cx0+cw):
            bx,by=xx-ix,yy-iy
            if 0<=bx<bar.shape[1] and 0<=by<16 and 0<=xx<176: barimg[yy,xx]=bpal[bar[by,bx]]
bclip(0,0,8,16,0,0)
for i in range(1,21): bclip(i*8,0,8,16,i*8-8,0)
bclip(168,0,8,16,152,0)
bclip(3,0,13,16,-21,0); bclip(31,0,13,16,-6,0); bclip(59,0,13,16,9,0)
def digit(n,x,y): bclip(x,y,8,8, x-63-(n%5)*8, y-(n//5)*8)
digit(0,156,4); digit(0,164,4)
digit(st['lives'],17,4); digit(st['health'],45,4)
digit(st['stars']//10,73,4); digit(st['stars']%10,81,4)
sc=st['score']
for i in range(5): digit(sc%10,(22-i)*8-28,4); sc//=10
img[:16]=barimg
Image.fromarray(img).save(out)
Image.fromarray(img).resize((VW*4,(BARH+VH)*4),Image.NEAREST).save(out.replace('.png','_x4.png'))
print('camera',wx,wy,'cleo',cx,cy,'sprites',[(orig_id(s['id']),s['x'],s['y']) for s in st['sprites']])
