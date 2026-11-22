"""scan.py の結果から、ドローン向きの区間・拍のある区間・単発の打撃音の候補を一覧にする。usage: pick.py 走査結果フォルダ"""
import json
import os
import sys

PC = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
d = sys.argv[1]
for fn in sorted(os.listdir(d)):
    r = json.load(open(os.path.join(d, fn)))
    vid = fn[:-5]
    print("=== %s %s (%d:%02d)" % (vid, r["name"][:40], r["dur"] // 60, r["dur"] % 60))
    # 音量の目安: 窓の上位4分の1
    dbs = sorted(w["db"] for w in r["wins"])
    hi = dbs[int(len(dbs) * 0.75)] if dbs else -90
    # ドローン: 立上りが少なく、和音の姿が安定した窓の連なり
    runs, cur = [], []
    for w in r["wins"]:
        good = w["onsets"] <= 1 and w["stab"] > 0.93 and w["db"] > hi - 14 and w["db_sd"] < 4
        if good:
            cur.append(w)
        else:
            if len(cur) >= 3:
                runs.append(cur)
            cur = []
    if len(cur) >= 3:
        runs.append(cur)
    runs.sort(key=lambda c: -len(c) * (sum(w["conc"] for w in c) / len(c)))
    for c in runs[:4]:
        pcs = {}
        for w in c:
            pcs[w["pc"]] = pcs.get(w["pc"], 0) + 1
        top = sorted(pcs.items(), key=lambda x: -x[1])[:2]
        print("  drone %6.1f-%6.1fs len %3ds | %5.1fdB | conc %.2f flat %.3f cent %4d low %.2f | %s" % (
            c[0]["t"], c[-1]["t"] + 4, c[-1]["t"] + 4 - c[0]["t"], sum(w["db"] for w in c) / len(c),
            sum(w["conc"] for w in c) / len(c), sum(w["flat"] for w in c) / len(c),
            sum(w["cent"] for w in c) / len(c), sum(w["low"] for w in c) / len(c),
            " ".join("%s×%d" % (PC[p], n) for p, n in top)))
    for x in sorted(r["rhythm"], key=lambda x: -x["clar"])[:3]:
        print("  beat  @%6.1fs %5.1fbpm clar %.2f onsets %d %.0fdB" % (x["t"], x["bpm"], x["clar"], x["onsets"], x["db"]))
    hits = [o for o in r["onsets"] if o["peak_db"] - o["pre_db"] > 10 and o["peak_db"] > hi - 6 and o["gap"] > 0.12]
    k = [o for o in hits if o["low"] > 0.45 or o["cent"] < 350]
    s = [o for o in hits if 900 < o["cent"] < 3800 and o["low"] < 0.3]
    h = [o for o in hits if o["cent"] >= 3800]
    print("  hits  %d (低 %d / 中 %d / 高 %d)" % (len(hits), len(k), len(s), len(h)))
