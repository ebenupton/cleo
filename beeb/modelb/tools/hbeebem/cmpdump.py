# Compare the per-frame dumps of the headless BeebEm (hb) and jsbeeb (jb): the first frame
# whose logic state differs, then whether the display RAM hashes differ, then the CRTC.
import sys
def parse(path):
    out = []
    for l in open(path):
        if not l.startswith('f='): continue
        d = {}
        for tok in l.split():
            k, _, v = tok.partition('='); d[k] = v
        out.append(d)
    return out
hb, jb = parse(sys.argv[1]), parse(sys.argv[2])
n = min(len(hb), len(jb)); print('frames: beebem %d, jsbeeb %d' % (len(hb), len(jb)))
logic_keys = [k for k in hb[0] if k not in ('f', 'disp', 'crtc')]
first_logic = first_disp = first_crtc = None
for i in range(n):
    a, b = hb[i], jb[i]
    if first_logic is None:
        diff = [k for k in logic_keys if a.get(k) != b.get(k)]
        if diff: first_logic = (i, diff)
    if first_disp is None and a['disp'] != b['disp']: first_disp = i
    if first_crtc is None and a['crtc'] != b['crtc']: first_crtc = (i, a['crtc'], b['crtc'])
print('logic state: ' + ('identical over %d frames' % n if first_logic is None else 'first difference at frame %d in %s' % (first_logic[0], ' '.join(first_logic[1][:8]))))
print('display RAM: ' + ('identical hashes over %d frames' % n if first_disp is None else 'first hash difference at frame %d' % first_disp))
print('CRTC regs:   ' + ('identical over %d frames' % n if first_crtc is None else 'first difference at frame %d: beebem %s jsbeeb %s' % first_crtc))
if first_logic:
    i, diff = first_logic
    for k in diff[:4]: print('  frame %d %s: beebem=%s jsbeeb=%s' % (i, k, hb[i][k][:60], jb[i][k][:60]))
