#!/usr/bin/env python3
"""Builds the ROM regions of the crospang.cpp sets from the MAME zips, exactly as ROM_START in src/mame/f32/crospang.cpp
(MAME 0.289) loads them, and checks them against MAME's own regions (tools/lua/dump_regions.lua).

    crospang_rom.py check [set ...]      compare with work/regions/<set>/<region>.bin (all six sets by default)
    crospang_rom.py build <set> <dir>    write <region>.bin for the set

Merged sets: bestria and pitapata live in the parent's zip; the files only they have are in a <set>/ folder there.
Load modes: 'b' = ROM_LOAD16_BYTE (every second byte), 'n' = ROM_LOAD (plain).  A tuple (name, mode, offset, size[, continues])
with continues = [offset, ...]: ROM_CONTINUE chunks of `size` bytes taken from the same file in turn.
"""
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths

# set -> (zip, [(region, size, [entries])])
_T_HEUKSUN = [('uc08.r11', 'b', 0x00001, 0x20000, [0x100001, 0x040001, 0x140001]),
              ('uc07.t11', 'b', 0x00000, 0x20000, [0x100000, 0x040000, 0x140000])]
_T_BESTRI = lambda a, b, c, d: [(a, 'b', 0x00001, 0x20000, [0x100001, 0x040001, 0x140001]),
                                (b, 'b', 0x00000, 0x20000, [0x100000, 0x040000, 0x140000]),
                                (c, 'b', 0x80001, 0x20000, [0x180001, 0x0c0001, 0x1c0001]),
                                (d, 'b', 0x80000, 0x20000, [0x180000, 0x0c0000, 0x1c0000])]
_T_PITAPAT = [('uc08', 'b', 0x00001, 0x20000, [0x100001, 0x040001, 0x140001]),
              ('uc07', 'b', 0x00000, 0x20000, [0x100000, 0x040000, 0x140000])]
_T_PITAPATA = [('uc08', 'b', 0x00001, 0x20000, [0x100001, 0x040001, 0x140001]),
               ('uc07', 'b', 0x00000, 0x20000, [0x100000, 0x040000, 0x140000])]

SETS = {
    'crospang': ('crospang', [
        ('maincpu', 0x100000, [('p1.bin', 'b', 0x00001, 0x20000), ('p2.bin', 'b', 0x00000, 0x20000)]),
        ('audiocpu', 0x10000, [('s1.bin', 'n', 0, 0x10000)]),
        ('oki', 0x40000, [('s2.bin', 'n', 0, 0x20000)]),
        ('tiles', 0x80000, [('rom1.bin', 'b', 0x00000, 0x40000), ('rom2.bin', 'b', 0x00001, 0x40000)]),
        ('sprites', 0x200000, [('rom3.bin', 'b', 0x000000, 0x80000), ('rom4.bin', 'b', 0x000001, 0x80000),
                               ('rom5.bin', 'b', 0x100000, 0x80000), ('rom6.bin', 'b', 0x100001, 0x80000)]),
    ]),
    'heuksun': ('heuksun', [
        ('maincpu', 0x100000, [('ua02.j3', 'b', 0x00001, 0x80000), ('ua03.j5', 'b', 0x00000, 0x80000)]),
        ('audiocpu', 0x40000, [('us02.r4', 'n', 0, 0x10000)]),
        ('oki', 0x40000, [('us08.u7', 'n', 0, 0x40000)]),
        ('tiles', 0x200000, _T_HEUKSUN),
        ('sprites', 0x100000, [('ud14.p11', 'b', 0x00000, 0x40000), ('ud15.m11', 'b', 0x00001, 0x40000),
                               ('ud16.l11', 'b', 0x80000, 0x40000), ('ud17.j11', 'b', 0x80001, 0x40000)]),
    ]),
    'bestri': ('bestri', [
        ('maincpu', 0x100000, [('ua02.i3', 'b', 0x00001, 0x80000), ('ua03.i5', 'b', 0x00000, 0x80000)]),
        ('audiocpu', 0x40000, [('us02.p3', 'n', 0, 0x10000)]),
        ('oki', 0x40000, [('us08.q7', 'n', 0, 0x40000)]),
        ('tiles', 0x200000, _T_BESTRI('uc08.m12', 'uc07 p12', 'uc29.k12', 'uc28.n12')),
        ('sprites', 0x200000, [('ud14.j12', 'b', 0x000000, 0x80000), ('ud15.h12', 'b', 0x000001, 0x80000),
                               ('ud16.g12', 'b', 0x100000, 0x80000), ('ud17.e12', 'b', 0x100001, 0x80000)]),
    ]),
    'bestria': ('bestri', [
        ('maincpu', 0x100000, [('o_ua02.i3', 'b', 0x00001, 0x80000), ('e_ua03.i5', 'b', 0x00000, 0x80000)]),
        ('audiocpu', 0x40000, [('us02.p3', 'n', 0, 0x10000)]),
        ('oki', 0x40000, [('us08.q7', 'n', 0, 0x40000)]),
        ('tiles', 0x200000, _T_BESTRI('2_uc08.m12', '0_uc07.p12', '3_uc29.k12', '1_uc28.n12')),
        ('sprites', 0x200000, [('a_ud14.j12', 'b', 0x000000, 0x80000), ('b_ud15.h12', 'b', 0x000001, 0x80000),
                               ('c_ud16.g12', 'b', 0x100000, 0x80000), ('d_ud17.e12', 'b', 0x100001, 0x80000)]),
    ]),
    'pitapat': ('pitapat', [
        ('maincpu', 0x100000, [('ua02', 'b', 0x00001, 0x40000), ('ua03', 'b', 0x00000, 0x40000)]),
        ('audiocpu', 0x10000, [('us02', 'n', 0, 0x10000)]),
        ('oki', 0x40000, [('us08', 'n', 0, 0x40000)]),
        ('tiles', 0x200000, _T_PITAPAT),
        ('sprites', 0x100000, [('ud14', 'b', 0x000000, 0x40000), ('ud15', 'b', 0x000001, 0x40000),
                               ('ud16', 'b', 0x080000, 0x40000), ('ud17', 'b', 0x080001, 0x40000)]),
    ]),
    'pitapata': ('pitapat', [
        ('maincpu', 0x100000, [('ua02', 'b', 0x00001, 0x40000), ('ua03', 'b', 0x00000, 0x40000)]),
        ('audiocpu', 0x10000, [('us02', 'n', 0, 0x10000)]),
        ('oki', 0x40000, [('us08', 'n', 0, 0x40000)]),
        ('tiles', 0x200000, _T_PITAPATA),
        ('sprites', 0x100000, [('ud14', 'b', 0x000000, 0x40000), ('ud15', 'b', 0x000001, 0x40000),
                               ('ud16', 'b', 0x080000, 0x40000), ('ud17', 'b', 0x080001, 0x40000)]),
    ]),
}

# the files a clone has of its own, in <clone>/ inside the parent's zip (merged set); everything else is the parent's
CLONE_DIR = {'bestria': 'bestria', 'pitapata': 'pitapata'}
CLONE_OWN = {
    'bestria': {'o_ua02.i3', 'e_ua03.i5', '2_uc08.m12', '0_uc07.p12', '3_uc29.k12', '1_uc28.n12',
                'a_ud14.j12', 'b_ud15.h12', 'c_ud16.g12', 'd_ud17.e12'},
    'pitapata': {'ua02', 'ua03', 'uc08', 'uc07', 'us08'},
}


def open_zip(zname):
    return zipfile.ZipFile(os.path.join(paths.ROMS, zname + '.zip'))


def get_file(z, setname, name):
    """The bytes of a ROM file of `setname` inside its (merged) zip."""
    names = set(z.namelist())
    if setname in CLONE_OWN and name in CLONE_OWN[setname]:
        return z.read(CLONE_DIR[setname] + '/' + name)
    if name in names:
        return z.read(name)
    raise KeyError('%s: %s not in the zip' % (setname, name))


def place(region, mode, offset, data):
    if mode == 'n':
        region[offset:offset + len(data)] = data
    else:                                              # ROM_LOAD16_BYTE: every second byte
        region[offset:offset + 2 * len(data):2] = data


def build(setname):
    zname, regions = SETS[setname]
    z = open_zip(zname)
    out = {}
    for rname, size, entries in regions:
        reg = bytearray(size)
        for e in entries:
            fname, mode, offset, n = e[:4]
            conts = e[4] if len(e) > 4 else []
            data = get_file(z, setname, fname)
            total = n * (1 + len(conts))
            if len(data) != total:
                raise ValueError('%s/%s: file is %d bytes, ROM_START wants %d' % (setname, fname, len(data), total))
            place(reg, mode, offset, data[:n])
            for k, off in enumerate(conts):
                place(reg, mode, off, data[n * (k + 1):n * (k + 2)])
        out[rname] = bytes(reg)
    return out


def check(names):
    bad = 0
    for s in names:
        mine = build(s)
        for rname, img in sorted(mine.items()):
            p = os.path.join(paths.WORK, 'regions', s, rname + '.bin')
            if not os.path.exists(p):
                print('%-9s %-9s no MAME dump (%s)' % (s, rname, p))
                bad += 1
                continue
            ref = open(p, 'rb').read()
            if ref == img:
                print('%-9s %-9s identical (%d bytes)' % (s, rname, len(img)))
            else:
                first = next((i for i in range(min(len(ref), len(img))) if ref[i] != img[i]), None)
                print('%-9s %-9s DIFFERENT: size %d vs MAME %d, first difference at %s' % (s, rname, len(img), len(ref), first))
                bad += 1
    return bad


def main(argv):
    if len(argv) >= 2 and argv[1] == 'check':
        return 1 if check(argv[2:] or sorted(SETS)) else 0
    if len(argv) == 4 and argv[1] == 'build' and argv[2] in SETS:
        os.makedirs(argv[3], exist_ok=True)
        for rname, img in build(argv[2]).items():
            open(os.path.join(argv[3], rname + '.bin'), 'wb').write(img)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
