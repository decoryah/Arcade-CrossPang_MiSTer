#!/usr/bin/env python3
"""Compares the bench's pictures (sim/tb_main.cpp, 320 x 240 PPM) with MAME's (tools/lua/dump_state.lua: <state>.rgb).

    cmp_frame.py <picture.ppm> <state prefix | file.rgb> [diff.png]

Prints the number of differing pixels and their bounding box; diff.png shows MAME's picture with the differing pixels in magenta.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

W, H = 320, 240


def read_ppm(path):
    d = open(path, 'rb').read()
    # P6\n<w> <h>\n255\n
    parts = d.split(b'\n', 3)
    assert parts[0] == b'P6', path
    w, h = (int(x) for x in parts[1].split())
    assert (w, h) == (W, H), (path, w, h)
    return parts[3][:W * H * 3]


def compare(ppm, ref_path, png=None):
    a = read_ppm(ppm)
    ref = open(ref_path if ref_path.endswith('.rgb') else ref_path + '.rgb', 'rb').read()
    diff = [i // 3 for i in range(0, W * H * 3, 3) if a[i:i + 3] != ref[i:i + 3]]
    if diff:
        xs = [p % W for p in diff]
        ys = [p // W for p in diff]
        print('%s: %d of %d pixels differ, x %d..%d, y %d..%d' % (os.path.basename(ppm), len(diff), W * H, min(xs), max(xs), min(ys), max(ys)))
    else:
        print('%s: 0 of %d pixels differ' % (os.path.basename(ppm), W * H))
    if png:
        import pngio
        d = bytearray(ref)
        for p in diff:
            d[p * 3:p * 3 + 3] = b'\xff\x00\xff'
        pngio.write(png, W, H, d)
    return len(diff)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    return 1 if compare(argv[1], argv[2], argv[3] if len(argv) > 3 else None) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
