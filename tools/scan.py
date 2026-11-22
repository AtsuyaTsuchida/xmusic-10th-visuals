"""素材の音を解析して、ドローン向きの区間・打撃音・拍のはっきりした区間を探すための特徴量を書き出す。
音は作らない(読むだけ)。usage: scan.py 音声フォルダ 出力フォルダ
"""
import json
import os
import sys

import librosa
import numpy as np

SR = 22050
HOP = 512
FPS = SR / HOP


def scan(path):
    y, _ = librosa.load(path, sr=SR, mono=True)
    dur = len(y) / SR
    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=HOP)).astype(np.float32)
    P = S ** 2
    freqs = librosa.fft_frequencies(sr=SR, n_fft=2048)
    tot = P.sum(0) + 1e-12
    rms = np.sqrt(tot / 1024.0 / 2048.0 * 2)
    db = 20 * np.log10(rms + 1e-9)
    cent = (freqs[:, None] * P).sum(0) / tot
    flat = np.exp(np.log(P + 1e-12).mean(0)) / (P.mean(0) + 1e-12)
    low = P[freqs < 150].sum(0) / tot
    high = P[freqs > 5000].sum(0) / tot
    mel = librosa.feature.melspectrogram(S=P, sr=SR, n_mels=96)
    oenv = librosa.onset.onset_strength(S=librosa.power_to_db(mel, ref=np.max), sr=SR, hop_length=HOP)
    chroma = librosa.feature.chroma_stft(S=P, sr=SR, n_fft=2048, hop_length=HOP)
    del S

    # 打撃音: 立ち上がりの位置と、その直後の性格
    on = librosa.onset.onset_detect(onset_envelope=oenv, sr=SR, hop_length=HOP, backtrack=True, units="frames")
    onsets = []
    for i, f in enumerate(on):
        nxt = on[i + 1] if i + 1 < len(on) else len(db) - 1
        a = slice(f, min(f + 4, len(db)))                 # 立ち上がり直後 約90ms
        pk = f + int(np.argmax(db[f:min(f + 6, len(db))]))
        # ピークから 20dB 落ちるまでの時間
        k = pk
        while k < len(db) - 1 and k - pk < FPS * 3 and db[k] > db[pk] - 20:
            k += 1
        onsets.append({
            "t": round(f / FPS, 4), "peak_db": round(float(db[pk]), 1), "str": round(float(oenv[min(f + 2, len(oenv) - 1)]), 2),
            "cent": round(float(np.median(cent[a]))), "low": round(float(np.mean(low[a])), 3),
            "high": round(float(np.mean(high[a])), 3), "flat": round(float(np.median(flat[a])), 4),
            "decay": round((k - pk) / FPS, 3), "gap": round((nxt - f) / FPS, 3),
            "pre_db": round(float(np.mean(db[max(0, f - 4):max(1, f)])), 1),
        })

    # 4秒窓(2秒刻み): ドローン向きかどうか
    wins = []
    w, h = int(4 * FPS), int(2 * FPS)
    for s in range(0, max(1, len(db) - w), h):
        e = s + w
        c = chroma[:, s:e]
        cm = c.mean(1)
        cm = cm / (cm.sum() + 1e-9)
        halves = [c[:, s2:s2 + w // 8].mean(1) for s2 in range(0, w - w // 8 + 1, w // 8)]
        sims = [float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9)) for a, b in zip(halves, halves[1:])]
        wins.append({
            "t": round(s / FPS, 2), "db": round(float(np.mean(db[s:e])), 1), "db_sd": round(float(np.std(db[s:e])), 1),
            "onsets": int(np.sum((on >= s) & (on < e))), "flat": round(float(np.median(flat[s:e])), 4),
            "cent": round(float(np.median(cent[s:e]))), "low": round(float(np.mean(low[s:e])), 3),
            "pc": int(np.argmax(cm)), "conc": round(float(np.max(cm)), 3), "stab": round(float(np.mean(sims)), 3),
        })

    # 8秒窓(4秒刻み): テンポと拍のはっきり度
    rh = []
    w, h = int(8 * FPS), int(4 * FPS)
    lo, hi = int(FPS * 60 / 200), int(FPS * 60 / 60)
    for s in range(0, max(1, len(oenv) - w), h):
        o = oenv[s:s + w] - oenv[s:s + w].mean()
        ac = librosa.autocorrelate(o)
        if ac[0] <= 0:
            continue
        seg = ac[lo:hi] / ac[0]
        lag = lo + int(np.argmax(seg))
        rh.append({"t": round(s / FPS, 2), "bpm": round(60 * FPS / lag, 1), "clar": round(float(seg.max()), 3),
                   "onsets": int(np.sum((on >= s) & (on < s + w))), "db": round(float(np.mean(db[s:s + w])), 1)})
    return {"dur": round(dur, 2), "db": round(float(np.mean(db)), 1), "onsets": onsets, "wins": wins, "rhythm": rh}


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for name in sorted(os.listdir(src)):
        if not name.endswith(".wav"):
            continue
        vid = name[name.rfind("[") + 1:name.rfind("]")]
        dst = os.path.join(out, vid + ".json")
        if not os.path.exists(dst):
            r = scan(os.path.join(src, name))
            r["name"] = name
            json.dump(r, open(dst, "w"))
        r = json.load(open(dst))
        dr = [x for x in r["wins"] if x["onsets"] <= 2 and x["db"] > r["db"] - 6 and x["stab"] > 0.9]
        rr = sorted(r["rhythm"], key=lambda x: -x["clar"])[:1]
        print("%s | %d:%02d | %.0fdB | 立上り %d (%.1f/s) | ドローン窓 %d | 拍最良 %s | %s" % (
            vid, r["dur"] // 60, r["dur"] % 60, r["db"], len(r["onsets"]), len(r["onsets"]) / r["dur"], len(dr),
            ("%.0fbpm clar %.2f @%ds" % (rr[0]["bpm"], rr[0]["clar"], rr[0]["t"])) if rr else "-", r["name"][:34]), flush=True)


main()
