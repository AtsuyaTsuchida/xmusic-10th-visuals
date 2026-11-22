#!/usr/bin/env python3
"""Measure a recorded WAV (analysis only — nothing is synthesised or written back).

usage: analyze.py FILE.wav [segment_seconds]
Prints peak / RMS / crest, stereo width, spectral balance per band and a per-segment level
table so problems (silence, clipping, DC, harshness, mud) can be spotted without listening.
"""
import sys
import struct
import numpy as np


def read_wav(path):
    """Minimal RIFF reader: PCM 16/24/32 and float32/64 (WAVE_FORMAT_EXTENSIBLE too)."""
    d = open(path, "rb").read()
    i, fmt, data = 12, None, None
    while i + 8 <= len(d):
        cid, n = d[i:i + 4], struct.unpack("<I", d[i + 4:i + 8])[0]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", d[i + 8:i + 24])
            if fmt[0] == 0xFFFE:
                fmt = (struct.unpack("<H", d[i + 32:i + 34])[0],) + fmt[1:]
        elif cid == b"data":
            data = d[i + 8:i + 8 + n]
        i += 8 + n + (n & 1)
    tag, ch, sr, _, _, bits = fmt
    if tag == 3:
        a = np.frombuffer(data, "<f4" if bits == 32 else "<f8").astype(np.float64)
    elif bits == 24:
        b = np.frombuffer(data[:len(data) // 3 * 3], np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        a = np.where(v >= 1 << 23, v - (1 << 24), v) / float(1 << 23)
    else:
        a = np.frombuffer(data, "<i%d" % (bits // 8)).astype(np.float64) / float(1 << (bits - 1))
    return a.reshape(-1, ch), sr


def bands(x, sr):
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    f = np.fft.rfftfreq(len(x), 1 / sr)
    edges = [20, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 12000, 20000]
    tot = spec[(f >= 20) & (f < 20000)].sum() + 1e-20
    return [(lo, hi, 10 * np.log10(spec[(f >= lo) & (f < hi)].sum() / tot + 1e-20))
            for lo, hi in zip(edges[:-1], edges[1:])]


def db(v):
    return 20 * np.log10(max(v, 1e-12))


def main():
    y, sr = read_wav(sys.argv[1])
    seg = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
    L, R = y[:, 0], y[:, -1]
    m = (L + R) / 2
    s = (L - R) / 2
    print("file %s  %.1fs  sr %d" % (sys.argv[1], len(y) / sr, sr))
    print("peak %.1f dBFS  rms %.1f dBFS  crest %.1f dB  dc %.4f" %
          (db(np.abs(y).max()), db(np.sqrt((m ** 2).mean())), db(np.abs(y).max()) - db(np.sqrt((m ** 2).mean())),
           m.mean()))
    print("side/mid %.1f dB  corr %.2f" % (db(np.sqrt((s ** 2).mean())) - db(np.sqrt((m ** 2).mean())),
                                           np.corrcoef(L, R)[0, 1] if L.std() > 0 and R.std() > 0 else 1))
    print("bands (dB rel. total):", "  ".join("%d-%d:%.0f" % b for b in bands(m, sr)))
    n = int(seg * sr)
    print("segments (%.1fs): rms dBFS / peak / centroid Hz" % seg)
    for i in range(0, len(m), n):
        c = m[i:i + n]
        if len(c) < sr * 0.2:
            break
        sp = np.abs(np.fft.rfft(c))
        f = np.fft.rfftfreq(len(c), 1 / sr)
        cen = (sp * f).sum() / (sp.sum() + 1e-12)
        print("  %6.1fs  %6.1f  %6.1f  %6.0f" % (i / sr, db(np.sqrt((c ** 2).mean())), db(np.abs(c).max()), cen))


if __name__ == "__main__":
    main()
