"""素材から断片を切り出して Live の User Library に置く。切り出すだけで、音量・音程・フェードなどの加工は一切しない
(それらは Live の中で行う)。usage: cut.py 音声フォルダ 走査結果フォルダ
出力: ~/Music/Ableton/User Library/Samples/XMusicCollage/ と work/manifest.json
"""
import json
import os
import shutil
import sys

import numpy as np
import soundfile as sf

SRC, SCAN = sys.argv[1], sys.argv[2]
ONLY = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None   # 例: grain だけ書き直す
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.expanduser("~/Music/Ableton/User Library/Samples/XMusicCollage")
REL = "Samples/XMusicCollage"

TITLE = {}
PATH = {}
for n in os.listdir(SRC):
    if n.endswith(".wav"):
        vid = n[n.rfind("[") + 1:n.rfind("]")]
        PATH[vid] = os.path.join(SRC, n)
        TITLE[vid] = n[:n.rfind("[")].strip()

# ドローン用の区間 (ID, 開始, 終了, 主な音)
DRONES = {
    "urban_G": ("_ypZv_fnXxw", 130.0, 144.0, "G+D"),
    "orbis_D": ("IfhvUUInXSA", 70.0, 101.0, "D の塊"),
    "orbis_C": ("IfhvUUInXSA", 297.0, 317.0, "C5 D4 E4 G4"),
    "rhopalia_Am": ("HBFbDtB_Nsw", 237.0, 245.6, "E G A C"),
    "micro_low": ("lkDefi8MPBE", 62.0, 118.0, "A+C# (Live で2半音下げて G+B)"),
    "micro_deep": ("lkDefi8MPBE", 330.0, 351.0, "C# D A F# (2半音下げて B C G E)"),
    "brain_air": ("D16I-ivJemM", 484.0, 544.0, "無調の塊"),
    "intona_roar": ("5exsWJTsdJE", 591.0, 607.0, "騒音機械の唸り"),
    "trans_noise": ("F0hwyvr1jEM", 641.0, 667.0, "ノイズ"),
}
# 1小節ずつ切るループ (ID, 最初の小節の頭, 元テンポ, 小節数)
LOOPS = {
    "drum": ("GxUCzhEopHc", 57.000, 150.2, 4),
    "tops": ("eoxtuzD0boc", 9.124, 161.4, 4),
    "room": ("p4xJ_N4SEi8", 317.016, 160.9, 4),
    "brain": ("D16I-ivJemM", 417.073, 120.0, 2),
    "aqua": ("fWhbtSgltVc", 184.000, 120.3, 2),
}
KIT_FILES = ["GxUCzhEopHc", "5exsWJTsdJE", "ygqWnyfdpNc", "TzUkfj8-LF8", "F0hwyvr1jEM", "NuWsNpy89tI",
             "D16I-ivJemM", "HBFbDtB_Nsw", "p4xJ_N4SEi8", "vcVdSxxMeMA", "rSHL24gcOUo"]
GRAIN_FILES = ["ML-aZeJ32UQ", "q57V__AxyE8", "rSHL24gcOUo", "vcVdSxxMeMA", "4diG4lfNYX4", "SeemSt_5GbM",
               "NuWsNpy89tI", "eoxtuzD0boc", "fWhbtSgltVc"]


def read(vid, t0, t1):
    info = sf.info(PATH[vid])
    sr = info.samplerate
    a, b = max(0, int(round(t0 * sr))), min(info.frames, int(round(t1 * sr)))
    y, _ = sf.read(PATH[vid], start=a, stop=b, dtype="int16", always_2d=True)
    return y, sr


def db(x):
    return 20 * np.log10(max(float(x), 1e-9))


def write(kind, name, vid, t0, t1, extra=None):
    y, sr = read(vid, t0, t1)
    d = os.path.join(LIB, kind)
    os.makedirs(d, exist_ok=True)
    if ONLY is None or kind in ONLY:
        sf.write(os.path.join(d, name + ".wav"), y, sr, subtype="PCM_16")
    f = y.astype(np.float64) / 32768.0
    e = {"name": name, "kind": kind, "path": "%s/%s/%s.wav" % (REL, kind, name), "vid": vid, "title": TITLE[vid],
         "t0": round(t0, 4), "t1": round(t1, 4), "dur": round(len(y) / sr, 4),
         "peak_db": round(db(np.abs(f).max()), 1), "rms_db": round(db(np.sqrt((f ** 2).mean())), 1)}
    e.update(extra or {})
    return e


def refine(vid, t, gap, maxdur, through=False):
    """立上り t の前後を元の解像度で見て、切り出しの始点・終点と帯域の割合を返す。"""
    # through: 次の立上りで切らず、余韻が消えるところ(か maxdur)まで取る
    y, sr = read(vid, t - 0.08, t + (maxdur if through else min(gap, maxdur)) + 0.15)
    if len(y) < sr * 0.1:
        return None
    m = np.abs(y.astype(np.float64) / 32768.0).max(1)
    w = int(0.002 * sr)
    env = np.convolve(m, np.ones(w) / w, "same")
    o = int(0.08 * sr)
    a, b = max(0, o - int(0.03 * sr)), min(len(env), o + int(0.12 * sr))
    pk = a + int(np.argmax(env[a:b]))
    peak = env[pk]
    if peak < 1e-4:
        return None
    i = pk
    while i > 0 and i > pk - int(0.1 * sr) and env[i] > 0.08 * peak:
        i -= 1
    start = max(0, i - int(0.003 * sr))
    pre = np.sqrt((m[max(0, start - int(0.05 * sr)):max(1, start)] ** 2).mean())
    limit = min(len(env), start + int((maxdur if through else min(gap - 0.004, maxdur)) * sr))
    w2 = int(0.02 * sr)
    env2 = np.convolve(m, np.ones(w2) / w2, "same")
    end = limit
    for j in range(pk + int(0.03 * sr), limit):
        if env2[j] < 0.03 * peak:
            end = min(limit, j + int(0.01 * sr))
            break
    seg = y[start:start + int(0.08 * sr)].astype(np.float64).mean(1)
    if len(seg) < 256:
        return None
    P = np.abs(np.fft.rfft(seg * np.hanning(len(seg)))) ** 2
    f = np.fft.rfftfreq(len(seg), 1 / sr)
    tot = P.sum() + 1e-12
    bands = [P[f < 120].sum() / tot, P[(f >= 120) & (f < 300)].sum() / tot,
             P[(f >= 300) & (f < 2500)].sum() / tot, P[f >= 2500].sum() / tot]
    t0 = t - 0.08 + start / sr
    return {"t0": t0, "t1": t - 0.08 + end / sr, "dur": (end - start) / sr, "peak": db(m[start:end].max()),
            "contrast": db(peak) - db(pre + 1e-6), "sub": bands[0], "low": bands[1], "mid": bands[2], "high": bands[3]}


def candidates(vid, maxdur, min_contrast=8, through=False):
    r = json.load(open(os.path.join(SCAN, vid + ".json")))
    out = []
    for o in r["onsets"]:
        if o["peak_db"] - o["pre_db"] < min_contrast or o["gap"] < 0.07:
            continue
        x = refine(vid, o["t"], o["gap"], maxdur, through)
        if x and x["dur"] > 0.03:
            x["vid"] = vid
            out.append(x)
    return out


def choose(pool, n, key, cap, used):
    out, per = [], {}
    for x in sorted(pool, key=key, reverse=True):
        if per.get(x["vid"], 0) >= cap or any(x["vid"] == u["vid"] and abs(x["t0"] - u["t0"]) < 0.3 for u in used):
            continue
        out.append(x)
        used.append(x)
        per[x["vid"]] = per.get(x["vid"], 0) + 1
        if len(out) >= n:
            break
    return out


def main():
    if ONLY is None and os.path.isdir(LIB):
        shutil.rmtree(LIB)
    man = {"drones": [], "loops": [], "kit": [], "grains": []}
    for name, (vid, t0, t1, note) in DRONES.items():
        man["drones"].append(write("drone", name, vid, t0, t1, {"note": note}))
    for name, (vid, t0, bpm, bars) in LOOPS.items():
        bar = 240.0 / bpm
        for k in range(bars):
            # 少し長めに切る(次の音が入るまでの余韻)。Live 側でフェードアウトをかける
            man["loops"].append(write("loop", "%s_%d" % (name, k + 1), vid, t0 + k * bar, t0 + (k + 1) * bar + 0.03,
                                      {"src_bpm": bpm, "group": name}))
    # 打撃音
    pool = []
    for vid in KIT_FILES:
        pool += [x for x in candidates(vid, 0.5) if x["peak"] > -26]
    used = []
    # 核になる打音は小田急ドラムセッションから(詳細解析で見つけた位置)
    G = "GxUCzhEopHc"
    forced = {"kick": [(G, 71.357, 0.41), (G, 70.175, 0.39), (G, 57.399, 0.39)],
              "snare": [(G, 52.641, 0.5), (G, 57.790, 0.39), (G, 67.398, 0.31)],
              "hat": [(G, 52.026, 0.3)], "perc": []}
    fx = {}
    for cls, lst in forced.items():
        fx[cls] = []
        for vid, t, gap in lst:
            x = refine(vid, t, gap, 0.45)
            x["vid"] = vid
            fx[cls].append(x)
            used.append(x)
    pool = [x for x in pool if x["vid"] != G]
    kick = fx["kick"] + choose([x for x in pool if x["sub"] > 0.3 and x["sub"] + x["low"] > 0.6 and x["dur"] > 0.1],
                               1, lambda x: x["contrast"] + 20 * (x["sub"] + x["low"]) + 0.3 * x["peak"], 1, used)
    snare = fx["snare"] + choose([x for x in pool if x["mid"] + x["high"] > 0.75 and x["high"] > 0.12 and 0.06 < x["dur"] < 0.45],
                                 1, lambda x: x["contrast"] + 0.3 * x["peak"], 1, used)
    hat = fx["hat"] + choose([x for x in pool if x["high"] > 0.5 and x["dur"] < 0.25],
                             3, lambda x: x["contrast"] + 15 * x["high"] + 0.3 * x["peak"], 2, used)
    perc = choose([x for x in pool if x["mid"] > 0.6 and x["high"] <= 0.12 and x["dur"] > 0.06],
                  4, lambda x: x["contrast"] + 0.3 * x["peak"], 1, used)
    for cls, items in (("kick", kick), ("snare", snare), ("hat", hat), ("perc", perc)):
        for i, x in enumerate(items):
            man["kit"].append(write("kit", "%s_%d" % (cls, i + 1), x["vid"], x["t0"], x["t1"],
                                    {"cls": cls, "contrast": round(x["contrast"], 1),
                                     "bands": [round(float(x[b]), 2) for b in ("sub", "low", "mid", "high")]}))
    # 粒
    pool = []
    for vid in GRAIN_FILES:
        pool += [x for x in candidates(vid, 0.7, 6, through=True) if x["peak"] > -45]
    grains = choose([x for x in pool if x["dur"] > 0.04], 16, lambda x: x["contrast"], 2, used)
    for i, x in enumerate(grains):
        man["grains"].append(write("grain", "grain_%02d" % (i + 1), x["vid"], x["t0"], x["t1"],
                                   {"contrast": round(x["contrast"], 1),
                                    "bands": [round(float(x[b]), 2) for b in ("sub", "low", "mid", "high")]}))
    json.dump(man, open(os.path.join(ROOT, "work", "manifest.json"), "w"), ensure_ascii=False, indent=1)
    for k, items in man.items():
        print("--- %s (%d)" % (k, len(items)))
        for e in items:
            print("%-12s %6.2fs peak %5.1f rms %5.1f | %s %.2f-%.2f %s %s" % (
                e["name"], e["dur"], e["peak_db"], e["rms_db"], e["title"][:26], e["t0"], e["t1"],
                e.get("bands", ""), e.get("note", "")))


main()
