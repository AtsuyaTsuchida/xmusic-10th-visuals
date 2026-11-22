"""work/plan/<ID>.json の keep(残す時間帯)だけをつないだ動画を書き出す。元の動画は読むだけ。
音声は入れない(映像素材として使うため)。
usage: export.py 出力フォルダ [ID ...]
出力: <出力フォルダ>/<題名> [ID].mp4 と、元動画のどこを残したかの一覧 segments.csv
"""
import csv
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "..", "work")


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    ids = sys.argv[2:] or sorted(n[:-5] for n in os.listdir(os.path.join(WORK, "plan")) if n.endswith(".json"))
    rows = []
    for vid in ids:
        p = json.load(open(os.path.join(WORK, "plan", vid + ".json")))
        name = "%s [%s].mp4" % (p["title"], vid)
        dst = os.path.join(out, name)
        pos = 0.0
        for a, b in p["keep"]:
            rows.append([name, "%.3f" % pos, "%.3f" % (pos + b - a), "%.3f" % a, "%.3f" % b])
            pos += b - a
        if not p["keep"]:
            print("%s 残す部分なし" % vid)
            if os.path.exists(dst):
                os.remove(dst)
            continue
        if os.path.exists(dst) and os.path.exists(dst + ".keep") and json.load(open(dst + ".keep")) == p["keep"]:
            print("%s 済み" % vid)
            continue
        e = 0.002
        expr = "+".join("gte(t,%.3f)*lt(t,%.3f)" % (a - e, b - e) for a, b in p["keep"])
        tmp = dst + ".part.mp4"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", p["path"], "-an",
                        "-vf", "select='%s',setpts=N/FRAME_RATE/TB" % expr,
                        "-c:v", "libx264", "-crf", "16", "-preset", "fast", "-pix_fmt", "yuv420p",
                        "-movflags", "+faststart", tmp], check=True)
        os.replace(tmp, dst)
        json.dump(p["keep"], open(dst + ".keep", "w"))
        print("%s 書き出し %.0fs (%d区間)" % (vid, pos, len(p["keep"])), flush=True)
    path = os.path.join(out, "segments.csv")
    old = []
    if os.path.exists(path) and sys.argv[2:]:
        names = {r[0] for r in rows}
        old = [r for r in list(csv.reader(open(path, encoding="utf-8")))[1:] if r[0] not in names]
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "start_in_file", "end_in_file", "start_in_original", "end_in_original"])
        w.writerows(sorted(old + rows, key=lambda r: (r[0], float(r[1]))))


if __name__ == "__main__":
    main()
