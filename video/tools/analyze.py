"""文字の検出結果(work/text)と画面変化量(work/scene)から、カットの切れ目と「文字が映っている時間帯」を出す。
動画は読むだけ。結果は work/plan/<ID>.json。
usage: analyze.py 動画フォルダ [ID ...]
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "..", "work")

STEP = 0.5          # 文字検出の間隔(textscan に渡した値)
PAD = 0.75          # 文字の前後に足す余白(フェードで薄く出入りする分)
JOIN = 1.5          # これ以下の切れ間は同じ文字のかたまりとみなす
SHORT_SHOT = 20.0   # これ以下のカットは、文字が一部でもあればカットごと消す
SNAP = 2.0          # 消す範囲の端からこの秒数以内にカットの切れ目があれば、そこまで広げる
MIN_KEEP = 1.5      # 残る部分がこれより短ければ一緒に消す
DARK_Y = 17.5       # 画面全体の明るさ(Y の平均、黒 = 16)がこれ以下なら黒味
DARK_MIN = 0.75     # 黒味がこの秒数以上続いたら消す
BIG = 0.012         # 文字の面積(画面比)がこれ以上なら「載せた文字」とみなす。未満は「写り込み」として既定では残す
# 目で見て決めた例外: work/overrides.json  {ID: {"overlay": [[開始,終了],…], "small": [[開始,終了],…], "remove": [[開始,終了],…]}}
#   overlay / small … その時間に重なる文字のかたまりの判定を上書き。
#   remove … 検出に関係なく、その時間を含むカットを消す(長いカットではその時間帯だけ)。cut … その時間帯だけを消す


def videos(src):
    out = {}
    for n in sorted(os.listdir(src)):
        m = re.match(r"(.*)\[([A-Za-z0-9_-]{11})\]\.mp4$", n)
        if m:
            out[m.group(2)] = (os.path.join(src, n), m.group(1).strip())
    return out


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                        "stream=width,height,r_frame_rate:format=duration", "-of", "json", path],
                       capture_output=True, text=True, check=True)
    j = json.loads(r.stdout)
    s = j["streams"][0]
    a, b = s["r_frame_rate"].split("/")
    return {"w": s["width"], "h": s["height"], "fps": float(a) / float(b), "dur": float(j["format"]["duration"])}


def read_meta(path, key):
    """ffmpeg の metadata=print の出力を (時刻, 値) の列にする。"""
    ts, vs = [], []
    t = None
    for ln in open(path):
        if ln.startswith("frame:"):
            t = float(ln.rsplit("pts_time:", 1)[1])
        elif ln.startswith(key + "="):
            ts.append(t)
            vs.append(float(ln.split("=", 1)[1]))
    return ts, vs


def cuts(ts, sc):
    """カットの切れ目(新しいカットの最初のコマの時刻)。"""
    out = []
    n = len(sc)
    for i in range(1, n):
        v = sc[i]
        if v < 0.08:
            continue
        nb = [sc[j] for j in range(max(1, i - 4), min(n, i + 5)) if j != i]
        m = max(nb) if nb else 0.0
        if v >= 0.3 and v >= 2.0 * m or v >= 0.08 and v >= 4.0 * m + 0.02:
            if not out or ts[i] - out[-1] > 0.25:
                out.append(ts[i])
    return out


WORDCH = re.compile(r"[^\W_]", re.UNICODE)


def strength(item):
    """0 = 無視、1 = 弱い(単独なら雑音扱い)、2 = 確か"""
    n = len(WORDCH.findall(item["s"]))
    if n < 2:
        return 0
    if item["c"] >= 0.5:
        return 2
    return 1 if n >= 3 else 0


def text_samples(path):
    out = []
    for ln in open(path):
        j = json.loads(ln)
        items = [dict(i, k=strength(i)) for i in j["items"]]
        items = [i for i in items if i["k"] > 0]
        out.append({"t": j["t"], "items": items, "k": max([i["k"] for i in items], default=0)})
    return out


def text_runs(samples):
    """文字が続いている時間帯。弱い検出が1回きりのものは捨てる(別枠で返す)。"""
    runs, weak = [], []
    cur = None
    for s in samples:
        if s["k"] == 0:
            continue
        if cur and s["t"] - cur["t1"] <= JOIN:
            cur["t1"] = s["t"]
            cur["n"] += 1
            cur["k"] = max(cur["k"], s["k"])
            cur["samples"].append(s)
        else:
            cur = {"t0": s["t"], "t1": s["t"], "n": 1, "k": s["k"], "samples": [s]}
            runs.append(cur)
    keep = []
    for r in runs:
        if r["n"] == 1 and r["k"] < 2:
            weak.append(r)
        else:
            keep.append(r)
    return keep, weak


def describe(run):
    """そのかたまりで一番よく出た文字列と、文字の大きさ・位置。"""
    cnt, hmax, area = {}, 0.0, 0.0
    ys = []
    for s in run["samples"]:
        a = 0.0
        for i in s["items"]:
            cnt[i["s"]] = cnt.get(i["s"], 0) + i["k"]
            hmax = max(hmax, i["h"])
            a += i["w"] * i["h"]
            ys.append(i["y"] + i["h"] / 2)
        area = max(area, a)
    top = sorted(cnt.items(), key=lambda x: -x[1])[:4]
    return {"words": [w for w, _ in top], "hmax": round(hmax, 3), "area": round(area, 4),
            "ymid": round(sum(ys) / len(ys), 2) if ys else None}


def dark_ranges(ts, ys):
    """真っ暗(黒味)が DARK_MIN 秒以上続く時間帯。"""
    out, a = [], None
    for t, y in zip(ts, ys):
        if y <= DARK_Y:
            a = t if a is None else a
        elif a is not None:
            if t - a >= DARK_MIN:
                out.append([a, t])
            a = None
    if a is not None and ts[-1] - a >= DARK_MIN:
        out.append([a, ts[-1] + 1.0])
    return out


def plan(info, cutlist, runs, exact=()):
    dur = info["dur"]
    bounds = [0.0] + cutlist + [dur]
    shots = [(bounds[i], bounds[i + 1]) for i in range(len(bounds) - 1) if bounds[i + 1] - bounds[i] > 1e-3]
    rem = []
    for r in runs:
        a, b = max(0.0, r["t0"] - PAD), min(dur, r["t1"] + PAD)
        times = r.get("times")
        for s0, s1 in shots:
            if s1 <= a or s0 >= b:
                continue
            # 余白だけが隣のカットにはみ出した場合は、そのカットを巻き込まない
            if times is not None and not any(s0 <= t < s1 for t in times):
                continue
            if s1 - s0 <= SHORT_SHOT:
                rem.append([s0, s1])
            else:
                x, y = max(a, s0), min(b, s1)
                if x - s0 <= SNAP:
                    x = s0
                if s1 - y <= SNAP:
                    y = s1
                rem.append([x, y])
    rem += [[max(0.0, a), min(dur, b)] for a, b in exact]
    rem.sort()
    merged = []
    for a, b in rem:
        if merged and a <= merged[-1][1] + 1e-6:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    # 残る部分: カットの切れ目でも区切り、短すぎるものは消す
    keep = []
    pos = 0.0
    for a, b in merged + [[dur, dur]]:
        if a > pos:
            keep.append([pos, a])
        pos = max(pos, b)
    keep = [k for k in keep if k[1] - k[0] >= MIN_KEEP]
    return shots, merged, keep


def main():
    src = sys.argv[1]
    vids = videos(src)
    ids = sys.argv[2:] or list(vids)
    os.makedirs(os.path.join(WORK, "plan"), exist_ok=True)
    global OVER
    op = os.path.join(WORK, "overrides.json")
    OVER = json.load(open(op)) if os.path.exists(op) else {}
    tot = [0.0, 0.0]
    for vid in ids:
        path, title = vids[vid]
        info = probe(path)
        ts, sc = read_meta(os.path.join(WORK, "scene", vid + ".scene.txt"), "lavfi.scene_score")
        cl = cuts(ts, sc)
        samples = text_samples(os.path.join(WORK, "text", vid + ".jsonl"))
        runs, weak = text_runs(samples)
        ov = OVER.get(vid, {})
        for r in runs:
            r.update(describe(r))
            r["times"] = [x["t"] for x in r["samples"]]
            r["cls"] = "overlay" if r["area"] >= BIG else "small"
            for c in ("overlay", "small"):
                if any(a <= r["t1"] and b >= r["t0"] for a, b in ov.get(c, [])):
                    r["cls"] = c
        hit = [r for r in runs if r["cls"] == "overlay"]
        hit += [{"t0": a + PAD, "t1": b - PAD} for a, b in ov.get("remove", [])]
        yt, yv = read_meta(os.path.join(WORK, "scene", vid + ".yavg.txt"), "lavfi.signalstats.YAVG")
        dark = dark_ranges(yt, yv)
        shots, rem, keep = plan(info, cl, hit, dark + ov.get("cut", []))
        kept = sum(b - a for a, b in keep)
        tot[0] += info["dur"]
        tot[1] += kept
        out = {"id": vid, "title": title, "path": path, "info": info, "cuts": [round(c, 3) for c in cl],
               "runs": [{k: v for k, v in r.items() if k not in ("samples", "times")} for r in runs],
               "weak": [dict(t0=r["t0"], **describe(r)) for r in weak],
               "dark": [[round(a, 3), round(b, 3)] for a, b in dark],
               "remove": [[round(a, 3), round(b, 3)] for a, b in rem],
               "keep": [[round(a, 3), round(b, 3)] for a, b in keep]}
        json.dump(out, open(os.path.join(WORK, "plan", vid + ".json"), "w"), ensure_ascii=False, indent=1)
        print("%s %-30s %6.0fs カット%4d 載せた文字%3d 写り込み%3d(弱%2d) 残す %6.0fs (%3.0f%%) %d区間" % (
            vid, title[:30], info["dur"], len(shots), sum(r["cls"] == "overlay" for r in runs),
            sum(r["cls"] == "small" for r in runs), len(weak), kept, 100 * kept / info["dur"], len(keep)))
    print("合計 %.0fs → 残す %.0fs (%.0f%%)" % (tot[0], tot[1], 100 * tot[1] / max(tot[0], 1)))


if __name__ == "__main__":
    main()
