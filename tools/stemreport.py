#!/usr/bin/env python3
"""Per-stem, per-section levels: stemreport.py STEMDIR [BPM]
Rows = stems, columns = sections; value = RMS dBFS of that stem in that section (blank if silent).
Also prints each stem's spectral centroid / low-energy share and peak."""
import os, sys
import numpy as np
from analyze import read_wav, db
from report import SECTIONS


def main():
    d = sys.argv[1]
    bpm = float(sys.argv[2]) if len(sys.argv) > 2 else 150
    names = sorted(f[:-4] for f in os.listdir(d) if f.endswith(".wav"))
    names = [n for n in names if n != "MASTER"] + (["MASTER"] if "MASTER" in names else [])
    secs = SECTIONS
    print("%-8s" % "", " ".join("%7s" % s[0] for s in secs[:-1]), "|  peak   cen  low%  corr")
    for n in names:
        y, sr = read_wav(os.path.join(d, n + ".wav"))
        spb = 60 / bpm * sr
        row = []
        for (nm, b0), (_, b1) in zip(secs, secs[1:]):
            c = y[int(b0 * spb):int(b1 * spb)].mean(1)
            r = db(np.sqrt((c ** 2).mean())) if len(c) else -200
            row.append("%7.1f" % r if r > -70 else "%7s" % ".")
        m = y.mean(1)
        sp = np.abs(np.fft.rfft(m)) ** 2
        f = np.fft.rfftfreq(len(m), 1 / sr)
        cen = (sp * f).sum() / (sp.sum() + 1e-20)
        low = sp[f < 150].sum() / (sp.sum() + 1e-20)
        L, R = y[:, 0], y[:, 1]
        act = np.abs(m) > 1e-4
        corr = np.corrcoef(L[act], R[act])[0, 1] if act.sum() > 100 and L[act].std() > 0 else 1
        print("%-8s" % n, " ".join(row), "| %5.1f %5.0f %4.0f  %5.2f" % (db(np.abs(y).max()), cen, low * 100, corr))


if __name__ == "__main__":
    main()
