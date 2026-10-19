#!/usr/bin/env python3
"""Reference renderer for crospang.cpp (MAME 0.289): the driver's screen_update written out literally, compared with MAME's pixels.

    crospang_ref.py <set> <state prefix> [out.png]    renders <prefix>.{fg,bg,pal,spr,regs}, compares with <prefix>.rgb
    crospang_ref.py <set> <dir>                       every f*.regs state in the folder

The driver (MAME's src/mame/f32/crospang.cpp):
  - BG and FG: 32 x 32 tilemaps of 16 x 16 (TILEMAP_SCAN_ROWS), video RAM at 0x122000 (BG) and 0x120000 (FG), 0x400 words each.
    word = [15:12] colour, [11:10] bank select, [9:0] code; tile = code + (tilebank[sel] << 10); pen base (colour + 0x20) * 16 for BG,
    (colour + 0x10) * 16 for FG; FG pen 0 is transparent; whole-layer scroll: screen (x, y) shows map ((x + scrollx), (y + scrolly)) mod 512.
  - sprites after both layers: decospr, standard list format, is_bootleg(true), offsets (5, 7), 256 entries of 4 words at 0x210000,
    palette index colour * 16 + pen, pen 0 transparent (decospr.cpp, draw_sprites_common, 320-wide branch, flip screen off).
    A flashing entry (w0 bit 12) is hidden when frame_number() is odd: see flash_hidden().
  - gfx decode: tiles `tlayout_alt`, sprites `tlayout` (16 x 16, 4 planes, half-region planes), code taken modulo the number of tiles.
  - palette: 0x300 words xRGB_555.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import crospang_rom

W, H = 320, 240


def hexwords(path):
    return [int(l, 16) for l in open(path) if l.strip()]


def load_state(prefix):
    s = {}
    for k in ('fg', 'bg', 'pal', 'spr'):
        s[k] = hexwords('%s.%s' % (prefix, k))
    # MAME converts the frame's pen indexes with the palette of the NEXT callback (see tools/lua/dump_state.lua)
    s['pal1'] = hexwords(prefix + '.pal1') if os.path.exists(prefix + '.pal1') else s['pal']
    v = open(prefix + '.regs').read().split()
    s['frame'] = int(v[0])
    s['regs'] = [int(x, 16) for x in v[1:9]]            # 0x100000, 0x100002, ... 0x10000e as last written
    s['bank'] = [int(x) for x in v[9:13]]
    s['banksel'] = int(v[13])
    return s


# ---- gfx decode (gfx_layout, MAME's gfxdecode) -------------------------------------------------------------------------------
class Gfx:
    def __init__(self, region, planes, xoffs, yoffs, charinc_bits):
        self.r = region
        self.planes, self.xoffs, self.yoffs, self.inc = planes, xoffs, yoffs, charinc_bits
        self.n = len(region) * 8 // charinc_bits // 2        # total = RGN_FRAC(1,2): half of the region's chars
        self.cache = {}

    def tile(self, code):
        """16 x 16 list of pens (rows of 16) for `code` (taken modulo the number of tiles)."""
        code %= self.n
        t = self.cache.get(code)
        if t is None:
            r = self.r
            base = code * self.inc
            t = []
            for y in range(16):
                row = []
                for x in range(16):
                    v = 0
                    for p in self.planes:
                        b = base + p + self.xoffs[x] + self.yoffs[y]
                        v = (v << 1) | ((r[b >> 3] >> (7 - (b & 7))) & 1)
                    row.append(v)
                t.append(row)
            self.cache[code] = t
        return t


def build_gfx(setname):
    regs = crospang_rom.build(setname)
    tr, sr = regs['tiles'], regs['sprites']
    frac_t, frac_s = len(tr) * 8 // 2, len(sr) * 8 // 2
    step8 = list(range(8))
    ylist = [16 * i for i in range(16)]
    tiles = Gfx(tr, [8, 0, frac_t + 8, frac_t + 0], step8 + [256 + i for i in range(8)], ylist, 64 * 8)
    sprites = Gfx(sr, [frac_s + 8, frac_s + 0, 8, 0], [256 + i for i in range(8)] + step8, ylist, 64 * 8)
    return tiles, sprites


# ---- the per-game scroll registers (the *_map functions of the driver) --------------------------------------------------------
def _bestri(xorv, plus, sign):
    return lambda d: sign * ((d & 0x3ff) ^ xorv) + plus


SCROLL = {
    # set: {register address: (layer, axis, function(data) -> tilemap scroll value)}
    'crospang': {0x100002: ('fg', 'y', lambda d: d + 8), 0x100004: ('bg', 'x', lambda d: d + 4),
                 0x100006: ('bg', 'y', lambda d: d + 8), 0x100008: ('fg', 'x', lambda d: d)},
    'pitapata': {0x100002: ('fg', 'x', lambda d: d), 0x100004: ('fg', 'y', lambda d: d + 8),
                 0x100006: ('bg', 'x', lambda d: d + 4), 0x100008: ('bg', 'y', lambda d: d + 8)},
    'bestri': {0x100004: ('fg', 'x', _bestri(0x1e1, -1, 1)), 0x100006: ('fg', 'y', _bestri(0xab, 7, -1)),
               0x10000a: ('bg', 'y', _bestri(0x155, 7, -1)), 0x10000c: ('bg', 'x', _bestri(0x3c1, 3, 1))},
    'bestria': {0x100006: ('fg', 'x', _bestri(0x1e1, -1, 1)), 0x100008: ('fg', 'y', _bestri(0xab, 7, -1)),
                0x10000a: ('bg', 'x', _bestri(0x3c1, 3, 1)), 0x10000c: ('bg', 'y', _bestri(0x155, 7, -1))},
}
SCROLL['heuksun'] = SCROLL['crospang']
SCROLL['pitapat'] = SCROLL['crospang']


def scrolls(setname, regs):
    """-> {'fg': [x, y], 'bg': [x, y]} as the driver's write handlers would have set them (0 until written)."""
    out = {'fg': [0, 0], 'bg': [0, 0]}
    for addr, (layer, axis, fn) in SCROLL[setname].items():
        out[layer][0 if axis == 'x' else 1] = fn(regs[(addr - 0x100000) >> 1])
    return out


def pal_rgb(w):
    r, g, b = (w >> 10) & 31, (w >> 5) & 31, w & 31          # xRGB_555
    return bytes(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)))


# ---- the frame -----------------------------------------------------------------------------------------------------------------
def tile_word(w, bank):
    return (w & 0x3ff) + (bank[(w >> 10) & 3] << 10), (w >> 12) & 15


def draw_layer(idx, vram, gfx, bank, scroll, colbase, transparent):
    sx, sy = scroll
    for y in range(H):
        my = (y + sy) & 0x1ff
        ty, fy = my >> 4, my & 15
        row = idx[y]
        for x in range(W):
            mx = (x + sx) & 0x1ff
            code, col = tile_word(vram[ty * 32 + (mx >> 4)], bank)
            pen = gfx.tile(code)[fy][mx & 15]
            if transparent and pen == 0:
                continue
            row[x] = (col + colbase) * 16 + pen


def draw_tile(idx, gfx, code, colour, fx, fy, sx, sy):
    """drawgfx transpen 0, clipped to the 320 x 240 screen; indexes are colour * 16 + pen."""
    t = gfx.tile(code)
    for r in range(16):
        y = sy + r
        if y < 0 or y >= H:
            continue
        src = t[15 - r if fy else r]
        row = idx[y]
        for c in range(16):
            x = sx + c
            if x < 0 or x >= W:
                continue
            pen = src[15 - c if fx else c]
            if pen:
                row[x] = colour * 16 + pen


def draw_sprites(idx, spr, gfx, x_offset=5, y_offset=7, frame_odd=False):
    """decospr_device::draw_sprites_common, standard format, is_bootleg, no priority callback, flip screen off, 320 wide."""
    for offs in range(0, 0x400, 4):
        sprite, y = spr[offs + 1], spr[offs]
        flash = (y >> 12) & 1
        w = (y >> 11) & 1
        if flash and frame_odd:
            continue
        x = spr[offs + 2]
        colour = (x >> 9) & 0x1f                             # default_col_cb
        fx, fy = (y >> 13) & 1, (y >> 14) & 1
        tempwidth = (((y >> 10) & 1) << 1) | ((y >> 9) & 1)  # bitswap<2>(y, 10, 9)
        multi = (1 << tempwidth) - 1
        x = ((x & 0x1ff) + x_offset) & 0x1ff
        y = ((y & 0x1ff) + y_offset) & 0x1ff
        if x >= 320:
            x -= 512
        if y >= 256:
            y -= 512
        y = 240 - y
        x = 304 - x
        # is_bootleg: the tile number is not masked with ~multi
        if fy:
            inc = -1
        else:
            sprite += multi
            inc = 1
        mult = -16
        mult2 = multi + 1
        while multi >= 0:
            ypos = y + mult * multi
            if ypos <= H - 1 and ypos >= 0 - 16:
                draw_tile(idx, gfx, (sprite - multi * inc) & 0xffff, colour, fx, fy, x, ypos)
                if w:
                    draw_tile(idx, gfx, ((sprite - multi * inc) - mult2) & 0xffff, colour, fx, fy, x - 16, ypos)
            multi -= 1


def render(setname, st, gfx_tiles, gfx_sprites, pal_key='pal1', frame_odd=False):
    pal = [pal_rgb(w) for w in st[pal_key]]
    idx = [[0] * W for _ in range(H)]
    sc = scrolls(setname, st['regs'])
    draw_layer(idx, st['bg'], gfx_tiles, st['bank'], sc['bg'], 0x20, False)
    draw_layer(idx, st['fg'], gfx_tiles, st['bank'], sc['fg'], 0x10, True)
    draw_sprites(idx, st['spr'], gfx_sprites, frame_odd=frame_odd)
    out = bytearray(W * H * 3)
    for y in range(H):
        for x in range(W):
            out[(y * W + x) * 3:(y * W + x) * 3 + 3] = pal[idx[y][x]]
    return out, idx


def flash_hidden(frame):
    """decospr hides a flashing entry when screen().frame_number() is odd.  Measured over 20 consecutive frames of Cross Pang
    (5 flashing entries, all 20 pixel-identical): the picture of dumped frame N (tools/lua/dump_state.lua numbering) is drawn with an
    odd frame_number when N is EVEN."""
    return frame % 2 == 0


def compare(prefix, setname, gfx, png=None, verbose=True):
    st = load_state(prefix)
    out, idx = render(setname, st, gfx[0], gfx[1], frame_odd=flash_hidden(st['frame']))
    ref = open(prefix + '.rgb', 'rb').read()
    diff = [i // 3 for i in range(0, len(ref), 3) if ref[i:i + 3] != bytes(out[i:i + 3])]
    if verbose:
        print('%s: %d of %d pixels differ' % (os.path.basename(prefix), len(diff), W * H))
    if png:
        import pngio
        pngio.write(png, W, H, out)
        if diff:
            d = bytearray(ref)
            for p in diff:
                d[p * 3:p * 3 + 3] = b'\xff\x00\xff'
            pngio.write(png.replace('.png', '.diff.png'), W, H, d)
    return diff


def main(argv):
    if len(argv) < 3 or argv[1] not in crospang_rom.SETS:
        print(__doc__)
        return 2
    setname, target = argv[1], argv[2]
    gfx = build_gfx(setname)
    if os.path.isdir(target):
        total = 0
        for f in sorted(os.listdir(target)):
            if f.endswith('.regs'):
                total += len(compare(os.path.join(target, f[:-5]), setname, gfx))
        return 1 if total else 0
    return 1 if compare(target, setname, gfx, argv[3] if len(argv) > 3 else None) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
