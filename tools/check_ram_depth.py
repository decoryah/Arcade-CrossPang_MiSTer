#!/usr/bin/env python3
"""Check the RAMs Quartus actually built against the depths the RTL declares (from the owner's ohmygod-mister/mister/tools/check_ram_depth.py).

    check_ram_depth.py <Crospang.fit.rpt> [--list]

A simulator evaluates an array exactly as declared; Quartus 17 does not always (a two-dimensional unpacked array was once built half as deep,
invisible in every bench and broken on the board).  Run this on every fit report; it exits 1 if a listed memory is shallower than its
minimum, or is missing.
"""
import re
import sys

# (instance name fragment, minimum words, minimum width)
EXPECT = [
    # the line buffer: {bank, x[8:0]} = 1024 words of 10 bits
    ("cp_video:u_video|cp_sdp:u_lb|altsyncram", 1024, 10),
    # the 68000 board's RAMs (cp_ram16: two byte-wide halves each) and the renderer's copies of the video RAMs
    ("cp_main:u_main|cp_ram16:u_ram|altsyncram", 32768, 8),
    ("cp_main:u_main|cp_ram16:u_fg|altsyncram", 1024, 8),
    ("cp_main:u_main|cp_ram16:u_bg|altsyncram", 1024, 8),
    ("cp_main:u_main|cp_ram16:u_pal|altsyncram", 1024, 8),
    ("cp_main:u_main|cp_ram16:u_s0|altsyncram", 256, 8),
    ("cp_main:u_main|cp_ram16:u_s1|altsyncram", 256, 8),
    ("cp_main:u_main|cp_ram16:u_s2|altsyncram", 256, 8),
    ("cp_main:u_main|cp_ram16:u_s3|altsyncram", 256, 8),
    ("cp_main:u_main|cp_sdp:u_fg_d|altsyncram", 1024, 16),
    ("cp_main:u_main|cp_sdp:u_bg_d|altsyncram", 1024, 16),
    ("cp_main:u_main|cp_sdp:u_sp_d|altsyncram", 256, 16),
    # the program cache
    ("cp_cache:u_cache|cp_sdp:u_dat|altsyncram", 8192, 16),
    ("cp_cache:u_cache|cp_sdp:u_tag|altsyncram", 1024, 7),
    # the sound board: the Z80 program (64 KB) and RAM (2 KB)
    ("cp_sound:u_sound|cp_sdp:u_rom|altsyncram", 65536, 8),
    ("cp_sound:u_sound|cp_ram8:u_ram|altsyncram", 2048, 8),
]


def main():
    path = sys.argv[1]
    ram = []
    for line in open(path, errors="replace"):
        if "|ALTSYNCRAM" not in line or not line.startswith(";"):
            continue
        f = [c.strip() for c in line.split(";")]
        # ; name ; type ; mode ; clocks ; words ; width ; words ; width ; ...
        try:
            ram.append((f[1], int(f[5]), int(f[6])))
        except (IndexError, ValueError):
            continue
    if "--list" in sys.argv:
        for n, w, b in ram:
            print("%6d x %-3d %s" % (w, b, n))
    bad = 0
    for frag, wmin, bmin in EXPECT:
        hits = [(n, w, b) for n, w, b in ram if frag in n]
        if not hits:
            print("MISSING  %-52s (expected >= %d x %d)" % (frag, wmin, bmin))
            bad += 1
            continue
        for n, w, b in hits:
            # a wide RAM may be split into several blocks side by side; only depth matters here
            ok = w >= wmin
            if not ok:
                bad += 1
            print("%s  %-52s %6d x %-3d (>= %d)" % ("ok     " if ok else "TOO SHALLOW", frag, w, b, wmin))
    print("%d problem(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
