#!/usr/bin/env python3
"""Does the game react to its service switch while it runs?  (tools/lua/service.lua in MAME, two runs per set)

    service.py <set> [--on N] [--off N] [--frames f,f,...]

  run 1: no service switch.  run 2: the set's service switch on from frame --on (default 600, the attract mode) to --off (default:
  stays on).  Prints which frames read the DSW port (0x280004) and how many pixels of each dumped frame differ between the runs;
  writes both runs' pictures as PNGs to work/service/<set>/.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import pngio

SVC = {'crospang': 0x4000, 'heuksun': 0x0080, 'bestri': 0x0001, 'bestria': 0x0001, 'pitapat': 0x0080, 'pitapata': 0x0080}


def run(s, out, frames, on=None, off=None):
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        os.remove(os.path.join(out, f))
    env = dict(os.environ, DUMPDIR=out, DUMPFRAMES=','.join(str(f) for f in frames), SVC_MASK='%x' % SVC[s])
    if on is not None:
        env['SVC_ON'] = str(on)
    if off is not None:
        env['SVC_OFF'] = str(off)
    cmd = [paths.MAME, s, '-rompath', paths.ROMS, '-cfg_directory', os.path.join(paths.WORK, 'cfg'),
           '-nvram_directory', os.path.join(paths.WORK, 'nvram'), '-video', 'none', '-sound', 'none', '-nothrottle',
           '-skip_gameinfo', '-autoboot_script', os.path.join(paths.LUA, 'service.lua'),
           '-seconds_to_run', str(max(frames) // 60 + 30)]
    subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    reads = [tuple(int(x, 16) if i == 2 else int(x) for i, x in enumerate(l.split()))
             for l in open(os.path.join(out, 'reads.log'))]
    pics = {}
    for f in frames:
        p = os.path.join(out, 'f%05d.rgb' % f)
        if os.path.exists(p):
            pics[f] = open(p, 'rb').read()
            pngio.write(p[:-4] + '.png', 320, 240, pics[f])
    return reads, pics


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if not args or args[0] not in SVC:
        print(__doc__)
        return 2
    s = args[0]
    opt = lambda k, d: argv[argv.index(k) + 1] if k in argv else d
    on, off = int(opt('--on', 600)), opt('--off', None)
    off = int(off) if off else None
    frames = [int(x) for x in opt('--frames', '590,620,660,720,900,1200').split(',')]
    base = os.path.join(paths.WORK, 'service', s)
    r0, p0 = run(s, os.path.join(base, 'off'), frames)
    r1, p1 = run(s, os.path.join(base, 'on'), frames, on, off)
    def span(reads):
        if not reads:
            return 'never'
        fr = [r[0] for r in reads]
        return '%d frames from %d to %d (%s)' % (len(fr), fr[0], fr[-1], ', '.join('%d:%dx%04x' % r for r in reads[:6]) +
                                                   (' ...' if len(reads) > 6 else ''))
    print('%s, service mask %04x, on from frame %d%s' % (s, SVC[s], on, (' to %d' % off) if off else ''))
    print('  DSW reads, switch off: %s' % span(r0))
    print('  DSW reads, switch on:  %s' % span(r1))
    for f in frames:
        if f in p0 and f in p1:
            a, b = p0[f], p1[f]
            n = sum(1 for i in range(0, len(a), 3) if a[i:i + 3] != b[i:i + 3])
            print('  frame %5d: %6d of 76800 pixels differ' % (f, n))
    print('  pictures: %s' % base)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
