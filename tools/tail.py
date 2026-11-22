#!/usr/bin/env python3
"""最後の一打のあとに、残響から立ち上がる 1 分のアンビエントを足す(Live で開いているセットに対して)。

  python3 tail.py            何度実行してもよい(ノートは同じ位置なら置き換え、オートメーションは書き直し)

やること:
  1. 余韻専用のリターン(4 本目、長いリバーブ)を作る。曲のほかの部分には送らない
  2. 最後の一打(KIT)だけを、そのリターンへ大きく送る
  3. 冒頭のドローン(SUB / GLASS / ORBIS / CHORD / AIR)を、一打の直後から同じリバーブ越しに立ち上げ、
     高い音から順に引いて 1 分で消す
音は作らない。置くのは既存の音源のノートとオートメーションだけ。
"""
import math
import sys
import time

from lib import *
from song import CURVES, interp_raw

ALS = "../../orf2026_xmusiclab Project/orf2026_xmusiclab_edit_6min.als"   # 連打のノートを読む元(保存済みのファイル)
ROLL = 740.0           # 最後の連打のクリップ(740-742 拍)。ここを余韻へ送る
HIT = 742.0            # 連打が終わる位置(拍)。余韻はここから数える
TEMPO_CHANGE = 752.0   # ここから先はセットのテンポのオートメーションが 160 BPM
BPS0, BPS1 = 150 / 60.0, 160 / 60.0
TAIL_SEC = 60.0
RET = 3                # 余韻用リターンの番号(A,B,C の次)
SLOT = 1               # 作業に使うセッション側の空きスロット(使ったあと消す)
REVERB_DECAY = 30.0    # 秒
RET_VOL_DB = -3.0
HIT_SEND = 1.0         # 連打を余韻へ送る量(1.0 = 0 dB)
DRONE_SEND = 0.80      # ドローンを余韻へ送る量(0.80 = -8 dB)
TRIM_DB = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0     # ドローン全体の上げ下げ(測って決めた)


def beat(sec):
    """連打の終わりからの秒 -> 拍(途中でテンポが変わる)"""
    b = HIT + sec * BPS0
    if b <= TEMPO_CHANGE:
        return b
    return TEMPO_CHANGE + (sec - (TEMPO_CHANGE - HIT) / BPS0) * BPS1


END = math.ceil(beat(TAIL_SEC) / 4) * 4      # 小節の頭に切り上げ
LATE = (748.0 - HIT) / BPS0                  # CHORD / AIR は 748 拍まで元のクリップがあるので、その後ろから

# トラック名: (クリップの開始拍, [(高さ, 開始秒, 終了秒)], [(秒, dB)] の音量の形)
#   音量は Utility の出力。立ち上がりは振幅でなめらかに、消える側は dB でまっすぐ(残響と同じ減り方)。
DRONES = {
    # ノートは、鍵を離したあとの余韻(4〜6 秒)がクリップの終わりまでに収まる位置で切る。
    # クリップの終わりを過ぎると Utility が 0 dB に戻るので、そこまで鳴っていると最後に大きく鳴ってしまう。
    "SUB":   (HIT,   [(60, 0.0, 54.5)],                    [(0.0, -60), (4.0, -8), (10.0, -5), (40.0, -5), (54.0, -14), (61.0, -60)]),
    "GLASS": (HIT,   [(60, 0.0, 48.0), (48, 4.0, 48.0)],   [(0.0, -60), (6.0, -5), (30.0, -6), (46.0, -20), (54.0, -60)]),
    "ORBIS": (HIT,   [(60, 0.0, 54.0), (53, 8.0, 54.0)],   [(0.0, -60), (8.0, -6), (36.0, -7), (52.0, -18), (60.0, -60)]),
    "CHORD": (748.0, [(60, LATE, 32.0), (55, 28.0, 53.0)], [(LATE, -60), (10.0, -7), (36.0, -8), (50.0, -20), (57.0, -60)]),
    "AIR":   (748.0, [(60, LATE, 44.0)],                   [(LATE, -60), (12.0, -9), (30.0, -9), (42.0, -24), (48.0, -60)]),
}


def shape(pts, step=0.5):
    """[(秒, dB)] を step 秒ごとの点にする。上がる区間は振幅の 2 乗カーブ、下がる区間は dB の直線。"""
    out = []
    for (t0, d0), (t1, d1) in zip(pts, pts[1:]):
        n = max(1, int(round((t1 - t0) / step)))
        for k in range(n):
            x = k / n
            if d1 > d0 and d0 <= -59:                      # 無音からの立ち上がり
                a = (x ** 2) * 10 ** (d1 / 20.0)
                d = max(-60.0, 20 * math.log10(a)) if a > 0 else -60.0
            else:
                d = d0 + (d1 - d0) * x
            out.append((t0 + (t1 - t0) * x, d))
    out.append(pts[-1])
    return out


def util_raw(db):
    return interp_raw(CURVES["utility"], -70 if db <= -59.9 else db + TRIM_DB)


def arr_clips(t):
    c = ok(q("get_arrangement_clips", {"track_index": t}))
    return c.get("clips", c)


def clip_at(t, start):
    for i, c in enumerate(arr_clips(t)):
        if abs(c["start_time"] - start) < 1e-6:
            return i, c
    return None, None


def place(t, start, length, notes, envs):
    """セッション側の空きスロットにクリップを作り、ノートとオートメーションを書いてから、アレンジメントの start に置く。
    (アレンジメント上のクリップには API からオートメーションを書けないため)
    envs = [(target の指定, [[拍, 値], ...], 補間するか)]。拍はクリップの頭から。"""
    q("delete_clip", {"track_index": t, "clip_index": SLOT})        # 前回の残りがあれば消す(無ければ失敗するだけ)
    ok(q("create_clip", {"track_index": t, "clip_index": SLOT, "length": float(length)}))
    ok(q("set_clip_name", {"track_index": t, "clip_index": SLOT, "name": "tail"}))
    ok(q("add_notes_to_clip", {"track_index": t, "clip_index": SLOT, "notes": notes}))
    for target, points, interp in envs:
        # write_automation は点と点の間を 0.25 拍の段で埋める。間隔が 0.25 の倍数でないと端数が埋まらず、
        # そこだけ元の値(0 dB など)に跳ねる。0.5 秒おきの「ザク」の原因だったので、ここで必ず確かめる。
        for (t0, _), (t1, _) in zip(points, points[1:]):
            assert abs((t1 - t0) / 0.25 - round((t1 - t0) / 0.25)) < 1e-6, "点の間隔が 0.25 拍の倍数でない: %s %s" % (t0, t1)
        last = float(length) - points[-1][0]      # 最後の点はクリップの終わりまで伸ばす
        p = {"track_index": t, "clip_index": SLOT, "points": points, "interpolate": interp, "resolution": 0.25, "tail": last}
        p.update(target)
        ok(q("write_automation", p))
    ok(q("duplicate_session_clip_to_arrangement", {"track_index": t, "clip_index": SLOT, "destination_time": float(start)}))
    ok(q("delete_clip", {"track_index": t, "clip_index": SLOT}))


def flat(v, length=None):
    return [[0.0, v]]              # 1 点だけ。place() がクリップの終わりまで伸ばす


def sec(b):
    """拍 -> 連打の終わりからの秒(beat() の逆)"""
    if b <= TEMPO_CHANGE:
        return (b - HIT) / BPS0
    return (TEMPO_CHANGE - HIT) / BPS0 + (b - TEMPO_CHANGE) / BPS1


def env_db(curve, s):
    """shape() の結果 [(秒, dB)] を、秒 s で読む(範囲の外は無音)"""
    if s <= curve[0][0] or s >= curve[-1][0]:
        return -60.0
    for (t0, d0), (t1, d1) in zip(curve, curve[1:]):
        if t0 <= s <= t1:
            return d0 + (d1 - d0) * (s - t0) / (t1 - t0 if t1 > t0 else 1)
    return -60.0


def roll_notes():
    """保存済みのファイルから、最後の連打(ROLL から 2 拍)で実際に鳴るノートを読む。"""
    import gzip
    import xml.etree.ElementTree as ET
    ls = ET.fromstring(gzip.open(ALS).read()).find("LiveSet")
    out = {}
    for ti, t in enumerate(ls.find("Tracks")):
        if t.find("Name/EffectiveName").attrib["Value"] != "KIT":
            continue
        for c in t.findall(".//ArrangerAutomation/Events/*"):
            s0 = float(c.find("CurrentStart").attrib["Value"])
            if abs(s0 - ROLL) > 1e-6:
                continue
            e0 = float(c.find("CurrentEnd").attrib["Value"])
            off = float(c.find("Loop/LoopStart").attrib["Value"]) + float(c.find("Loop/StartRelative").attrib["Value"])
            notes = []
            for k in c.findall("Notes/KeyTracks/KeyTrack"):
                pitch = int(k.find("MidiKey").attrib["Value"])
                for n in k.find("Notes"):
                    at = float(n.attrib["Time"]) - off
                    if 0 <= at < e0 - s0:
                        notes.append({"pitch": pitch, "start_time": at, "duration": float(n.attrib["Duration"]),
                                      "velocity": float(n.attrib["Velocity"]), "mute": False})
            out[ti] = (e0 - s0, notes)
    return out


def main():
    ns = names()
    info = ok(q("get_session_info"))
    print("余韻の終わり: %g 拍(小節 %d の頭)" % (END, END / 4 + 1))

    # 1. 余韻用のリターン
    if info["return_track_count"] <= RET:
        ok(q("create_return_track", {}))
        load_path(RET, "audio_effects/Reverb", kind="return")
    setp(RET, 0, {"Decay Time": math.log(REVERB_DECAY / 0.2) / math.log(300), "Dry/Wet": 1.0,
                  "In Lo Cut On": 1, "Density": 3, "Diffusion": 0.85, "Scale": 0.6,
                  "HiShelf Gain": 0.45, "Chorus Amount": 0.2, "Chorus Rate": 0.3}, kind="return")
    # 原因の切り分けで足した 2 台目のリバーブが残っていれば切る(API からは消せない。Live 上で削除してよい)
    if q("get_device_parameters_ex", {"track_index": RET, "kind": "return", "device_index": 1}).get("status") == "success":
        setp(RET, 1, {"Device On": 0}, kind="return")
    ok(q("set_mixer", {"track_index": RET, "kind": "return", "volume": interp_raw(CURVES["volume"], RET_VOL_DB)}))
    rp = params(RET, 0, kind="return")
    print("リバーブ:", {k: rp[k]["display"] for k in ("Decay Time", "Dry/Wet", "In Lo Cut On", "Density", "Diffusion", "Scale", "HiShelf Gain", "Chorus Amount")})

    # 2. 最後の連打(2 拍)だけを余韻へ送る。同じノートのクリップに置き換え、送りのオートメーションを付ける。
    #    その区間でもともと動いているパラメータは、いまの値のまま書いておく(置き換えで値が変わらないように)。
    done = False
    for t, (length, notes) in roll_notes().items():
        if ns[t] != "KIT" or ok(q("get_track_info", {"track_index": t}))["mute"] or not notes:
            continue
        ci, c = clip_at(t, ROLL)
        if ci is None:
            continue
        ok(q("set_current_song_time", {"time": ROLL + 1.0}))
        time.sleep(0.5)
        devs = devices(t)
        fi, ui = devs.index("Auto Filter"), devs.index("Utility")
        fp, up = params(t, fi)["Frequency"], params(t, ui)["Output"]
        snd = ok(q("get_session_snapshot", {"include_notes": False}))["tracks"][t]["sends"]
        envs = [({"target": "send", "send_index": RET}, flat(HIT_SEND, length), False),
                ({"device_index": fi, "parameter_index": fp["index"]}, flat(fp["value"], length), False),
                ({"device_index": ui, "parameter_index": up["index"]}, flat(up["value"], length), False)]
        for i, sv in enumerate(snd):
            if i != RET:
                envs.append(({"target": "send", "send_index": i}, flat(sv["value"], length), False))
        place(t, ROLL, length, notes, envs)
        print("連打を余韻へ送る: トラック %d KIT  ノート %d  (フィルタ %s, 出力 %s のまま)" % (t, len(notes), fp["display"], up["display"]))
        done = True
    if not done:
        raise SystemExit("最後の連打のクリップが見つからない")

    # 3. ドローン
    for name, (start, notes, env) in DRONES.items():
        t = ns.index(name)
        length = END - start
        ut = devices(t).index("Utility")
        pidx = params(t, ut)["Output"]["index"]
        curve = shape(env)
        pts = [[float(k), util_raw(env_db(curve, sec(start + k)))] for k in range(int(length))]   # 1 拍ごと(0.25 の倍数)
        nts = [{"pitch": p, "start_time": beat(a) - start, "duration": beat(b) - beat(a), "velocity": 100.0, "mute": False} for p, a, b in notes]
        place(t, start, length, nts, [({"device_index": ut, "parameter_index": pidx}, pts, True),
                                      ({"target": "send", "send_index": RET}, flat(DRONE_SEND, length), False)])
        print("%-6s クリップ %g-%g  ノート %d  音量の点 %d" % (name, start, END, len(notes), len(pts)))

    # 4. ループの範囲を余韻の終わりまで広げ、再生位置を頭に戻す
    r = ok(q("set_song_props", {"loop_start": 0.0, "loop_length": float(END)}))
    ok(q("set_current_song_time", {"time": 0.0}))
    print("ループ: 0 - %g 拍 / 全体 %.1f 秒" % (r["loop_length"], HIT / BPS0 + TAIL_SEC))


if __name__ == "__main__":
    main()
