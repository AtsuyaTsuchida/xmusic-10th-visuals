#!/usr/bin/env python3
"""stems.py が録音ファイルを見つけられなかったときの取り込み(セットを保存すると録音先がプロジェクト内に変わる)。
usage: recover.py 録音フォルダ 時刻タグ(例 "2026-11-18 140336") 停止位置[拍] BPM 出力フォルダ 秒数
録音は停止位置まで続いているので、ファイルの長さから録音開始位置を逆算して頭をそろえる。"""
import glob, os, sys
import numpy as np
from analyze import read_wav
from rec import write_wav

d, tag, stop_beat, bpm, out, secs = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5], float(sys.argv[6])
os.makedirs(out, exist_ok=True)
spb = 60.0 / bpm
for f in sorted(glob.glob(os.path.join(d, "_S_* 0001 [[]%s*[]].wav" % tag))):   # tag は前方一致
    name = os.path.basename(f)[3:].split(" 0001 ")[0]
    y, sr = read_wav(f)
    start_beat = stop_beat - len(y) / sr / spb
    pad = int(round(start_beat * spb * sr))
    y = np.vstack([np.zeros((pad, y.shape[1])), y]) if pad > 0 else y[-pad:]
    write_wav(os.path.join(out, name + ".wav"), y[:int(secs * sr)], sr)
    print("%-8s 録音 %.1fs 開始位置 %.3f 拍 -> %s" % (name, len(y) / sr, start_beat, name + ".wav"))
