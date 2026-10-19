#!/usr/bin/env python3
"""Compares the bench's audio with MAME's and fits the mix.

    cmp_audio.py <rtl.wav> <mame.wav> [--from S] [--to S]

  rtl.wav    sim/tb_main.cpp +wav: 48 kHz stereo, left = the YM3812 (jtopl2) output, right = the OKI's sum x 16; or a mono file from
             sim/tb_opl.cpp (the YM3812 alone)
  mame.wav   MAME -wavwrite -samplerate 48000 (the driver's one mono speaker: YM3812 route 1.0 + OKI route 1.0)

Finds the lag between the two (RMS envelopes, then sample cross-correlation), then the least-squares gains a, b of
mame = a * fm + b * oki over the aligned samples, and prints the residual.  a = b = 1 means the core's mix (Crospang.sv:
fm + oki, clipped) is MAME's.
"""
import array
import math
import sys
import wave


def load(path):
    with wave.open(path, 'rb') as w:
        assert w.getsampwidth() == 2, '16-bit WAV expected'
        rate, ch = w.getframerate(), w.getnchannels()
        a = array.array('h')
        a.frombytes(w.readframes(w.getnframes()))
    if ch == 1:
        return rate, [a]
    return rate, [a[i::ch] for i in range(ch)]


def envelope(x, win):
    out = []
    for i in range(0, len(x) - win + 1, win):
        s = 0
        for k in range(i, i + win):
            s += x[k] * x[k]
        out.append(math.sqrt(s / win))
    return out


def corr(a, b):
    n = min(len(a), len(b))
    if n < 2:
        return 0.0
    ma, mb = sum(a[:n]) / n, sum(b[:n]) / n
    sab = sum((a[i] - ma) * (b[i] - mb) for i in range(n))
    saa = sum((a[i] - ma) ** 2 for i in range(n))
    sbb = sum((b[i] - mb) ** 2 for i in range(n))
    return sab / math.sqrt(saa * sbb) if saa > 0 and sbb > 0 else 0.0


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    r1, chans = load(argv[1])
    fm = chans[0]
    oki = chans[1] if len(chans) > 1 else array.array('h', bytes(2 * len(fm)))     # a mono file: the YM3812 bench (sim/tb_opl.cpp)
    r2, (m,) = load(argv[2])
    assert r1 == r2 == 48000, (r1, r2)
    t0 = float(argv[argv.index('--from') + 1]) if '--from' in argv else 0.5
    t1 = float(argv[argv.index('--to') + 1]) if '--to' in argv else 1e9
    mix = [fm[i] + oki[i] for i in range(len(fm))]
    # coarse lag: 10 ms envelopes, +-0.5 s
    W = 480
    em, ex = envelope(m, W), envelope(mix, W)
    best = max(range(-50, 51), key=lambda L: corr(em[max(0, L):], ex[max(0, -L):]))
    # fine lag: samples around it (mame[i + lag] ~ rtl[i])
    base = best * W
    lo = int(t0 * 48000)
    hi = min(int(t1 * 48000), len(mix) - 2000, len(m) - base - 2000)
    seg = range(lo, min(hi, lo + 96000))
    def c(L):
        return corr([m[i + L] for i in seg], [mix[i] for i in seg])
    lag = max(range(base - W, base + W + 1, 4), key=c)
    lag = max(range(lag - 4, lag + 5), key=c)
    print('lag: MAME is %+d samples (%+.2f ms) from the core; envelope correlation %.3f, sample correlation %.3f'
          % (lag, lag / 48.0, corr(em[max(0, best):], ex[max(0, -best):]), c(lag)))
    idx = [i for i in range(lo, hi) if 0 <= i + lag < len(m)]
    # least squares: m = a fm + b oki
    sff = sum(fm[i] * fm[i] for i in idx)
    soo = sum(oki[i] * oki[i] for i in idx)
    sfo = sum(fm[i] * oki[i] for i in idx)
    smf = sum(m[i + lag] * fm[i] for i in idx)
    smo = sum(m[i + lag] * oki[i] for i in idx)
    det = sff * soo - sfo * sfo
    if sff == 0 and soo == 0:
        print('both chips are silent in this window')
        return 1
    elif sff == 0:
        a, b = 0.0, smo / soo
        print('the YM3812 is silent in this window: fitting the OKI alone')
    elif soo == 0 or det < 1e-9 * sff * soo:
        a, b = smf / sff, 0.0
        print('the OKI is silent in this window: fitting the YM3812 alone')
    else:
        a = (smf * soo - smo * sfo) / det
        b = (smo * sff - smf * sfo) / det
    res = sum((m[i + lag] - a * fm[i] - b * oki[i]) ** 2 for i in idx)
    tot = sum(m[i + lag] ** 2 for i in idx)
    rms_f = math.sqrt(sff / len(idx)); rms_o = math.sqrt(soo / len(idx)); rms_m = math.sqrt(tot / len(idx))
    print('levels (RMS): MAME %.0f, core FM %.0f, core OKI %.0f' % (rms_m, rms_f, rms_o))
    print('fit: mame = %.3f * fm + %.3f * oki   (%.1f dB, %.1f dB); residual %.1f%% of the energy'
          % (a, b, 20 * math.log10(abs(a)) if a else -99, 20 * math.log10(abs(b)) if b else -99, 100.0 * res / tot if tot else 0))
    # the same, per 0.25 s, to see whether the gain is constant (a level error) or not (a different sound)
    step = 12000
    for s0 in range(lo, hi - step + 1, step):
        seg = [i for i in range(s0, s0 + step) if 0 <= i + lag < len(m)]
        e_m = sum(m[i + lag] ** 2 for i in seg)
        e_c = sum((a * fm[i] + b * oki[i]) ** 2 for i in seg)
        r = sum((m[i + lag] - a * fm[i] - b * oki[i]) ** 2 for i in seg)
        if e_m:
            print('  %5.2f s: MAME rms %6.0f, fitted core rms %6.0f, residual %5.1f%%' % (s0 / 48000.0, math.sqrt(e_m / len(seg)),
                  math.sqrt(e_c / len(seg)), 100.0 * r / e_m))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
