import sys
import numpy as np
from PIL import Image
a=np.array(Image.open(sys.argv[1]).convert('RGB')).astype(int)
NAME={(0,0,0):'.',(0,255,255):'C',(255,0,255):'M',(255,255,0):'Y'}
for y in range(int(sys.argv[2]), int(sys.argv[3]), 8):
    chars=[NAME.get(tuple(a[y,20+c*8+3]),'?') for c in range(80)]
    runs=[]; cur=chars[0]; n=1
    for ch in chars[1:]:
        if ch==cur: n+=1
        else: runs.append(f'{cur}x{n}'); cur=ch; n=1
    runs.append(f'{cur}x{n}')
    print(f'  sl {y//2:3d}: ' + ' '.join(runs))
