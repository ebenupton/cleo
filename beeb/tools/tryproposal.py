#!/usr/bin/env python3
"""Apply one proposal from the catalogue, build, and leave the tree ready to verify.

    python3 tools/tryproposal.py <rank|id>        apply it
    python3 tools/tryproposal.py --revert         put the source back

The proposal's `original` text must appear exactly once inside the window's own line
range -- not merely somewhere in the file, which is how a plausible-looking patch lands
in the wrong routine.  The line range is the check that makes this safe to automate.

After applying, the caller is expected to run, at minimum:
    ./build.sh
    node tools/statediff.mjs <ref> <reflabels> build/cleo.ssd build/labels.txt <lv> 300
    node tools/pixdiff.mjs   <ref> <reflabels> build/cleo.ssd build/labels.txt <lv> 300
An agent's cycle arithmetic is a claim; only those two make it a fact.
"""
import json, sys, os, shutil, re

SRC = 'src'
BACKUP = 'build/proposal_backup'

def apply_one(p, src_dir=SRC, backup=True):
    """Splice one proposal into its file.  Returns None on success, else a reason string.

    The match is anchored to the window's own line range: an agent's `original` often
    appears elsewhere in the file (a two-instruction idiom repeats everywhere), and a
    patch that lands in the wrong routine assembles cleanly and fails much later."""
    path = os.path.join(src_dir, p['file'])
    src = open(path).read().split('\n')
    lo, hi = p['lo'], p['hi']
    orig = p['original'].strip('\n')
    new = p['proposal'].strip('\n')
    def code(l):
        """the instruction on a line, comments and whitespace normalised away."""
        t = re.sub(r'(^|\s);.*$', '', l).rstrip()
        return ' '.join(t.split())
    # Agents routinely paste a `; expands to:` gloss into the quoted original, and drop or
    # reword the source's own trailing comments.  Comments are not the program, so match on
    # instructions alone; the splice still replaces whole source lines.
    lines_o = [l for l in orig.split('\n') if code(l)]
    lines_n = [l for l in new.split('\n') if l.strip()]
    # The window is 16 *instructions*; an agent quoting a coherent loop routinely runs
    # past its last line, and one quoting from a routine's head starts a little before.
    # So anchor on where the match STARTS -- inside the window -- and let it run on.
    SLACK = 60
    base = max(lo - 9, 1)
    ri = [i for i, l in enumerate(src[base - 1:min(hi + SLACK, len(src))]) if code(l)]
    nstart = sum(1 for i in ri if base + i - 1 < hi)      # starts that begin in-window
    key = code
    starts = [i for i in range(min(nstart, len(ri) - len(lines_o) + 1))
              if [key(src[base - 1 + ri[i + k]]) for k in range(len(lines_o))]
                 == [key(l) for l in lines_o]]
    if not starts: return 'original not found in window'
    if len(starts) > 1: return f'original matches {len(starts)} times in window'
    s0 = ri[starts[0]]; s1 = ri[starts[0] + len(lines_o) - 1]
    lo = base                                              # s0/s1 are relative to base now
    if backup:
        os.makedirs(BACKUP, exist_ok=True)
        b = os.path.join(BACKUP, p['file'])
        if not os.path.exists(b): shutil.copy(path, b)
    indent = re.match(r'\s*', src[lo - 1 + s0]).group(0) or '        '
    out = []
    for l in lines_n:
        t = l.strip()
        # a line that begins with a label (named, @cheap or anonymous ':') keeps column 0;
        # everything else takes the file's body indent
        out.append(l if re.match(r'^[:@A-Za-z_.]', l) else indent + t)
    src[lo - 1 + s0: lo + s1] = out
    open(path, 'w').write('\n'.join(src))
    p['_span'] = (lo + s0, lo + s1)     # 1-based inclusive range replaced in the OLD file
    return None


def revert():
    if not os.path.isdir(BACKUP): sys.exit('nothing to revert')
    for f in os.listdir(BACKUP): shutil.copy(os.path.join(BACKUP, f), os.path.join(SRC, f))
    shutil.rmtree(BACKUP); print('source restored')

if __name__ == '__main__':
    if len(sys.argv) < 2: sys.exit(__doc__)
    if sys.argv[1] == '--revert': revert(); sys.exit()

    props = json.load(open('opt/proposals.json'))
    sel = sys.argv[1]
    p = props[int(sel)] if sel.isdigit() else next((x for x in props if x['id'] == sel), None)
    if p is None: sys.exit(f'no proposal {sel}')

    err = apply_one(p)
    if err: sys.exit(f'{p["id"]}: {err}')
    print(f"applied {p['id']}  {p['file']}:{p['lo']}-{p['hi']} ({p['routine']})")
    print(f"  claim: -{p.get('saving_cycles',0)} cy x {p['execs_per_frame']}/frame = {p['weighted']} cy/frame")
    print(f"  assumption: {p.get('assumption') or '(none stated)'}")
    print(f"  confidence: {p.get('confidence','?')}")
