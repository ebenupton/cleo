import sys
import numpy as np
from PIL import Image
a=np.array(Image.open(sys.argv[1]).convert('RGB')).astype(int); lit=(a.sum(axis=2)>0)
prev=None
for y in range(120, 512, 2):
    row=lit[y]; x=20
    while x<660 and not row[x]: x+=1
    if x>=660: d='blank'
    else:
        lead=(x-20)//8; c=tuple(a[y,x]); name={(0,255,255):'C',(255,0,255):'M',(255,255,0):'Y'}.get(c,'?')
        x2=659
        while x2>20 and not row[x2]: x2-=1
        d=f'lead {lead:2d} ({name}) right {(x2-20)//8}'
    if d!=prev: print(f'  sl {y//2:3d}: {d}')
    prev=d
