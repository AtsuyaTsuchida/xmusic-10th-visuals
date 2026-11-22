#!/usr/bin/env python3
"""v1 の粒(短く切ったままの断片)を、v1 のときの位置どおりに別フォルダ grain_v1 へ切り出す。加工はしない。
usage: cut_v1_grains.py 音声フォルダ    (work/manifest_v1.json を読み、パスを書き換えて保存する)"""
import json, os, sys
import numpy as np
import soundfile as sf

SRC = sys.argv[1]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.expanduser("~/Music/Ableton/User Library/Samples/XMusicCollage/grain_v1")
os.makedirs(LIB, exist_ok=True)
mp = os.path.join(ROOT, "work", "manifest_v1.json")
man = json.load(open(mp))
path = {n[n.rfind("[") + 1:n.rfind("]")]: os.path.join(SRC, n) for n in os.listdir(SRC) if n.endswith(".wav")}
for e in man["grains"]:
    sr = sf.info(path[e["vid"]]).samplerate
    y, _ = sf.read(path[e["vid"]], start=int(round(e["t0"] * sr)), stop=int(round(e["t1"] * sr)), dtype="int16", always_2d=True)
    sf.write(os.path.join(LIB, e["name"] + ".wav"), y, sr, subtype="PCM_16")
    pk = 20 * np.log10(max(np.abs(y.astype(np.float64) / 32768).max(), 1e-9))
    e["path"] = "Samples/XMusicCollage/grain_v1/%s.wav" % e["name"]
    print("%s %.3fs peak %.1f (v1 の記録: %.3fs %.1f)" % (e["name"], len(y) / sr, pk, e["dur"], e["peak_db"]))
json.dump(man, open(mp, "w"), ensure_ascii=False, indent=1)
