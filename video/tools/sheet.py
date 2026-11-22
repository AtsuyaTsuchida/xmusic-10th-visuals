"""確認用の一覧画像を作る(動画は読むだけ)。
usage: sheet.py runs ID 出力.jpg      … 文字のかたまりごとに1コマ(検出枠つき)。左上から順に work/plan の runs の順
       sheet.py keep ID 出力.jpg      … 残す部分ごとに、始まり直後・中ほど・終わり直前の3コマ
       sheet.py times ID 出力.jpg 秒 秒 …  … 指定時刻のコマ
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "..", "work")
W, H, COLS = 384, 216, 6


def frame(path, t, out, boxes=()):
    vf = "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2" % (W, H, W, H)
    for x, y, w, h in boxes[:24]:
        vf += ",drawbox=x=%d:y=%d:w=%d:h=%d:color=red:t=2" % (x * W, y * H, max(2, w * W), max(2, h * H))
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "%.3f" % max(0, t), "-i", path,
                    "-frames:v", "1", "-vf", vf, "-q:v", "4", out], check=True)


def tile(files, out):
    rows = (len(files) + COLS - 1) // COLS
    d = os.path.dirname(files[0])
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", "1", "-i",
                    os.path.join(d, "%04d.jpg"), "-vf", "tile=%dx%d:margin=4:padding=4:color=gray" % (COLS, rows),
                    "-frames:v", "1", "-q:v", "4", out], check=True)


def main():
    mode, vid, out = sys.argv[1], sys.argv[2], sys.argv[3]
    p = json.load(open(os.path.join(WORK, "plan", vid + ".json")))
    jobs = []   # (時刻, 枠)
    if mode == "runs":
        samples = {}
        for ln in open(os.path.join(WORK, "text", vid + ".jsonl")):
            j = json.loads(ln)
            samples[j["t"]] = j["items"]
        ts = sorted(samples)
        for r in p["runs"]:
            inside = [t for t in ts if r["t0"] <= t <= r["t1"] and samples[t]]
            t = max(inside, key=lambda t: sum(i["w"] * i["h"] for i in samples[t]))
            jobs.append((t, [(i["x"], i["y"], i["w"], i["h"]) for i in samples[t]]))
    elif mode == "keep":
        # 残す部分の中のカットごとに、始まり直後と終わり直前、長いカットは途中も 12 秒おき
        for a, b in p["keep"]:
            edges = [a] + [c for c in p["cuts"] if a < c < b] + [b]
            for s0, s1 in zip(edges, edges[1:]):
                ts = [s0 + 0.12]
                n = int((s1 - s0) // 12)
                ts += [s0 + (s1 - s0) * (k + 1) / (n + 1) for k in range(n)]
                if s1 - s0 > 1.0:
                    ts.append(s1 - 0.15)
                jobs += [(t, []) for t in ts]
    else:
        jobs = [(float(t), []) for t in sys.argv[4:]]
    with tempfile.TemporaryDirectory() as d:
        files = []
        for k, (t, boxes) in enumerate(jobs):
            f = os.path.join(d, "%04d.jpg" % k)
            frame(p["path"], t, f, boxes)
            files.append(f)
        for c in range(0, len(files), 48):       # 1枚に 48 コマまで
            d2 = os.path.join(d, "p%d" % c)
            os.makedirs(d2)
            for k, f in enumerate(files[c:c + 48]):
                os.rename(f, os.path.join(d2, "%04d.jpg" % k))
            tile([os.path.join(d2, "0000.jpg")] * len(files[c:c + 48]),
                 out if len(files) <= 48 else out.replace(".jpg", ".%d.jpg" % (c // 48)))
    for k, (t, _) in enumerate(jobs):
        extra = ""
        if mode == "runs":
            r = p["runs"][k]
            extra = " %s %.1f-%.1f 面積%.3f 高さ%.3f %s" % (r["cls"], r["t0"], r["t1"], r["area"], r["hmax"], " / ".join(r["words"][:3])[:60])
        print("%3d (行%d 列%d) %8.2fs%s" % (k, k // COLS + 1, k % COLS + 1, t, extra))


if __name__ == "__main__":
    main()
