#!/usr/bin/env python3
"""Whole-machine check: each picture of a bench run (sim/tb_main.cpp, <prefix>.fNNNNN.ppm, named by MAME frame) against MAME's pictures of
the same and the neighbouring frames (any number of state folders made by tools/capture.py with the same inputs).

    sys_match.py <bench prefix> <MAME state dir> [<MAME state dir> ...] [--window K]

For every bench picture that has MAME pictures within +-K frames (default 2), prints the differing pixels against each; a picture that
matches its own frame exactly is the goal, a match one frame off means the bench's numbering (+foff) or the input replay (+ioff) is off.
"""
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmp_frame

W, H = 320, 240


def ndiff(a, b):
    return sum(1 for i in range(0, W * H * 3, 3) if a[i:i + 3] != b[i:i + 3])


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if len(args) < 2:
        print(__doc__)
        return 2
    k = int(argv[argv.index('--window') + 1]) if '--window' in argv else 2
    if '--window' in argv:
        args.remove(str(k))
    prefix, dirs = args[0], args[1:]
    mame = {}
    for d in dirs:
        for p in glob.glob(os.path.join(d, 'f*.rgb')):
            mame[int(os.path.basename(p)[1:6])] = p
    exact = total = 0
    for ppm in sorted(glob.glob(prefix + '.f*.ppm')):
        n = int(ppm[-9:-4])
        near = [m for m in range(n - k, n + k + 1) if m in mame]
        if not near:
            continue
        a = cmp_frame.read_ppm(ppm)
        res = [(m, ndiff(a, open(mame[m], 'rb').read())) for m in near]
        best = min(res, key=lambda r: r[1])
        total += 1
        own = dict(res).get(n)
        if own == 0:
            exact += 1
        print('%s: %s   best %+d (%d px)' % (os.path.basename(ppm), '  '.join('%d:%d' % r for r in res), best[0] - n, best[1]))
    print('%d of %d pictures identical to MAME\'s picture of the same frame' % (exact, total))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
