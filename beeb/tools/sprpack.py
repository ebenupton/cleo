"""Where the sprites' images and masks go in a bank: the order and the padding that
cost the sprite loops least.

The cost is the pointers' page crossings.  A row of a sprite walks its column pointer
across the image a column (`lines` bytes) at a time, and every page it crosses takes
the carry path (sprpinc: 9 cycles more than falling through; the mirrored walk's
borrow about the same); the mask pointer does the same across the mask plane, a
group of four columns at a time.  The walk of row r starts at base + 8r - lb0, lb0's
low three bits the sprite's line phase, which is anything: the cost of a placement is
the carries a draw expects over the eight phases, at the base's offset in its page.
The reads that cross a page as well (a (zp),Y read whose index runs into the next
page: 3.5 a draw for each page boundary inside an image) are the rest of it.

A bank's run of sprites is items -- each image and each mask on its own -- in an
order, with padding before any of them; the search swaps and moves items and moves
padding, keeping what lowers the draws-weighted cost, within the run's room.  It is
deterministic (seeded by its inputs) and cached (build/sprpack.cache): the same
items in the same room come back the same without the search.
"""
import hashlib, json, os, random

CARRY = 9.0             # cycles: the carry path over falling through
BORROW = 7.0            # the mirrored walk's borrow path (sprretM's dec ptr+1)
READ = 3.5              # cycles a draw: the (zp),Y reads past a page boundary in an image
VERSION = 2
_tables = {}


def _walk(o, cols, step, rstep, rows_of, phases):
    """Carries a draw expects, over the phases: each row's walk from o + rstep*r - phase."""
    tot = 0
    for ph in range(phases):
        for r in range(rows_of(ph)):
            p = o + rstep * r - ph
            tot += (p + cols * step) // 256 - p // 256
    return tot / phases


def image_table(W, L, mirrored=False):
    """cost a draw (cycles) of an image W columns by L lines at each page offset: the
    walk from the first column up, or (mirrored) from the last column down -- the same
    span one column lower, and the borrow path's cost"""
    k = ('img', W, L, mirrored)
    if k not in _tables:
        n = W * L
        rows = lambda ph: (L + ph + 7) // 8
        if mirrored:
            walk = [_walk(o - L, W, L, 8, rows, 8) for o in range(256)]
            _tables[k] = [BORROW * walk[o] + READ * ((o + n - 1) // 256 - o // 256) for o in range(256)]
        else:
            _tables[k] = [CARRY * _walk(o, W, L, 8, rows, 8) + READ * ((o + n - 1) // 256 - o // 256)
                          for o in range(256)]
    return _tables[k]


def mask_table(W, L):
    """the same for its mask: groups of four columns, L/2 bytes each, 4 bytes a row"""
    k = ('mask', W, L)
    if k not in _tables:
        g, mh = (W + 3) // 4, L // 2
        rows = lambda ph: (L + 2 * ph + 7) // 8
        _tables[k] = [CARRY * _walk(o, g, mh, 4, rows, 4) for o in range(256)]
    return _tables[k]


def cost(items, lo, order, pads):
    a, c = lo, 0.0
    for i, idx in enumerate(order):
        a += pads[i]
        it = items[idx]
        if it['table'] is not None:
            c += it['w'] * it['table'][a & 255]
        a += it['size']
    return c


def optimise(items, lo, hi, cache=None, iters=None, pad_penalty=1e-3):
    """items: dicts key, size, w (draws a frame), table (256 costs, or None: free).
    Returns ({key: address}, cost before, cost after), in cycles a frame."""
    n = len(items)
    room = hi - lo - sum(it['size'] for it in items)
    assert room >= 0, ('does not fit', hi - lo, room)
    base_order, base_pads = list(range(n)), [0] * n
    before = cost(items, lo, base_order, base_pads)
    sig = json.dumps([VERSION, lo, hi, [(repr(it['key']), it['size'], round(it['w'], 4),
                                         hashlib.sha1(json.dumps(it['table']).encode()).hexdigest()[:8] if it['table'] else None)
                                        for it in items]])
    h = hashlib.sha1(sig.encode()).hexdigest()
    got = cache.get(h) if cache is not None else None
    if got:
        order, pads = got
    else:
        rnd = random.Random(h)
        order, pads = base_order[:], base_pads[:]
        best = cost(items, lo, order, pads) + pad_penalty * sum(pads)
        steps = iters or (3000 + 600 * n)
        for _ in range(steps):
            o2, p2 = order[:], pads[:]
            mv = rnd.random()
            if mv < 0.3 and n > 1:                          # swap two
                i, j = rnd.randrange(n), rnd.randrange(n)
                o2[i], o2[j] = o2[j], o2[i]
            elif mv < 0.55 and n > 1:                       # move one
                i, j = rnd.randrange(n), rnd.randrange(n)
                o2.insert(j, o2.pop(i))
            elif mv < 0.85:                                  # padding before one, more or less
                i = rnd.randrange(n)
                d = rnd.choice((-8, -4, -2, -1, 1, 2, 4, 8, 16, 32))
                v = p2[i] + d
                if v < 0 or sum(p2) - p2[i] + v > room:
                    continue
                p2[i] = v
            else:                                            # padding from one to another
                i, j = rnd.randrange(n), rnd.randrange(n)
                d = rnd.randint(1, 32)
                if p2[i] < d:
                    continue
                p2[i] -= d; p2[j] += d
            c = cost(items, lo, o2, p2) + pad_penalty * sum(p2)
            if c <= best:
                best, order, pads = c, o2, p2
        if cache is not None:
            cache[h] = (order, pads)
    addr, a = {}, lo
    for i, idx in enumerate(order):
        a += pads[i]
        addr[items[idx]['key']] = a
        a += items[idx]['size']
    assert a <= hi
    return addr, before, cost(items, lo, order, pads), a


def load_cache(path):
    try:
        with open(path) as f:
            return {k: tuple(v) for k, v in json.load(f).items()}
    except (OSError, ValueError):
        return {}


def save_cache(cache, path):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(cache, f)
    os.replace(tmp, path)
