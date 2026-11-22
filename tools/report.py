#!/usr/bin/env python3
"""Section report for a full render: report.py FILE.wav [BPM]
Approximate integrated loudness (K-weighted, BS.1770-style gating), per-section loudness,
peak, crest, low/mid/high balance, stereo correlation, and 1-bar loudness jumps."""
import sys
import numpy as np
from analyze import read_wav, db

SECTIONS = [("Drone", 0), ("Drone2", 64), ("Stir", 128), ("Stir2", 192), ("Pulse", 256), ("Pulse2", 320),
            ("Break", 384), ("Chop", 448), ("Peak", 512), ("Down", 576), ("Final", 608), ("Dissv", 640),
            ("Out", 688), ("END", 752)]


def kweight(x, sr):
    X = np.fft.rfft(x, axis=0)
    f = np.fft.rfftfreq(len(x), 1 / sr)
    hp = 1 / np.sqrt(1 + (38 / np.maximum(f, 1e-3)) ** 4)
    shelf = 10 ** ((4 / 20) * (1 / (1 + (1500 / np.maximum(f, 1e-3)) ** 2)))
    return np.fft.irfft(X * (hp * shelf)[:, None], n=len(x), axis=0)


def loudness(y, sr):
    k = kweight(y, sr)
    blk, hop = int(0.4 * sr), int(0.1 * sr)
    ms = np.array([(k[i:i + blk] ** 2).mean(0).sum() for i in range(0, len(k) - blk, hop)])
    if not len(ms):
        return -99
    l = -0.691 + 10 * np.log10(ms + 1e-20)
    g = ms[l > -70]
    if not len(g):
        return -99
    rel = -0.691 + 10 * np.log10(g.mean()) - 10
    g2 = g[(-0.691 + 10 * np.log10(g + 1e-20)) > rel]
    return -0.691 + 10 * np.log10(g2.mean() + 1e-20)


def band(x, sr, lo, hi, tot):
    sp = np.abs(np.fft.rfft(x)) ** 2
    f = np.fft.rfftfreq(len(x), 1 / sr)
    return 10 * np.log10(sp[(f >= lo) & (f < hi)].sum() / tot + 1e-20)


def main():
    y, sr = read_wav(sys.argv[1])
    bpm = float(sys.argv[2]) if len(sys.argv) > 2 else 150
    spb = 60 / bpm * sr
    print("integrated ~%.1f LUFS  peak %.1f dBFS  length %.1fs" % (loudness(y, sr), db(np.abs(y).max()), len(y) / sr))
    print("%-7s %6s %6s %6s %6s | %5s %5s %5s %5s %5s | %5s" % ("sect", "LUFS", "peak", "crest", "rms",
                                                                "<60", "60-250", "250-2k", "2k-8k", ">8k", "corr"))
    for (name, b0), (_, b1) in zip(SECTIONS, SECTIONS[1:]):
        a, b = int(b0 * spb), min(len(y), int(b1 * spb))
        if a >= len(y):
            break
        c = y[a:b]
        m = c.mean(1)
        sp = np.abs(np.fft.rfft(m)) ** 2
        tot = sp.sum() + 1e-20
        L, R = c[:, 0], c[:, 1]
        corr = np.corrcoef(L, R)[0, 1] if L.std() > 0 and R.std() > 0 else 1
        rms = db(np.sqrt((m ** 2).mean()))
        print("%-7s %6.1f %6.1f %6.1f %6.1f | %5.0f %5.0f %5.0f %5.0f %5.0f | %5.2f" % (
            name, loudness(c, sr), db(np.abs(c).max()), db(np.abs(c).max()) - rms, rms,
            band(m, sr, 20, 60, tot), band(m, sr, 60, 250, tot), band(m, sr, 250, 2000, tot),
            band(m, sr, 2000, 8000, tot), band(m, sr, 8000, 20000, tot), corr))
    # bar-level loudness curve (for spotting holes / jumps)
    bars = []
    for i in range(0, len(y) - int(4 * spb), int(4 * spb)):
        c = y[i:i + int(4 * spb)].mean(1)
        bars.append(db(np.sqrt((c ** 2).mean())))
    print("bar rms (dBFS), 8 bars per row:")
    for i in range(0, len(bars), 8):
        print("  bar %3d: %s" % (i + 1, " ".join("%5.1f" % v for v in bars[i:i + 8])))


if __name__ == "__main__":
    main()
