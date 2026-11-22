"""書き出した動画をもう一度文字検出にかけ、残っている文字を一覧にする(読むだけ)。
usage: verify.py 書き出しフォルダ
出力: work/verify/<ID>.jsonl と、画面への一覧表示(時刻は書き出した動画の中での秒)
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import analyze as A  # noqa: E402
WORK = os.path.join(HERE, "..", "work")


def main():
    out = sys.argv[1]
    os.makedirs(os.path.join(WORK, "verify"), exist_ok=True)
    big = small = 0
    for n in sorted(os.listdir(out)):
        m = re.match(r"(.*)\[([A-Za-z0-9_-]{11})\]\.mp4$", n)
        if not m:
            continue
        vid = m.group(2)
        j = os.path.join(WORK, "verify", vid + ".jsonl")
        src = os.path.join(out, n)
        if not os.path.exists(j) or os.path.getmtime(j) < os.path.getmtime(src):
            subprocess.run([os.path.join(HERE, "textscan"), src, "0.5", j], check=True)
        runs, weak = A.text_runs(A.text_samples(j))
        for r in runs:
            d = A.describe(r)
            cls = "載せた文字?" if d["area"] >= A.BIG else "写り込み"
            big += d["area"] >= A.BIG
            small += d["area"] < A.BIG
            print("%s %-11s %7.1f-%7.1f 面積%.3f 高さ%.3f %s" % (
                vid, cls, r["t0"], r["t1"], d["area"], d["hmax"], " / ".join(d["words"][:3])[:70]), flush=True)
    print("載せた文字の疑い %d 件、写り込み %d 件" % (big, small))


if __name__ == "__main__":
    main()
