#!/usr/bin/env python3
"""The core's ROM image (what the MRA delivers to the loader, rtl/cp_mem.sv), and checks of the loader's graphics remap.

    crospang_image.py build <set> <out.rom>     the image
    crospang_image.py check [set ...]           decode tiles / sprites through the remap + the renderer's pixel pick and compare with
                                                MAME's gfx decode (tools/crospang_ref.py's Gfx), every tile, every row, every pixel

Image layout (byte offsets; cp_mem.sv has the same table).  The loader packs the stream little-endian (first byte = low half of the
SDRAM word); every region keeps MAME's byte order except the 68000 program, whose big-endian words are byte-swapped:
  000000  68000 program, MAME's "maincpu" region (1 MB), each word's two bytes swapped (low byte first)
  100000  "tiles": its first half at 100000, its second half at 200000 (each padded to 1 MB)
  300000  "sprites": the same, first half at 300000, second at 400000
  500000  "oki" (256 KB)
  540000  "audiocpu", the first 64 KB
  550000  configuration bytes: scroll map, work RAM base, 68000 at 14.318 MHz, tiles 16384, sprites 16384, button 3, 0, 0
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crospang_rom

IMG_SIZE = 0x550008
O_MAIN, O_TILE, O_SPR, O_OKI, O_Z80, O_CFG = 0x000000, 0x100000, 0x300000, 0x500000, 0x540000, 0x550000

# set: (scroll map, RAM base, fast 68000, button 3)   -- cp_main.sv: map 0 crospang/heuksun/pitapat, 1 pitapata, 2 bestri,
#                                                        3 bestria; RAM 0 = 320000, 1 = 300000, 2 = 3A0000, 3 = 340000;
#                                                        button 3 (Crospang.sv): MAME's INPUT_PORTS pitapat has IPT_BUTTON3;
#                                                        crospang uses it too (MAME 0.289: IPT_UNKNOWN), see make_mra.BUTTONS
CFG = {
    'crospang': (0, 0, 0, 1),
    'heuksun':  (0, 0, 0, 0),
    'bestri':   (2, 2, 0, 0),
    'bestria':  (3, 3, 0, 0),
    'pitapat':  (0, 1, 1, 1),
    'pitapata': (1, 1, 1, 1),
}


def build(setname):
    r = crospang_rom.build(setname)
    img = bytearray(IMG_SIZE)
    # the loader packs the stream little-endian (first byte = low half of the SDRAM word): the 68000's big-endian words go in swapped
    m = r['maincpu']
    img[O_MAIN:O_MAIN + len(m):2] = m[1::2]
    img[O_MAIN + 1:O_MAIN + len(m):2] = m[0::2]
    for base, reg in ((O_TILE, r['tiles']), (O_SPR, r['sprites'])):
        h = len(reg) // 2
        assert h <= 0x100000
        img[base:base + h] = reg[:h]
        img[base + 0x100000:base + 0x100000 + h] = reg[h:]
    img[O_OKI:O_OKI + 0x40000] = r['oki']
    img[O_Z80:O_Z80 + 0x10000] = r['audiocpu'][:0x10000]
    smap, ram, fast, b3 = CFG[setname]
    tbig = 1 if len(r['tiles']) == 0x200000 else 0
    sbig = 1 if len(r['sprites']) == 0x200000 else 0
    img[O_CFG:O_CFG + 8] = bytes([smap, ram, fast, tbig, sbig, b3, 0, 0])
    return bytes(img)


# ---- the loader's remap (cp_mem.sv remap()) on word addresses, and the SDRAM contents it makes
SD_TILE, SD_SPR, SD_PCM = 0x080000, 0x180000, 0x280000


def remap(wa):
    if SD_TILE <= wa < SD_SPR:
        r = wa - SD_TILE
        return SD_TILE + (((r >> 5) & 0x3fff) << 6 | (r & 15) << 2 | ((r >> 4) & 1) << 1 | (r >> 19) & 1)
    if SD_SPR <= wa < SD_PCM:
        r = wa - SD_SPR
        return SD_SPR + (((r >> 5) & 0x3fff) << 6 | (r & 15) << 2 | (((r >> 4) & 1) ^ 1) << 1 | (r >> 19) & 1)
    return wa


def sdram_words(img):
    """{word address: word} as the loader stores the image (only the region the SDRAM holds)."""
    out = {}
    for wa in range(0, 0x2A0000):
        out[remap(wa)] = img[2 * wa] | (img[2 * wa + 1] << 8)
    return out


def pick(w, x, is_spr):
    """cp_render.sv pick(): pen of pixel x (0..15) from the row's four words."""
    p = w[2] if x & 8 else w[0]
    q = w[3] if x & 8 else w[1]
    b = 7 - (x & 7)
    bit = lambda v, n: (v >> n) & 1
    if is_spr:
        return bit(q, 8 + b) << 3 | bit(q, b) << 2 | bit(p, 8 + b) << 1 | bit(p, b)
    return bit(p, 8 + b) << 3 | bit(p, b) << 2 | bit(q, 8 + b) << 1 | bit(q, b)


def check(setname, sample_every=1):
    import crospang_ref
    img = build(setname)
    gt, gs = crospang_ref.build_gfx(setname)
    # SDRAM words of the two graphics regions only (the rest is plain)
    mem = {}
    for wa in range(SD_TILE, SD_PCM):
        mem[remap(wa)] = img[2 * wa] | (img[2 * wa + 1] << 8)
    bad = 0
    for gfx, base, is_spr, name in ((gt, SD_TILE, False, 'tiles'), (gs, SD_SPR, True, 'sprites')):
        n = gfx.n
        for code in range(0, n, sample_every):
            t = gfx.tile(code)
            for y in range(16):
                a = base + (code << 6) + (y << 2)
                w = [mem[a], mem[a + 1], mem[a + 2], mem[a + 3]]
                for x in range(16):
                    if pick(w, x, is_spr) != t[y][x]:
                        bad += 1
                        if bad < 5:
                            print('%s %s tile %d row %d x %d: remap %d, MAME %d' % (setname, name, code, y, x, pick(w, x, is_spr), t[y][x]))
            gfx.cache.pop(code, None)
        print('%-9s %-7s %5d tiles checked%s' % (setname, name, (n + sample_every - 1) // sample_every, '' if not bad else ', DIFFERENCES'))
    return bad


def main(argv):
    if len(argv) == 4 and argv[1] == 'build':
        open(argv[3], 'wb').write(build(argv[2]))
        print('%s: %d bytes' % (argv[3], IMG_SIZE))
        return 0
    if len(argv) >= 2 and argv[1] == 'check':
        sets = [a for a in argv[2:] if not a.startswith('--')] or sorted(crospang_rom.SETS)
        every = 7 if '--sample' in argv else 1
        return 1 if sum(check(s, every) for s in sets) else 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
