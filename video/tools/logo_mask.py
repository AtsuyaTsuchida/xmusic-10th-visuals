#!/usr/bin/env python3
"""ロゴの画像(明るい地に黒いロゴ)から、ロゴの形だけを抜き出す。

  ../../glitch-house-generate-main/.venv/bin/python tools/logo_mask.py 元の画像.png 出力.png [仕上がりの高さ]

出力は白黒の絵(白 = ロゴ、黒 = 何もない所)。アプリはこれを型紙にして、ロゴを白で塗る。
地は白か明るい灰色(透明を表す模様も含む)とみなし、白から離れた所(黒い所も、色のついた所も)をロゴとする。
元が小さいので、縦横 3 倍に拡大してから、ふちをなめらかに決め直している(ffmpeg で読み書き、numpy で計算)。
"""
import subprocess
import sys

import numpy as np

UP = 3


def main(src, dst, height=0):
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", src], capture_output=True, text=True).stdout
    w, h = (int(v) for v in probe.strip().split(",")[:2])
    # 仕上がりの高さを指定しなければ 3 倍に拡大(小さい画像用)。指定すれば、その高さへ拡大・縮小する(大きい画像用)
    H = height if height else h * UP
    W = int(round(w * H / h / 2)) * 2
    # 透明な所は白地とみなす
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", src, "-filter_complex", "color=c=white:s=%dx%d[bg];[0]scale=%d:%d:flags=lanczos[fg];[bg][fg]overlay=format=auto,format=rgb24" % (W, H, W, H),
                          "-frames:v", "1", "-f", "rawvideo", "-"], capture_output=True).stdout
    rgb = np.frombuffer(raw, dtype=np.uint8).reshape(H, W, 3).astype(np.float32) / 255
    d = 1 - rgb.min(axis=2)                       # 白からどれだけ離れているか(黒でも、黄色などの色でも 1 に近くなる)
    a = np.clip((d - 0.38) / 0.24, 0, 1)          # 地は 0.1 以下、ロゴは 0.7 以上。その間をふちとしてなめらかにつなぐ
    a = a * a * (3 - 2 * a)
    ys, xs = np.where(a > 0.5)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    pad = 6
    x0, y0, x1, y1 = max(0, x0 - pad), max(0, y0 - pad), min(W, x1 + pad), min(H, y1 + pad)
    out = (a[y0:y1, x0:x1] * 255 + 0.5).astype(np.uint8)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray", "-s", "%dx%d" % (out.shape[1], out.shape[0]), "-i", "-", dst], input=out.tobytes(), check=True)
    print("元 %dx%d → ロゴの形 %dx%d -> %s" % (w, h, out.shape[1], out.shape[0], dst))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 0)
