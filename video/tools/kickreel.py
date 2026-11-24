#!/usr/bin/env python3
"""通しの終盤(キックだけが続く区間)に流す動画を、前もって 1 本に組む。

  python3 tools/kickreel.py 曲.cues.json 素材のフォルダ 出力.mp4 [順番の版を始める秒]

最後の引数を付けると「順番の版」: その秒あたりのキックから、キックだけのパートの手前までを、素材を名前の順に 1 本ずつ回して組む。

キックが鳴るコマごとに別の素材の別の場所へ切り替わる 1 本の動画(1920x540、30 コマ/秒、音なし)を作る。
アプリはこの 1 本を頭から流すだけなので、再生中に場所を選んだり頭出ししたりしない。

同じ所が二度出ないことは、場所の決め方で保証する:
  - 素材 1 本ごとに、使う回数ぶんの場所を、頭から終わりまで等間隔に割り振る(となりどうしは MIN_GAP 秒以上離す)
  - 1 回に使う長さは MIN_GAP より必ず短い → 同じ素材の中で、使う区間どうしは重なりようがない
  - 続けて同じ素材は使わない
最後に、実際に使った区間どうしが重なっていないかを総当たりで確かめ、一覧(.csv)を書き出す。
"""
import csv
import json
import os
import random
import subprocess
import sys
import tempfile

FPS = 30
W, H = (int(v) for v in os.environ.get("REEL_SIZE", "1920x540").split("x"))    # 16:9 版は REEL_SIZE=1920x1080
MIN_GAP = 2.5      # 同じ素材の中で、使う場所どうしを最低これだけ離す(秒)
HOLD = 0.4         # 最後のキックのあとに出しておく秒数(アプリの seqVideoHold と同じ)
EDGE = 0.5         # 素材の頭と終わりの、使わない幅(秒)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path], capture_output=True, text=True).stdout
    return float(out.strip())


def main(cues_path, src_dir, dst, ordered_from=None):
    lanes = json.load(open(cues_path))["lanes"]
    kicks, claps = [t for t, _ in lanes["kick"]], [t for t, _ in lanes["clap"]]
    first = next(t for t in kicks if t > claps[-1] + 0.05)
    frames = sorted({int(t * FPS + 1e-6) for t in kicks if t >= first - 0.01})          # 切り替わるコマ(同じコマのキックは 1 つに)
    end = int((kicks[-1] + HOLD) * FPS + 0.5)
    if ordered_from is not None:
        # 「順番に」の版: ordered_from 秒あたりのキックから、キックだけのパートの手前まで。素材を名前の順に 1 本ずつ回し、ひと回りするごとに各素材の先の場所へ進む
        k0 = next(t for t in kicks if t >= ordered_from - 0.05)
        end = int(first * FPS + 1e-6)
        frames = sorted({int(t * FPS + 1e-6) for t in kicks if k0 - 0.01 <= t < first - 0.01})
    lengths = [b - a for a, b in zip(frames, frames[1:] + [end])]                         # 各カットのコマ数
    assert max(lengths) / FPS < MIN_GAP, "1 カットが MIN_GAP より長い"
    n = len(lengths)

    files = sorted(f for f in os.listdir(src_dir) if f.lower().endswith((".mp4", ".mov", ".m4v")))
    durs = {f: duration(os.path.join(src_dir, f)) for f in files}
    cap = {f: max(0, int((durs[f] - 2 * EDGE) / MIN_GAP)) for f in files}                # その素材から取れる場所の数
    rng = random.Random(20261122)
    # 素材ごとの回数: 取れる場所が残っている素材へ、順ぐりに 1 回ずつ配る
    uses = {f: 0 for f in files}
    left = n
    seq = []                                       # 順番の版で出す素材の並び
    while left > 0 and ordered_from is not None:
        avail = [f for f in files if uses[f] < cap[f]]
        assert avail, "素材が足りない"
        for f in avail:
            if left == 0:
                break
            uses[f] += 1; left -= 1; seq.append(f)
    while left > 0:
        avail = [f for f in files if uses[f] < cap[f]]
        assert avail, "素材が足りない"
        rng.shuffle(avail)
        for f in avail:
            if left == 0:
                break
            uses[f] += 1; left -= 1
    # 素材ごとの場所: 等間隔に割り振って、出す順番だけ混ぜる
    slots = {}
    for f in files:
        k = uses[f]
        step = (durs[f] - 2 * EDGE) / k if k else 0
        s = [EDGE + step * (m + 0.5) - 0.5 * MIN_GAP * 0 for m in range(k)]
        if ordered_from is None:
            rng.shuffle(s)
        else:
            s.reverse()                            # pop() で前から順に出るように
        slots[f] = s
    # 出す順番: 続けて同じ素材にならないように、残りの多い素材から選ぶ
    order, prev = [], None
    for f in seq:
        order.append((f, slots[f].pop()))
    for _ in range(n if ordered_from is None else 0):
        cands = [f for f in files if slots[f] and f != prev] or [f for f in files if slots[f]]
        top = max(len(slots[f]) for f in cands)
        f = rng.choice([c for c in cands if len(slots[c]) >= top - 1])
        order.append((f, slots[f].pop())); prev = f

    # 重なりの総当たり確認(同じ素材の中で、区間どうしが重ならないこと)
    used = {}
    for (f, start), ln in zip(order, lengths):
        used.setdefault(f, []).append((start, start + ln / FPS))
    worst = 1e9
    for f, iv in used.items():
        iv.sort()
        for (a0, a1), (b0, b1) in zip(iv, iv[1:]):
            assert b0 >= a1, "重なり: %s %.2f-%.2f / %.2f-%.2f" % (f, a0, a1, b0, b1)
            worst = min(worst, b0 - a1)
    print("カット %d 個、素材 %d 本。同じ素材の中で、使う区間どうしのいちばん近いすき間 %.2f 秒(重なりなし)" % (n, len(used), worst))

    with tempfile.TemporaryDirectory() as tmp:
        lst = os.path.join(tmp, "list.txt")
        with open(lst, "w") as L:
            for i, ((f, start), ln) in enumerate(zip(order, lengths)):
                seg = os.path.join(tmp, "s%04d.mp4" % i)
                vf = "fps=%d,scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1" % (FPS, W, H, W, H)
                subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "%.4f" % start, "-i", os.path.join(src_dir, f), "-frames:v", str(ln), "-vf", vf,
                                "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "15", "-g", "1", "-pix_fmt", "yuv420p", "-video_track_timescale", "30000", seg], check=True)
                L.write("file '%s'\n" % seg)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", dst], check=True)
    with open(os.path.splitext(dst)[0] + ".csv", "w", newline="") as C:
        w = csv.writer(C)
        w.writerow(["cut", "song_sec", "frames", "clip", "clip_start_sec", "clip_end_sec"])
        for i, ((f, start), ln, fr) in enumerate(zip(order, lengths, frames)):
            w.writerow([i + 1, "%.3f" % (fr / FPS), ln, f, "%.3f" % start, "%.3f" % (start + ln / FPS)])
    print("区間 %.3f 〜 %.3f 秒、%d コマ -> %s" % (frames[0] / FPS, end / FPS, sum(lengths), dst))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else None)
