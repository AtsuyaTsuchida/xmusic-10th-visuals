"""候補区間を詳しく見る(読むだけ)。
usage: detail.py tone 音声フォルダ ID 開始 終了 [ID 開始 終了 ...]   … 平均スペクトルの山(音名とずれ)
       detail.py beat 音声フォルダ ID 開始 終了                        … 立上りの一覧とテンポの当てはめ
"""
import os
import sys

import librosa
import numpy as np
import soundfile as sf

NOTE = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def find(folder, vid):
    for n in os.listdir(folder):
        if "[" + vid + "]" in n:
            return os.path.join(folder, n)
    raise KeyError(vid)


def load(folder, vid, t0, t1):
    path = find(folder, vid)
    info = sf.info(path)
    y, sr = sf.read(path, start=int(t0 * info.samplerate), stop=int(t1 * info.samplerate), dtype="float32", always_2d=True)
    return y, sr


def name(f):
    m = 69 + 12 * np.log2(f / 440.0)
    k = int(round(m))
    return "%s%d%+03d" % (NOTE[k % 12], k // 12 - 1, round((m - k) * 100))


def tone(folder, args):
    for i in range(0, len(args), 3):
        vid, t0, t1 = args[i], float(args[i + 1]), float(args[i + 2])
        y, sr = load(folder, vid, t0, t1)
        m = y.mean(1)
        n = 32768
        S = np.abs(librosa.stft(m, n_fft=n, hop_length=n // 4)) ** 2
        p = S.mean(1)
        f = np.fft.rfftfreq(n, 1 / sr)
        db = 10 * np.log10(p + 1e-20)
        peaks = [k for k in range(8, len(p) - 1) if p[k] > p[k - 1] and p[k] >= p[k + 1] and 25 < f[k] < 6000]
        peaks.sort(key=lambda k: -p[k])
        out = []
        for k in peaks[:10]:
            a, b, c = db[k - 1], db[k], db[k + 1]
            d = 0.5 * (a - c) / (a - 2 * b + c)
            fk = (k + d) * sr / n
            out.append("%s(%.1fHz %+.0fdB)" % (name(fk), fk, db[k] - db[peaks[0]]))
        corr = float(np.corrcoef(y[:, 0], y[:, 1])[0, 1]) if y.shape[1] > 1 and y[:, 0].std() > 0 else 1.0
        rms = 20 * np.log10(np.sqrt((m ** 2).mean()) + 1e-9)
        pk = 20 * np.log10(np.abs(y).max() + 1e-9)
        # 区間内の音量のゆれ(1秒ごと)
        sec = [20 * np.log10(np.sqrt((m[j:j + sr] ** 2).mean()) + 1e-9) for j in range(0, len(m) - sr, sr)]
        print("%s %.1f-%.1f | rms %.1f peak %.1f | LR相関 %.2f | 毎秒dB %.0f〜%.0f" % (vid, t0, t1, rms, pk, corr, min(sec), max(sec)))
        print("   " + " ".join(out))


def beat(folder, args):
    vid, t0, t1 = args[0], float(args[1]), float(args[2])
    y, sr = load(folder, vid, t0, t1)
    m = y.mean(1)
    hop = 128
    oenv = librosa.onset.onset_strength(y=m, sr=sr, hop_length=hop)
    fps = sr / hop
    on = librosa.onset.onset_detect(onset_envelope=oenv, sr=sr, hop_length=hop, backtrack=False, units="frames", delta=0.12)
    # テンポ: 立上りの強さを櫛に当てはめる
    best = []
    for bpm in np.arange(70, 190, 0.1):
        per = fps * 60 / bpm / 4            # 16分音符
        for ph in np.linspace(0, per, 12, endpoint=False):
            idx = np.round(np.arange(ph, len(oenv) - 1, per)).astype(int)
            best.append((float(oenv[idx].mean()), bpm, ph / fps))
    best.sort(reverse=True)
    seen = []
    for s, bpm, ph in best:
        if all(abs(bpm - b) > 1.5 for _, b, _ in seen):
            seen.append((s, bpm, ph))
        if len(seen) >= 6:
            break
    print("テンポ候補: " + " | ".join("%.1fbpm 位相%.3fs 点%.2f" % (b, p, s) for s, b, p in seen))
    S = np.abs(librosa.stft(m, n_fft=1024, hop_length=hop)) ** 2
    f = np.fft.rfftfreq(1024, 1 / sr)
    for k in on:
        a = S[:, k:k + 12].sum(1)
        tot = a.sum() + 1e-12
        lo, mid, hi = a[f < 150].sum() / tot, a[(f >= 150) & (f < 2500)].sum() / tot, a[f >= 2500].sum() / tot
        cls = "K" if lo > 0.45 else ("H" if hi > 0.5 else "S")
        print("%7.3f %s 強さ %4.1f 低 %.2f 中 %.2f 高 %.2f" % (t0 + k / fps, cls, oenv[k], lo, mid, hi))


if sys.argv[1] == "tone":
    tone(sys.argv[2], sys.argv[3:])
else:
    beat(sys.argv[2], sys.argv[3:])
