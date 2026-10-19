#!/usr/bin/env python3
"""What does an input do?  Runs MAME twice with tools/lua/probe.lua -- the base presses, then the base plus the probed ones -- and
compares the pictures.

    probe.py <set> <name> --base "<presses>" --probe "<presses>" --frames <list> [--sheet first,last,step]

  presses   probe.lua's PRESS list: "from-to:port:mask,...", port 0 = P1_P2 (0x280000), 2 = COIN (0x280002), mask = bits pulled low
  frames    probe.lua's DUMPFRAMES: "f,f,..." and / or "a-b/s"
Prints the differing pixels per dumped frame; writes work/probe/<set>/<name>/{base,probe}/f<N>.png, and with --sheet a side-by-side
sheet (base left, probe right) of those frames to work/probe/<set>/<name>/sheet.png.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import pngio


def frames_of(spec):
    out = []
    for item in spec.split(','):
        if '-' in item:
            ab, s = item.split('/')
            a, b = ab.split('-')
            out += list(range(int(a), int(b) + 1, int(s)))
        else:
            out.append(int(item))
    return out


def run(s, out, press, frames):
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        os.remove(os.path.join(out, f))
    env = dict(os.environ, DUMPDIR=out, DUMPFRAMES=frames, PRESS=press, READLOG='1')
    last = max(frames_of(frames))
    cmd = [paths.MAME, s, '-rompath', paths.ROMS, '-cfg_directory', os.path.join(paths.WORK, 'cfg'),
           '-nvram_directory', os.path.join(paths.WORK, 'nvram'), '-video', 'none', '-sound', 'none', '-nothrottle',
           '-skip_gameinfo', '-autoboot_script', os.path.join(paths.LUA, 'probe.lua'), '-seconds_to_run', str(last // 60 + 30)]
    subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    pics = {}
    for f in frames_of(frames):
        p = os.path.join(out, 'f%05d.rgb' % f)
        if os.path.exists(p):
            pics[f] = open(p, 'rb').read()
            pngio.write(p[:-4] + '.png', 320, 240, pics[f])
    return pics


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    opt = lambda k, d=None: argv[argv.index(k) + 1] if k in argv else d
    if len(args) < 2 or not opt('--frames'):
        print(__doc__)
        return 2
    s, name = args[0], args[1]
    base, extra, frames = opt('--base', ''), opt('--probe', ''), opt('--frames')
    top = os.path.join(paths.WORK, 'probe', s, name)
    p0 = run(s, os.path.join(top, 'base'), base, frames)
    p1 = run(s, os.path.join(top, 'probe'), ','.join(x for x in (base, extra) if x), frames)
    diff = []
    for f in sorted(p0):
        if f in p1:
            a, b = p0[f], p1[f]
            diff.append('%d:%d' % (f, sum(1 for i in range(0, len(a), 3) if a[i:i + 3] != b[i:i + 3])))
    print('%s %s: differing pixels per frame: %s' % (s, name, ' '.join(diff)))
    if opt('--sheet'):
        sel = [f for f in frames_of(opt('--sheet')) if f in p0 and f in p1]
        W = 640
        img = bytearray(W * 240 * len(sel) * 3)
        for k, f in enumerate(sel):
            for y in range(240):
                j = ((k * 240 + y) * W) * 3
                img[j:j + 960] = p0[f][y * 960:(y + 1) * 960]
                img[j + 960:j + 1920] = p1[f][y * 960:(y + 1) * 960]
        pngio.write(os.path.join(top, 'sheet.png'), W, 240 * len(sel), img)
        print('sheet (base | probe) of frames %s: %s' % (sel, os.path.join(top, 'sheet.png')))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
