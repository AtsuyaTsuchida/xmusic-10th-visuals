#!/usr/bin/env python3
"""x-Music Lab の作品音声の断片だけで、ドローンからブレイクビーツへ移り変わる曲を Live 上に組み立てる。

usage: song.py all | returns | master | TRACK [TRACK ...] | mix | locators | clean
音はすべて cut.py が切り出した断片(加工なし)を Live の Simpler / Drum Rack で鳴らし、
音程・伸縮・フィルタ・トレモロ・残響などの加工は Live のデバイスで行う。ここでは音を作らない。
"""
import json
import math
import os
import random
import sys
import time

from lib import *

BPM = 150
BARS = 188
END = BARS * 4
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 音作りの版。XMC_STYLE=v1 で最初の版(ビート控えめ、断片は短く切ったまま、深いトレモロ)を同じ5分構成で組む
# v3 は v2 の音作りのまま、ビートを四つ打ち寄りにしたもの(変わるのは KIT の音符だけ)。XMC_STYLE=v2 で前の版に戻せる
STYLE = os.environ.get("XMC_STYLE", "v7")
V1 = STYLE == "v1"
V3 = STYLE == "v3"
# v4 はジューク/フットワークのビート(KIT と LOOPS の音符が変わる。テンポは 150 のまま)。XMC_STYLE=v4 で組む
V4 = STYLE == "v4"
# v5 は構成ごと変える: 97–128 ジューク / 129–172 テクノの四つ打ち / 173–186 キックが詰まっていく / 187 の頭で一打して終わる。
# 引き・ほどける部分はない。全トラックを組み直す(song.py の既定)
# v6 は v5 と同じ構成で、KIT のキックだけ変える: キックは全部 kick_4 + snare_1 の重ね、
# ビートのある小節にはキックを必ず2つ以上入れる(song.py の既定)
# v7 は v6 を 7 分に伸ばしたもの(song.py の既定)。v6 の音符と自動化をそのまま作ってから、
# 下の INSERTS の位置に「直前の小節のくり返し」を差し込む(合計 75 小節)。最後の一打は 262 小節目の頭(6:57.6)
V7 = STYLE == "v7"
V6 = STYLE in ("v6", "v7")
V5 = STYLE in ("v5", "v6", "v7")
# (何小節目のあとに, 何小節ぶん)。差し込むのは、その直前の同じ小節数のくり返し。v6 の小節番号で書く。
# 区間ごとの段階(8小節のまとまり)を1回ずつ多く鳴らす形: ドローン 32→48 / うごめき 32→48 / ハーフタイム 32→48 /
# ジューク 32→48 / 四つ打ち 44→52 / 詰め 14→17。盛り上げの音や連打の切り替えがある小節の境目は避けてある
INSERTS = [(16, 8), (24, 8), (48, 8), (56, 8), (80, 8), (88, 8), (104, 8), (120, 8), (152, 8), (180, 3)] if V7 else []
JUKE = V4 or V5
FIN = 343               # v5: 最後の一打の小節(実際の 187 小節目)。B() の中の番号
MAN = json.load(open(os.path.join(ROOT, "work", "manifest_v1.json" if V1 else "manifest.json")))
GD = 0.95 if V1 else 0.5            # ブレイク部での GLASS のトレモロの深さ
OD = -13 if V1 else -9              # ブレイク部での ORBIS の音量
KH = 0.06 if V1 else 0.14           # ブレイク部でのキットの残響送り
LBAR, LHALF, LQ = (3.95, 1.95, 0.98) if V1 else (4.06, 2.05, 1.04)   # ループの音符の長さ(v2 は少し重ねる)
M = {e["name"]: e for k in MAN for e in MAN[k]}
RATE = {"1/4": 12, "3/16": 13, "1/8": 15, "1/16": 17, "1/32": 19}
HALL, ECHO, GRAIN = 0, 1, 2


def B(b):
    """小節番号(1始まり) -> 拍。v2 で 5 分に伸ばしたときの対応:
    1–144 はそのまま / 201–216 は新しい区間(実際の 145–160: 引き→最後の山) /
    145–156 は実際の 161–172 / 157–169 は実際の 173–189 に引き伸ばす(ほどける部分)。
    v5: 1–144 はそのまま / 301 以降が実際の 145 小節目以降 / 145–216(v2 までの終盤)は曲の外へ飛ばして使わない。"""
    if V5:
        if b >= 301:
            return (b - 301 + 144) * 4.0
        if b >= 145:
            return 1e6 + b * 4.0
        return (b - 1) * 4.0
    if b >= 201:
        return (b - 201 + 144) * 4.0
    if b >= 157:
        return (172 + (b - 157) * 4.0 / 3.0) * 4.0
    if b >= 145:
        return (b - 1 + 16) * 4.0
    return (b - 1) * 4.0


def X(a):               # v5: 実際の小節番号 -> B() に渡す番号
    return a + 156 if a >= 145 else a


def v5pts(points, tail=()):
    """v5: 曲の外へ飛ばした点を捨て、最後の値を保ったまま tail [(拍, 値)] を足して終わりまで伸ばす。"""
    pts = sorted([[b, v] for b, v in points if b < END - 0.3], key=lambda x: x[0])
    for b, v in tail:
        pts.append([b, pts[-1][1] if v is None else v])
    if pts[-1][0] < END - 0.3:
        pts.append([END - 0.25, pts[-1][1]])
    return pts


END_OUT = END + 4 * sum(n for _, n in INSERTS)          # 伸ばしたあとの曲の長さ(拍)


def xt(b):              # v7: 伸ばす前の位置(拍) -> 伸ばしたあとの位置。差し込みの境目ちょうどは後ろへ送る
    return b + sum(n * 4 for a, n in INSERTS if b >= a * 4 - 1e-6)


def stretch_notes(notes):
    """v7: 音符を伸ばしたあとの位置へ移し、差し込む区間には直前の小節の音符をくり返して置く。
    境目をまたいで鳴り続ける長い音(ドローンなど)は、差し込んだぶんだけ長くする。"""
    out = []
    for p, s0, d, v in notes:
        e = s0 + d
        ns = xt(s0)
        ne = e + sum(n * 4 for a, n in INSERTS if e > a * 4 + 0.3)      # 0.3 拍までのはみ出しは「境目で終わる音」とみなす
        out.append((p, ns, max(ne - ns, min(d, 0.05)), v))
        for a, n in INSERTS:
            pb, ln = a * 4, n * 4
            if pb - ln - 1e-6 <= s0 < pb - 1e-6 and e <= pb + 0.3:      # くり返す区間の中に収まる音だけ写す
                out.append((p, ns + ln, d, v))
    return out


def stretch_points(points, step=False):
    """v7: 自動化の点を伸ばしたあとの位置へ移す。差し込む区間の間は、境目の直前の値のまま保つ。"""
    pts = sorted([[b, v] for b, v in points], key=lambda x: x[0])
    if not pts:
        return pts

    def before(b):
        prev = [q_ for q_ in pts if q_[0] < b - 1e-6]
        nxt = [q_ for q_ in pts if q_[0] >= b - 1e-6]
        if not prev:
            return nxt[0][1]
        if step or not nxt:
            return prev[-1][1]
        (b0, v0), (b1, v1) = prev[-1], nxt[0]
        return v0 + (v1 - v0) * (b - b0) / (b1 - b0) if b1 > b0 else v0

    out = [[xt(b), v] for b, v in pts]
    for a, n in INSERTS:
        pb = a * 4
        if pts[0][0] < pb - 1e-6 and pts[-1][0] >= pb - 1e-6:
            base = pb + sum(m * 4 for a2, m in INSERTS if a2 < a)
            v = before(pb)
            out += [[base, v], [base + n * 4 - 0.01, v]]
    out.sort(key=lambda x: x[0])
    return out


def st(bar, step):      # 小節内の16分ステップ -> 拍
    return B(bar) + step * 0.25


def fr(f):              # Auto Filter / Echo の周波数 -> 生値 (20Hz..20kHz の対数)
    return max(0.0, min(1.0, math.log10(f / 20.0) / 3.0))


# ---------------------------------------------------------------- 共通の道具
def song_clip(t, name):
    ok(q("create_clip", {"track_index": t, "clip_index": 0, "length": float(END_OUT)}))
    ok(q("set_clip_name", {"track_index": t, "clip_index": 0, "name": name}))
    return 0


def commit(t):
    ok(q("duplicate_session_clip_to_arrangement", {"track_index": t, "clip_index": 0, "destination_time": 0.0}))


def add_notes(t, c, notes):
    notes = [n for n in notes if 0 <= n[1] < END]
    if V5:              # 最後の一打より前の音符は、一打の位置で切る
        F = B(FIN)
        notes = [(p, s0, min(d, F - s0) if s0 < F else min(d, END - s0), v) for p, s0, d, v in notes]
    if V7:
        notes = stretch_notes(notes)
    for i in range(0, len(notes), 400):
        chunk = [{"pitch": int(p), "start_time": float(s), "duration": float(d),
                  "velocity": float(max(1, min(127, v))), "mute": False} for p, s, d, v in notes[i:i + 400]]
        ok(q("add_notes_to_clip", {"track_index": t, "clip_index": c, "notes": chunk}))
    return len(notes)


def env(t, c, dev, pname, points, step=False, res=1.0):
    idx = params(t, dev)[pname]["index"]
    if V5:
        points = v5pts(points)
    if V7:
        points = stretch_points(points, step)
    if step:
        pts = []
        for i, (b, v) in enumerate(points):
            pts.append([b, v])
            if i + 1 < len(points):
                pts.append([points[i + 1][0] - 0.001, v])
    else:
        pts = [[b, v] for b, v in points]
    return ok(q("write_automation", {"track_index": t, "clip_index": c, "device_index": dev,
                                     "parameter_index": idx, "points": pts,
                                     "interpolate": not step, "resolution": res}))


def env_send(t, c, send, points, res=1.0):
    if V5:              # 終わりの手前で残響への送りを絞る(一打のあと 5:00 までに響きが収まるように)
        points = v5pts(points, [(B(X(179)), None), (B(X(183)), 0.0)] if send in (HALL, GRAIN) else [])
    if V7:
        points = stretch_points(points)
    return ok(q("write_automation", {"track_index": t, "clip_index": c, "target": "send", "send_index": send,
                                     "points": [[b, v] for b, v in points], "interpolate": True, "resolution": res}))


CURVES = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "curves.json")))


def interp_raw(table, db):
    pts = [(r, d) for r, d in table if d > -1e8]
    if db <= pts[0][1]:
        return table[0][0] if db < pts[0][1] - 20 else pts[0][0]
    for (r0, d0), (r1, d1) in zip(pts, pts[1:]):
        if d0 <= db <= d1:
            return r0 + (r1 - r0) * (db - d0) / (d1 - d0 if d1 != d0 else 1)
    return pts[-1][0]


def fx(t, name, wait=1.0, kind="track"):
    load_path(t, "audio_effects/" + name, kind=kind, wait=wait)
    return (len(devices(t)) - 1) if kind == "track" else None


def utility(t):
    return fx(t, "Utility")


def fade(t, c, util, pts_db, cut=True):
    """Utility の出力を [(拍, dB)] でなぞる。-60dB 以下は無音。
    v5 で cut=True なら、最後の一打の位置から1拍で無音にする(余韻の長いドローン用)。"""
    pname = "Gain" if "Gain" in params(t, util) else "Output"
    if V5:
        pts_db = v5pts(pts_db, [(B(FIN), None), (B(FIN) + 1.0, -70)] if cut else [])
    env(t, c, util, pname, [(b, interp_raw(CURVES["utility"], d)) for b, d in pts_db], res=0.25 if V5 else 0.5)


def vol(t, db, kind="track"):
    return ok(q("set_mixer", {"track_index": t, "kind": kind, "volume": interp_raw(CURVES["volume"], db)}))


def sends(t, vals):
    ok(q("set_mixer", {"track_index": t, "sends": vals}))
    if V5:
        for i in (HALL, GRAIN):
            if vals[i] > 0:
                env_send(t, 0, i, [(0, vals[i])])


def new(name):
    return make_track(name)


def afilter(t, ftype, freq):
    d = fx(t, "Auto Filter")
    setp(t, d, {"Filter Type": ftype, "Frequency": fr(freq)})
    return d


def trem(t, rate, phase=0.5, wave=0, amount=0.0):
    d = fx(t, "Auto Pan-Tremolo")
    setp(t, d, {"Mode": 1, "Time Mode": 2, "Rate": RATE[rate], "Phase": phase, "Waveform": wave, "Amount": amount})
    return d


def raw_for(t, d, name, target, chain_path=None, iters=10):
    """表示値が target になる生値を二分探索で求める(その値に設定したまま返す)。"""
    p = params(t, d, chain_path=chain_path)[name]
    lo, hi = p["min"], p["max"]
    for _ in range(iters):
        mid = (lo + hi) / 2
        v = parse_display(setp(t, d, {name: mid}, chain_path=chain_path)[name])
        if v is None:
            break
        if v < target:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


_CACHE = {}


def simpler_time(t, name, ms, chain_path=None):
    """Simpler の時間系パラメータ(Ve Attack など)を ms で設定。写像は全 Simpler 共通なので一度だけ探す。"""
    key = (name, ms)
    if key not in _CACHE:
        _CACHE[key] = raw_for(t, 0, name, ms, chain_path)
    setp(t, 0, {name: _CACHE[key]}, chain_path=chain_path)
    return _CACHE[key]


def sampler(name, sample, vol_db, trans=0, det=0, loop=(0.8, 0.4), att=4000, rel=6000, spread=0, vel=0.0, start=0.0):
    """トラックを作り、断片を Simpler に読み込んで基本設定をする。"""
    t = new(name)
    ok(q("load_user_sample", {"track_index": t, "path": M[sample]["path"]}))
    time.sleep(2.0)
    load_glx(t, "Util")
    ut = devices(t).index("GLX Util")
    util_apply(t, ut, t, 0, "warping", 0)
    vals = {"Volume": vol_db, "Transpose": trans, "Detune": det, "Spread": spread, "Vol < Vel": vel, "S Start": start}
    if loop:
        vals.update({"S Loop On": 1, "S Loop Length": loop[0], "S Loop Fade": loop[1]})
    setp(t, 0, vals)
    simpler_time(t, "Ve Attack", att)
    simpler_time(t, "Ve Release", rel)
    return t


def rack(name, entries):
    """Drum Rack を作り、entries = [(パッド名, 断片名)] を 36 番から順に読み込む。chain の番号表を返す。"""
    t = new(name)
    load_path(t, "drums/Drum Rack", wait=1.5)
    for i, (pad, sample) in enumerate(entries):
        ok(q("load_user_sample", {"track_index": t, "device_index": 0, "path": M[sample]["path"],
                                  "drum_note": 36 + i, "pad_name": pad}))
        time.sleep(0.7)
    info = ok(q("get_device_parameters_ex", {"track_index": t, "device_index": 0}))
    chain = {c["name"]: c["index"] for c in info["chains"]}
    missing = [p for p, _ in entries if p not in chain]
    if missing:
        raise RuntimeError("pads not loaded: %s" % missing)
    return t, chain


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


# ---------------------------------------------------------------- returns / master
def build_returns():
    info = ok(q("get_session_info"))
    for i in range(info["return_track_count"] - 1, -1, -1):
        ok(q("delete_track", {"track_index": i, "kind": "return"}))
    for _ in range(3):
        ok(q("create_return_track", {}))
    # A: HALL — 長い残響
    load_path(0, "audio_effects/Reverb", kind="return")
    setp(0, 0, {"Decay Time": math.log(10 / 0.2) / math.log(300), "Dry/Wet": 1.0}, kind="return")
    load_path(0, "audio_effects/EQ Eight", kind="return", wait=1.0)
    setp(0, 1, {"1 Filter Type A": 0}, kind="return")
    setd(0, 1, {"1 Frequency A": 140}, kind="return", iters=10)
    # B: ECHO — 付点8分
    load_path(1, "audio_effects/Echo", kind="return")
    setp(1, 0, {"HP Freq": fr(300), "LP Freq": fr(4500), "Feedback": 0.38, "Dry Wet": 1.0, "Reverb Level": 0.3}, kind="return")
    # C: GRAIN — 1オクターブ上の粒 + 残響
    load_path(2, "audio_effects/Grain Delay", kind="return")
    setp(2, 0, {"Pitch": 12.0, "Spray": 0.5, "Random": 0.15, "Feedback": 0.4, "DryWet": 1.0, "Beat Delay": 3}, kind="return")
    load_path(2, "audio_effects/Reverb", kind="return")
    setp(2, 1, {"Decay Time": math.log(6 / 0.2) / math.log(300), "Dry/Wet": 0.7}, kind="return")
    vol(0, -3, "return"); vol(1, -6, "return"); vol(2, -9, "return")


def build_master():
    for name in ["EQ Eight", "Glue Compressor", "Limiter"]:
        load_path(0, "audio_effects/" + name, kind="master", wait=1.0)
    setp(0, 0, {"1 Filter Type A": 0}, kind="master")
    setd(0, 0, {"1 Frequency A": 28}, kind="master", iters=10)
    setp(0, 1, {"Ratio": 0, "Attack": 3, "Release": 6, "Dry/Wet": 1.0, "Threshold": -10.0}, kind="master")
    setd(0, 2, {"Ceiling": -0.8, "Input Gain": 3.0}, kind="master", iters=10)


# ---------------------------------------------------------------- ドローン
def t_sub():
    t = sampler("SUB", "micro_low", -9, trans=-2, det=15, loop=(0.85, 0.3), att=6000, rel=5000)
    setp(t, 0, {"Filt < Key": 0.0})
    simpler_time(t, "Filter Freq", 700)
    u = utility(t)
    c = song_clip(t, "sub")
    add_notes(t, c, [(60, 0, B(97), 100), (60, B(201), 16, 100), (60, B(145), B(166) - B(145), 100)])
    fade(t, c, u, [(0, -26), (B(5), -6), (B(33), -3), (B(65), -3), (B(89), -6), (B(97), -14),
                   (B(201), -14), (B(203), -6), (B(205), -8), (B(209), -14),
                   (B(145), -14), (B(149), -4), (B(161), -6), (B(168), -40)])
    sends(t, [0.2, 0.0, 0.0])
    commit(t)


def t_glass():
    t = sampler("GLASS", "urban_G", -12, loop=(0.7, 0.5), att=5000, rel=6000, spread=30)
    af = afilter(t, 0, 900)
    tr = trem(t, "1/8")
    u = utility(t)
    c = song_clip(t, "glass")
    add_notes(t, c, [(60, 0, B(166), 100), (48, B(17), B(97) - B(17), 100), (48, B(145), B(166) - B(145), 100)])
    env(t, c, af, "Frequency", [(0, fr(700)), (B(17), fr(5000)), (B(65), fr(9000)), (B(168), fr(9000))])
    env(t, c, tr, "Amount", [(0, 0), (B(33), 0), (B(49), 0.4 if V1 else 0.25), (B(65), 0.75 if V1 else 0.45), (B(97), GD), (B(201), GD), (B(203), 0.15), (B(208), 0.15), (B(209), GD), (B(145), GD),
                              (B(157), 0.3 if V1 else 0.2), (B(163), 0)])
    env(t, c, tr, "Rate", [(0, RATE["1/8"]), (B(65), RATE["1/16"]), (B(145), RATE["1/8"])], step=True)
    fade(t, c, u, [(0, -45), (B(3), -12), (B(9), -4), (B(33), -3), (B(65), -5), (B(97), -11 if V1 else -8), (B(129), -9 if V1 else -7), (B(201), -9 if V1 else -7), (B(203), -3), (B(208), -3), (B(209), -9 if V1 else -7),
                   (B(145), -6), (B(153), -3), (B(161), -6), (B(168), -45)])
    sends(t, [0.35, 0.1, 0.3])
    commit(t)


def t_orbis():
    t = sampler("ORBIS", "orbis_D", -10, loop=(0.8, 0.4), att=6000, rel=6000)
    tr = trem(t, "3/16")
    u = utility(t)
    c = song_clip(t, "orbis")
    add_notes(t, c, [(60, B(5), B(166) - B(5), 100), (53, B(25), B(97) - B(25), 100), (53, B(149), B(166) - B(149), 100)])
    env(t, c, tr, "Amount", [(0, 0), (B(37), 0), (B(57), 0.5 if V1 else 0.3), (B(65), 0.6 if V1 else 0.4), (B(97), 0.9 if V1 else 0.45), (B(145), 0.9 if V1 else 0.45), (B(157), 0)])
    fade(t, c, u, [(0, -45), (B(5), -45), (B(13), -5), (B(65), -5), (B(97), OD), (B(201), OD), (B(203), -4), (B(208), -4), (B(209), OD), (B(145), -10), (B(153), -4),
                   (B(161), -8), (B(168), -45)])
    sends(t, [0.3, 0.0, 0.2])
    commit(t)


def t_shimmer():
    t = sampler("SHIMMER", "orbis_C", -6, loop=(0.8, 0.4), att=5000, rel=7000)
    afilter(t, 1, 350)
    u = utility(t)
    c = song_clip(t, "shimmer")
    add_notes(t, c, [(60, B(13), B(166) - B(13), 100), (72, B(41), B(97) - B(41), 100), (72, B(149), B(162) - B(149), 100)])
    fade(t, c, u, [(0, -45), (B(13), -45), (B(21), -8), (B(65), -6), (B(97), -14), (B(201), -14), (B(203), -7), (B(208), -7), (B(209), -14), (B(145), -12), (B(153), -6),
                   (B(166), -45)])
    sends(t, [0.4, 0.15, 0.5])
    commit(t)


def t_chord():
    t = sampler("CHORD", "rhopalia_Am", -2, loop=(0.8, 0.5), att=3000, rel=4000, spread=20)
    u = utility(t)
    c = song_clip(t, "chord")
    n = [(60, B(21), B(34) - B(21), 100)]
    for k, bar in enumerate(range(33, 97, 8)):          # 8小節ごとに E-G-A-C と B-D-E-G を行き来
        n.append((60 if k % 2 == 0 else 55, B(bar), 36.0 if bar < 89 else 32.0, 100))
    n.append((60, B(201), 33.0, 100))
    n.append((60, B(145), B(166) - B(145), 100))
    add_notes(t, c, n)
    fade(t, c, u, [(0, -45), (B(21), -45), (B(29), -6), (B(65), -4), (B(89), -6), (B(97), -10), (B(201), -10), (B(203), -5), (B(208), -5), (B(209), -10), (B(145), -10),
                   (B(149), -6), (B(161), -8), (B(168), -45)])
    sends(t, [0.4, 0.2, 0.3])
    commit(t)


def t_air():
    t = sampler("AIR", "brain_air", -4, loop=(0.9, 0.3), att=6000, rel=4000)
    afilter(t, 1, 500)
    tr = trem(t, "1/16")
    u = utility(t)
    c = song_clip(t, "air")
    add_notes(t, c, [(60, B(9), B(97) - B(9), 100), (60, B(201), 32, 100), (60, B(145), B(163) - B(145), 100)])
    env(t, c, tr, "Amount", [(0, 0), (B(45), 0), (B(65), 0.85 if V1 else 0.45), (B(97), 0.85 if V1 else 0.45), (B(101), 0)])
    fade(t, c, u, [(0, -45), (B(9), -45), (B(17), -8), (B(49), -5), (B(89), -5), (B(97), -30), (B(201), -30), (B(203), -10), (B(208), -10), (B(209), -30), (B(145), -12),
                   (B(161), -45)])
    sends(t, [0.3, 0.1, 0.2])
    commit(t)


def t_noise():
    # ノイズを16分のトレモロ(のこぎり下降)で刻むと、ハイハットのような脈になる
    t = sampler("NOISE", "trans_noise", 4, loop=(0.9, 0.2), att=50, rel=200)
    af = afilter(t, 1, 6000)
    tr = trem(t, "1/16", phase=0.0, wave=4, amount=1.0)
    u = utility(t)
    c = song_clip(t, "noise")
    add_notes(t, c, [(60, B(41), B(157) - B(41), 100)])
    env(t, c, af, "Frequency", [(0, fr(6000)), (B(65), fr(4500)), (B(97), fr(3500)), (B(145), fr(3500)), (B(157), fr(9000))])
    r16, r32 = RATE["1/16"], RATE["1/32"]
    env(t, c, tr, "Rate", [(0, r16), (B(112) + 2, r32), (B(113), r16), (B(128) + 2, r32), (B(129), r16),
                            (B(136) + 2, r32), (B(137), r16), (B(144), r32), (B(201), r16), (B(216), r32), (B(145), r16)]
        + ([(B(301), r16), (B(X(160)) + 2, r32), (B(X(161)), r16), (B(X(185)), r32)] if V5 else []), step=True)
    fade(t, c, u, [(0, -50), (B(41), -50), (B(57), -24), (B(65), -18), (B(97), -11), (B(145), -13), (B(157), -50)])
    sends(t, [0.05, 0.1, 0.0])
    commit(t)


def t_roar():
    t = sampler("ROAR", "intona_roar", -4, loop=None, att=20, rel=1500)
    af = afilter(t, 1, 1500)
    u = utility(t)
    c = song_clip(t, "roar")
    add_notes(t, c, [(60, B(93), 16, 100), (60, B(125), 16, 100),
                     (72, B(97), 4, 100), (72, B(113), 4, 100), (72, B(129), 4, 100), (72, B(145), 8, 100),
                     (72, B(201), 4, 100), (60, B(205), 16, 100), (72, B(209), 4, 100)]
              + ([(72, B(X(145)), 4, 100), (72, B(X(161)), 4, 100), (60, B(X(169)), 16, 100), (72, B(X(173)), 4, 100),
                  (60, B(X(183)), 16, 100), (72, B(FIN), 2, 110)] if V5 else []))
    e = 0.05
    v5f = [(B(X(168)), fr(1500)), (B(X(169)), fr(4000)), (B(X(173)) - e, fr(150)), (B(X(173)), fr(1500)),
           (B(X(182)), fr(1500)), (B(X(183)), fr(4000)), (B(FIN) - e, fr(150)), (B(FIN), fr(1500))] if V5 else []
    v5g = [(B(X(168)), -12), (B(X(169)), -30), (B(X(173)) - e, -5), (B(X(173)), -12),
           (B(X(182)), -12), (B(X(183)), -30), (B(FIN) - e, -4), (B(FIN), -3)] if V5 else []
    env(t, c, af, "Frequency", [(0, fr(4000)), (B(93), fr(4000)), (B(97) - e, fr(150)), (B(97), fr(1500)),
                                 (B(125), fr(4000)), (B(129) - e, fr(150)), (B(129), fr(1500)),
                                 (B(201), fr(1500)), (B(205), fr(4000)), (B(209) - e, fr(150)), (B(209), fr(1500)), (B(145), fr(900))] + v5f, res=0.25)
    fade(t, c, u, [(0, -30), (B(93), -30), (B(97) - e, -5), (B(97), -12), (B(101), -12), (B(113), -12), (B(117), -14),
                   (B(125), -30), (B(129) - e, -5), (B(129), -12),
                   (B(201), -11), (B(205), -30), (B(209) - e, -5), (B(209), -12), (B(145), -10), (B(147), -14)] + v5g, cut=False)
    sends(t, [0.35, 0.2, 0.0])
    commit(t)


# ---------------------------------------------------------------- GRAINS: 粒(16パッド)
def grain_notes():
    rng = random.Random(21)
    n = []
    for bar in list(range(9, 145)) + (list(range(301, FIN)) if V5 else list(range(201, 217)) + list(range(145, 165))):
        if bar >= 201:
            p, quant, v0 = 0.25, 1.0, 78
        elif bar < 33:
            p, quant, v0 = 0.012 + 0.03 * (bar - 9) / 24.0, 0.0, 50
        elif bar < 65:
            f = (bar - 33) / 32.0
            p, quant, v0 = 0.04 + 0.12 * f, f, 60
        elif bar < 97:
            p, quant, v0 = 0.17, 1.0, 70
        elif bar < 145:
            p, quant, v0 = 0.25, 1.0, 78
        else:
            f = (bar - 145) / 20.0
            p, quant, v0 = 0.2 * (1 - f) + 0.01, 1 - f, 60
        for i in range(16):
            if quant == 1.0 and i in (0, 4, 8, 12):
                continue                                   # 拍の頭はキットに譲る
            if rng.random() < p:
                pos = st(bar, i) if rng.random() < quant else B(bar) + rng.random() * 4
                n.append((36 + rng.randrange(16), pos, 0.2, v0 + rng.randint(-25, 30)))
        if (97 <= bar < 145 or bar >= 201) and bar % 4 == 0:   # 4小節の終わりに連打
            pad = 36 + rng.randrange(16)
            div = rng.choice([0.125, 1 / 6.0, 0.0625])
            k = int(round(1.0 / div))
            for j in range(k):
                n.append((pad, B(bar) + 3 + j * div, div * 0.8, 40 + int(70 * j / k)))
    return n


def t_grains():
    entries = [(e["name"], e["name"]) for e in MAN["grains"]]
    t, chain = rack("GRAINS", entries)
    for name, _ in entries:
        cp = [[chain[name], 0]]
        setp(t, 0, {"Volume": clamp(-10 - M[name]["peak_db"], -24, 22), "Pan < Rnd": 0.7}, chain_path=cp)
        d = M[name]["dur"]
        if not V1:
            simpler_time(t, "Fade Out", 250 if d > 0.5 else (120 if d > 0.25 else 50), cp)
    u = utility(t)
    c = song_clip(t, "grains")
    print("  grain notes", add_notes(t, c, grain_notes()))
    fade(t, c, u, [(0, -8), (B(65), -6), (B(97), -7), (B(145), -6), (B(165), -12)], cut=False)
    sends(t, [0.7, 0.3, 0.15])
    env_send(t, c, HALL, [(0, 0.75), (B(65), 0.5), (B(97), 0.2), (B(145), 0.3), (B(160), 0.8)])
    commit(t)


# ---------------------------------------------------------------- LOOPS: 1小節ループ(並べ替え用)
DRUM0, TOPS0, ROOM0, BRAIN0, AQUA0 = 36, 52, 56, 60, 62


def loop_notes():
    rng = random.Random(57)
    n = []
    for bar in range(41, 65):                               # B: 低く濾したループが脈を作りはじめる
        n.append((BRAIN0 + bar % 2, B(bar), LBAR, 50 + int(40 * (bar - 41) / 24.0)))
    for bar in range(49, 81):
        n.append((AQUA0 + bar % 2, B(bar), LBAR, 60 + min(35, bar - 49)))
    for bar in list(range(57, 145)) + (list(range(301, FIN)) if V5 else list(range(201, 217)) + list(range(145, 157))):   # tops
        if bar >= 201:
            v = 100
        elif bar < 65:
            v = 40 + 5 * (bar - 57)
        elif bar < 97:
            v = 84
        elif bar < 145:
            v = 100
        else:
            v = 96 - 6 * (bar - 145)
        if 113 <= bar < 129:                                # D2: 半小節ごとに入れ替える
            for h in range(2):
                n.append((TOPS0 + rng.randrange(4), B(bar) + 2 * h, LHALF, v))
        else:
            n.append((TOPS0 + (bar - 57) % 4, B(bar), LBAR, v))
    for bar in list(range(73, 97)) + list(range(113, 129)) + list(range(201, 209)):
        n.append((ROOM0 + (bar - 73) % 4, B(bar), LBAR, 86))

    def sl(b, qd):                                          # ドラムループ b 小節目の qd 拍目の断片
        return DRUM0 + 4 * b + qd

    for bar in range(81, 97):                               # C: 1拍目と3拍目だけ
        b = (bar - 81) % 4
        n.append((sl(b, 0), B(bar), LQ, 84))
        n.append((sl(b, 2), B(bar) + 2, LQ, 80))
        if bar >= 89:
            n.append((sl(b, 3), B(bar) + 3, LQ, 70))

    JG = [(0, 0), (3, 1), (6, 2), (8, 2), (11, 3), (14, 3), (16, 0)]   # v4: (16分ステップ, 拍の断片)。3-3-2 を2回

    def jgrid(bar, pick, v, stutter=False):
        for (s0, qd), (s1, _) in zip(JG, JG[1:]):
            if stutter and s0 >= 11:                        # 4小節の終わり: 最後の1拍は3連で6回
                if s0 == 11:
                    n.append((pick(qd), st(bar, 11), 0.27, v))
                    pt = pick(qd)
                    for j in range(6):
                        n.append((pt, B(bar) + 3 + j / 6.0, 0.15, v - 14 + 4 * j))
                continue
            n.append((pick(qd), st(bar, s0), (s1 - s0) * 0.25 + 0.04, v))

    def in_order(bar, v=100):
        b = (bar - 97) % 4
        if JUKE:
            return jgrid(bar, lambda qd: sl(b, qd), v)
        for qd in range(4):
            n.append((sl(b, qd), B(bar) + qd, LQ, v))

    def rearranged(bar, v=100):
        if JUKE:
            return jgrid(bar, lambda qd: sl(rng.randrange(4), qd if qd == 0 else rng.randrange(4)), v, stutter=bar % 4 == 0)
        for beat in range(4):
            b, qd = rng.randrange(4), (0 if beat == 0 else rng.randrange(4))
            r = rng.random()
            last = bar % 4 == 0 and beat == 3
            if last or (V1 and r < 0.15):                   # 16分で4回(v2 は4小節の終わりだけ)
                for j in range(4):
                    n.append((sl(b, qd), B(bar) + beat + j * 0.25, 0.23, v - 10 + 6 * j))
            elif r < (0.45 if V1 else 0.2):                 # 8分で2回
                for j in range(2):
                    n.append((sl(b, qd), B(bar) + beat + j * 0.5, 0.48, v))
            else:
                n.append((sl(b, qd), B(bar) + beat, LQ, v))

    if V5:                                                  # v5: ドラムの断片はジュークの部分だけ。四つ打ちからは鳴らさない
        for bar in range(97, 113):
            in_order(bar)
        for bar in range(113, 129):
            in_order(bar) if bar % 2 else rearranged(bar)
        return n
    for bar in range(97, 113):
        in_order(bar)
    for bar in range(113, 129):
        rearranged(bar)
    for bar in range(129, 145):
        in_order(bar) if bar % 2 else rearranged(bar)
    for bar in range(201, 209):                             # 引き: 1拍目と3拍目だけ
        b = (bar - 201) % 4
        n.append((sl(b, 0), B(bar), LQ, 88))
        n.append((sl(b, 2), B(bar) + 2, LQ, 84))
        if bar >= 205:
            n.append((sl(b, 3), B(bar) + 3, LQ, 76))
    for bar in range(209, 217):                             # 最後の山
        in_order(bar) if bar % 2 else rearranged(bar)
    for bar in range(145, 153):
        b = (bar - 145) % 4
        n.append((sl(b, 0), B(bar), LQ, 90 - 6 * (bar - 145)))
        if bar < 149:
            n.append((sl(b, 2), B(bar) + 2, LQ, 80))
    return n


def t_loops():
    entries, conf = [], {}
    for b in range(4):
        e = M["drum_%d" % (b + 1)]
        barlen = 240.0 / e["src_bpm"]
        for qd in range(4):
            pad = "drum_%d_q%d" % (b + 1, qd + 1)
            entries.append((pad, e["name"]))
            conf[pad] = (e, qd * 0.25 * barlen / e["dur"])
    for g in ("tops", "room", "brain", "aqua"):
        for e in MAN["loops"]:
            if e["group"] == g:
                entries.append((e["name"], e["name"]))
                conf[e["name"]] = (e, 0.0)
    assert entries[TOPS0 - 36][0] == "tops_1" and entries[ROOM0 - 36][0] == "room_1"
    assert entries[BRAIN0 - 36][0] == "brain_1" and entries[AQUA0 - 36][0] == "aqua_1"
    t, chain = rack("LOOPS", entries)
    fo = None
    for pad, _ in entries:
        e, start = conf[pad]
        semis = 12 * math.log2(BPM / e["src_bpm"])           # 元テンポ -> 150 に合わせる移調
        tr = int(round(semis))
        cp = [[chain[pad], 0]]
        setp(t, 0, {"Trigger Mode": 1, "Volume": clamp(-20 - e["rms_db"], -20, 18), "Transpose": tr,
                    "Detune": clamp((semis - tr) * 100, -50, 50), "S Start": start}, chain_path=cp)
        simpler_time(t, "Fade Out", 15 if V1 else 35, cp)
        if not V1:
            simpler_time(t, "Fade In", 4, cp)
    af = afilter(t, 0, 250)
    u = utility(t)
    c = song_clip(t, "loops")
    print("  loop notes", add_notes(t, c, loop_notes()))
    env(t, c, af, "Frequency", [(0, fr(250)), (B(41), fr(250)), (B(65), fr(1800)), (B(89), fr(6000)), (B(97), fr(18000)),
                                 (B(145), fr(18000)), (B(157), fr(400))])
    fade(t, c, u, [(0, -16), (B(41), -16), (B(65), -9), (B(97), -6), (B(145), -6), (B(157), -18)], cut=False)
    sends(t, [0.6, 0.1, 0.0])
    env_send(t, c, HALL, [(0, 0.6), (B(65), 0.35), (B(97), 0.08), (B(145), 0.15), (B(157), 0.7)])
    commit(t)


# ---------------------------------------------------------------- KIT: 打音(16パッド)
K1, K2, K3, K4, S1, S2, S3, S4, H1, H2, H3, H4, P1, P2, P3, P4 = range(36, 52)
PAT = {      # 16分ステップ。K: キック, S: スネア, g: ゴースト, t: 低いタム
    "a": dict(K=[0, 10], S=[4, 12], g=[7, 9, 15], t=[]),
    "b": dict(K=[0, 3, 10], S=[4, 12], g=[7, 14], t=[11]),
    "c": dict(K=[0, 2, 10, 11], S=[4, 12], g=[7, 9], t=[]),
    "d": dict(K=[0, 2, 10], S=[4, 14], g=[7, 9, 12], t=[]),
    "e": dict(K=[0, 6, 10], S=[4, 12, 15], g=[9, 11], t=[14]),
    "f": dict(K=[0, 3, 6, 11], S=[4, 13], g=[8, 10, 15], t=[]),
}
KX = {"a": [10], "b": [3, 10], "c": [2, 10], "d": [10], "e": [6], "f": [3, 11]}   # v3: 四つ打ちの間に残す跳ねのキック
JK = {       # v4 ジューク/フットワーク。K: キック, S: クラップ役のスネア, tk: 3連キックを入れる拍(0始まり)
    "A": dict(K=[0, 3, 6, 10, 14], S=[4, 12], tk=None),         # ベースの1小節目と同じ位置
    "B": dict(K=[0, 6, 8, 11, 14], S=[4, 12], tk=None),
    "C": dict(K=[0, 3, 6, 10, 12, 14], S=[12], tk=None),
    "D": dict(K=[0, 3, 6, 8, 11, 14], S=[4, 12], tk=None),      # 3-3-2 を2回
    "E": dict(K=[0, 3, 6, 9, 12, 14], S=[12], tk=None),         # 3-3-3-3-2-2
    "F": dict(K=[0, 3, 6, 12, 14], S=[12], tk=2),               # 3拍目に3連のキック
}


def kit_notes():
    rng = random.Random(150)
    n = []
    hum = lambda v: v + rng.randint(-5, 5)

    for bar in range(49, 65):                               # B: 鼓動
        if bar < 57 and bar % 2 == 0:
            continue
        n.append((K1, B(bar), 0.3, 55 + int(40 * (bar - 49) / 16.0)))
        if V6:                                              # v6: 鼓動も2つ打ち(ドッ・ドッ)
            n.append((K1, st(bar, 3), 0.3, 40 + int(40 * (bar - 49) / 16.0)))
        if bar >= 57 and bar % 2 == 0:
            n.append((P2, st(bar, 10), 0.2, 50))
        if bar >= 61:
            n.append((H2, st(bar, 4), 0.1, 40))
            n.append((H2, st(bar, 12), 0.1, 46))

    def tri(pitch, bar, beat, a, b, count=6):               # 1拍を3連(16分3連)で刻む
        for j in range(count):
            n.append((pitch, B(bar) + beat + j / 6.0, 0.08, hum(a + int((b - a) * j / max(1, count - 1)))))

    def half_juke(bar, lvl):                                # v4: クラップが3拍目に来るハーフタイムのフットワーク
        n.append((K1, st(bar, 0), 0.3, hum(116)))
        n.append((S1, st(bar, 8), 0.3, hum(114)))
        if V6 and lvl == 0:                                 # v6: 入りの8小節もキック2つ
            n.append((K2, st(bar, 10), 0.3, hum(92)))
        if lvl >= 1:
            n.append((K2, st(bar, 0), 0.3, hum(90)))
            n.append((S2, st(bar, 8), 0.3, hum(84)))
            n.append((K2, st(bar, 6), 0.3, hum(84)))
            for i in (2, 6, 10, 14):
                n.append((H3, st(bar, i), 0.1, hum(72)))
        if lvl >= 2:
            n.append((K2, st(bar, 3), 0.3, hum(80)))
            n.append((K1, st(bar, 10 if bar % 2 else 11), 0.3, hum(92)))
            for i in (0, 4, 12):
                n.append((H2, st(bar, i), 0.1, hum(46)))
            n.append((S3, st(bar, 15), 0.1, hum(44)))
        if lvl >= 3:
            n.append((K2, st(bar, 14), 0.3, hum(88)))
            n.append((S4, st(bar, 5 if bar % 2 else 13), 0.1, hum(56)))
            n.append((P1 if bar % 2 else P3, st(bar, 13 if bar % 2 else 3), 0.2, hum(64)))
            if bar % 2 == 0:
                tri(H2, bar, 3, 40, 70)                     # 2小節ごとに4拍目をハットの3連で刻む

    def half(bar, lvl):                                     # ハーフタイム
        if JUKE:
            return half_juke(bar, lvl)
        n.append((K1, st(bar, 0), 0.3, hum(112 if V1 else 116)))
        n.append((S1, st(bar, 8), 0.3, hum(108 if V1 else 114)))
        if lvl >= 1 and not V1:
            n.append((K2, st(bar, 0), 0.3, hum(90)))
            n.append((S2, st(bar, 8), 0.3, hum(84)))
        if lvl >= 1:
            for i in range(0, 16, 2):
                n.append((H3 if i % 4 == 0 else H2, st(bar, i), 0.1, hum(70 if i % 4 == 0 else 48)))
        if lvl >= 2:
            n.append((K2, st(bar, 10 if bar % 2 else 6), 0.3, hum(88)))
            n.append((S3, st(bar, 15), 0.1, hum(44)))
        if lvl >= 3:
            n.append((S2, st(bar, 11), 0.1, hum(50)))
            n.append((P1 if bar % 2 else P3, st(bar, 13 if bar % 2 else 3), 0.2, hum(64)))
            if bar % 4 == 0:
                n.append((K3, st(bar, 14), 0.2, hum(72)))
        if V3 and 89 <= bar < 97:                           # v3: Break の前に四分のキックが少しずつ入ってくる
            for i in (4, 8, 12):
                n.append((K2, st(bar, i), 0.3, hum(62 + 5 * (bar - 89))))

    def roll(bar, beats, a=50, b=112, tripl=None):          # 小節の終わりのロール
        steps = int(beats * 4)
        start = B(bar) + 4 - beats
        n[:] = [x for x in n if not (x[1] >= start and x[1] < B(bar) + 4 and x[0] in (S1, S2, S3, S4, H2, H3))]
        if JUKE if tripl is None else tripl:                # v4: 3連のロール(2拍のときは最後の1拍が倍の細かさ)
            for i in range(6 if beats < 2 else 6):
                n.append((S2 if i % 2 == 0 else S3, start + i / 6.0, 0.1, a + int((b - a) * 0.6 * i / 6)))
            if beats >= 2:
                for i in range(12):
                    n.append((S2 if i % 2 == 0 else S3, B(bar) + 3 + i / 12.0, 0.05, a + int((b - a) * (0.6 + 0.4 * i / 12))))
            return
        for i in range(steps):
            n.append((S2 if i % 2 == 0 else S3, start + i * 0.25, 0.1, a + int((b - a) * i / steps)))
        if beats >= 2:                                      # 最後の1拍は32分
            for i in range(8):
                n.append((S3, B(bar) + 3 + i * 0.125 + 0.0625, 0.05, 60 + 6 * i))

    for bar in range(65, 97):
        half(bar, (bar - 65) // 8)
    roll(80, 1); roll(88, 1); roll(96, 2)

    def juke(bar, key, lvl):                                # v4: ジューク/フットワーク。lvl 0 Break / 1 Chop / 2 Peak
        p = JK[key]
        for i in p["K"]:
            n.append((K1, st(bar, i), 0.3, hum(118 if i == 0 else (110 if i % 4 == 0 else 104))))
            if i == 0:
                n.append((K2, st(bar, i), 0.3, hum(96)))
        if p["tk"] is not None:
            tri(K2, bar, p["tk"], 78, 104)
        for j, i in enumerate(p["S"]):
            n.append((S1 if j % 2 == 0 else S2, st(bar, i), 0.3, hum(116)))
            n.append((S2 if j % 2 == 0 else S1, st(bar, i), 0.3, hum(86)))
        for i in ([7, 15] if bar % 2 else [10, 15]):        # ゴースト
            n.append((rng.choice([S3, S4]), st(bar, i), 0.1, hum(46)))
        if lvl >= 1:                                        # 3つ刻みのリム(4拍子に対してずれていく)
            for i in ([3, 6, 9] if bar % 2 else [7, 10, 13]):
                n.append((S4, st(bar, i), 0.1, hum(58)))
        if lvl >= 2:                                        # タム
            for i in ([5, 11] if bar % 2 else [7, 13]):
                n.append((K3, st(bar, i), 0.2, hum(80)))
        roll_beat = (1 if bar % 4 == 2 else 3) if (lvl >= 1 and bar % 2 == 0) else None
        for i in range(16):
            if roll_beat is not None and i // 4 == roll_beat:
                continue
            if i % 4 == 2:
                n.append((H3, st(bar, i), 0.1, hum(86)))    # 裏拍のハット
            elif i % 2 == 0:
                n.append((H2, st(bar, i), 0.1, hum(50)))
            elif lvl >= 2 or rng.random() < 0.4:
                n.append((H2, st(bar, i), 0.1, hum(42)))
        if roll_beat is not None:
            tri(H2, bar, roll_beat, 44, 78)                 # ハットの3連
        elif bar % 2 == 0:
            n.append((H4, st(bar, 14), 0.2, hum(74)))
        if lvl >= 1:
            n.append((rng.choice([P1, P2, P3, P4]), st(bar, rng.choice([3, 5, 11, 13])), 0.2, hum(72)))
            if bar % 2 == 0:
                n.append((K4, st(bar, 15), 0.1, hum(70)))

    def full(bar, key, dense=False, perc=False):            # フルのブレイクビーツ
        if JUKE:
            return juke(bar, {"a": "A", "b": "B", "c": "A", "d": "D", "e": "C" if not perc else "E", "f": "D" if not perc else "F"}[key],
                        2 if dense else (1 if perc else 0))
        p = PAT[key]
        if V3:                                              # v3: 毎拍にキック。跳ねのキックは軽く残す
            for i in (0, 4, 8, 12):
                n.append((K1, st(bar, i), 0.3, hum(118 if i == 0 else 110)))
                if i == 0:
                    n.append((K2, st(bar, i), 0.3, hum(96)))
            for i in KX[key]:
                n.append((K2, st(bar, i), 0.3, hum(84)))
        for i in ([] if V3 else p["K"]):
            n.append((K1 if i == 0 else rng.choice([K1, K2]), st(bar, i), 0.3, hum((116 if i == 0 else 100) if V1 else (118 if i == 0 else 104))))
            if i == 0 and not V1:
                n.append((K2, st(bar, i), 0.3, hum(96)))        # 頭は2つのキックを重ねる
        for j, i in enumerate(p["S"]):
            main = i in (4, 12)
            n.append(((S1 if j % 2 == 0 else S2) if main else S3, st(bar, i), 0.3, hum((112 if main else 84) if V1 else (116 if main else 86))))
            if main and not V1:
                n.append((S2 if j % 2 == 0 else S1, st(bar, i), 0.3, hum(86)))  # バックビートは2つのスネアを重ねる
        for i in p["g"]:
            n.append((rng.choice([S3, S4]), st(bar, i), 0.1, hum(46)))
        for i in p["t"]:
            n.append((K3, st(bar, i), 0.2, hum(84)))
        for i in range(16):
            if i % 2 == 0:
                acc = (56 if i % 4 == 0 else 84) if V3 else (78 if i % 4 == 0 else 62)   # v3 は裏拍を強く
                n.append((H3, st(bar, i), 0.1, hum(acc)))
            elif dense or rng.random() < 0.55:
                n.append((H2, st(bar, i), 0.1, hum(44)))
        if bar % 2 == 0:
            n.append((H4, st(bar, 14), 0.2, hum(74)))
        n.append((H1, st(bar, 6), 0.1, hum(58)))
        if perc:
            n.append((rng.choice([P1, P2, P3, P4]), st(bar, rng.choice([3, 5, 11, 13])), 0.2, hum(72)))
            if bar % 2 == 0:
                n.append((K4, st(bar, 15), 0.1, hum(70)))

    def techno(bar, a, lvl):                                # v5: まっすぐな四つ打ち。a は実際の小節番号
        for i in (0, 4, 8, 12):
            n.append((K1, st(bar, i), 0.3, hum(120 if i == 0 else 114)))
            if i == 0:
                n.append((K2, st(bar, i), 0.3, hum(96)))
        for j, i in enumerate((4, 12)):                     # クラップ役のスネア
            n.append((S1 if j == 0 else S2, st(bar, i), 0.3, hum(112)))
            n.append((S2 if j == 0 else S1, st(bar, i), 0.3, hum(82)))
        for i in (2, 6, 10, 14):                            # 裏拍のハット
            n.append((H3, st(bar, i), 0.1, hum(88)))
            if lvl >= 2:
                n.append((H4, st(bar, i), 0.2, hum(64)))
        if lvl >= 1:
            for i in range(16):
                if i % 4 != 2:
                    n.append((H2, st(bar, i), 0.1, hum(44 if i % 2 else 52)))
            n.append((S4, st(bar, 3 if a % 2 else 11), 0.1, hum(56)))
        if lvl >= 2:
            n.append((P2, st(bar, 7), 0.2, hum(60)))
            if a % 2 == 0:
                n.append((K3, st(bar, 15), 0.2, hum(70)))

    def build(bar, a):                                      # v5: 173–186。キックが 8分 → 16分 → 32分 と詰まっていく
        k = a - 173
        if k < 8:                                           # 173–180: 8分
            for i in range(0, 16, 2):
                n.append((K1, st(bar, i), 0.3, hum(118) if i % 4 == 0 else 84 + 3 * k))
            for j, i in enumerate((4, 12)):
                n.append((S1 if j == 0 else S2, st(bar, i), 0.3, hum(112)))
                n.append((S2 if j == 0 else S1, st(bar, i), 0.3, hum(82)))
            for i in range(16):
                n.append((H3, st(bar, i), 0.1, hum(88)) if i % 4 == 2 else (H2, st(bar, i), 0.1, hum(46)))
            if k >= 4:                                      # 177–180: スネアの8分が下から上がってくる
                for i in range(0, 16, 2):
                    if i not in (4, 12):
                        n.append((S3, st(bar, i), 0.1, 40 + 9 * (k - 4) + i))
        elif k < 13:                                        # 181–185: 16分
            base = 84 + 5 * (k - 8)
            for i in range(16):
                n.append((K1, st(bar, i), 0.2, base + (12 if i % 4 == 0 else 0) + i // 4))
                n.append((S2 if i % 2 == 0 else S3, st(bar, i), 0.1, 58 + 7 * (k - 8) + i))
            for i in (2, 6, 10, 14):
                n.append((H3, st(bar, i), 0.1, hum(88)))
                n.append((H4, st(bar, i), 0.2, hum(70)))
        else:                                               # 186: 前半 16分、後半 32分
            for i in range(8):
                n.append((K1, st(bar, i), 0.2, 108 + i))
                n.append((S2 if i % 2 == 0 else S3, st(bar, i), 0.1, 96 + i))
            for j in range(16):
                n.append((K1, B(bar) + 2 + j * 0.125, 0.1, 100 + int(27 * j / 15.0)))
                n.append((S2 if j % 2 == 0 else S3, B(bar) + 2 + j * 0.125, 0.05, 100 + int(27 * j / 15.0)))

    if V5:                                                  # v5: ジューク → 四つ打ち → 詰める → 一打
        s1, s3 = "abacabaeabacabaf", "cbcecbcfcbcecdef"
        for k, bar in enumerate(range(97, 113)):
            full(bar, s1[k], perc=bar >= 105)
        roll(104, 1); roll(112, 2)
        for k, bar in enumerate(range(113, 129)):
            full(bar, s3[k], dense=True, perc=True)
        roll(120, 1); roll(128, 2)
        for a in range(129, 173):
            techno(X(a), a, 0 if a < 137 else (1 if a < 153 else 2))
        for a in (136, 144, 152, 160, 168, 172):
            roll(X(a), 1, tripl=False)
        for a in range(173, 187):
            build(X(a), a)
        for p_, v_ in ((K1, 127), (K2, 114), (S1, 120), (S2, 96), (H4, 104)):   # 最後の一打
            n.append((p_, B(FIN), 0.5, v_))
        if V6:                                              # v6: キックは全部 kick_4 + snare_1 の重ねにする
            hit, rest = {}, {}
            for p_, s_, d_, v_ in n:
                if p_ in (K1, K2, K4):                      # キック役(kick_3 はタムとして使っているので残す)
                    k_ = round(s_, 4)
                    hit[k_] = (max(v_, hit.get(k_, (0, 0))[0]), max(d_, hit.get(k_, (0, 0))[1]))
                else:
                    k_ = (p_, round(s_, 4))
                    if k_ not in rest or v_ > rest[k_][3]:
                        rest[k_] = (p_, s_, d_, v_)
            for s_, (v_, d_) in hit.items():
                for p_ in (K4, S1):
                    k_ = (p_, s_)
                    if k_ not in rest or v_ > rest[k_][3]:
                        rest[k_] = (p_, s_, d_, v_)
            n = list(rest.values())
        return n

    seq1 = "abacabaeabacabaf"
    for k, bar in enumerate(range(97, 113)):
        full(bar, seq1[k])
    roll(104, 1); roll(112, 2)
    seq2 = "cecfcdefcecfcdef"
    for k, bar in enumerate(range(113, 129)):
        full(bar, seq2[k], perc=True)
        if bar % 4 == 0:                                    # 4小節ごとに3拍目を抜いてから連打
            a, b = B(bar) + 2, B(bar) + 3
            n[:] = [x for x in n if not (a <= x[1] < b)]
            if V4:                                          # v4: 連打は3連(キックとスネアを交互に)
                n[:] = [x for x in n if not (b <= x[1] < b + 1 and x[0] in (H2, H3, H4))]
                for i in range(6):
                    n.append((S3 if i % 2 else K2, b + i / 6.0, 0.08, 64 + 9 * i))
                continue
            for i in range(8):
                n.append((S3 if i % 2 else K2, b + i * 0.125, 0.06, 56 + 8 * i))
    roll(128, 1)
    seq3 = "cbcecbcfcbcecdef"
    for k, bar in enumerate(range(129, 145)):
        full(bar, seq3[k], dense=True, perc=True)
    roll(136, 1); roll(144, 2)
    for bar in range(201, 205):                             # 引き: ハットとゴーストだけ
        for i in range(0, 16, 2):
            n.append((H3 if i % 4 == 0 else H2, st(bar, i), 0.1, hum(64 if i % 4 == 0 else 44)))
        n.append((S4, st(bar, 4), 0.1, hum(60)))
        n.append((S4, st(bar, 12), 0.1, hum(64)))
        n.append((rng.choice([P1, P2, P3, P4]), st(bar, rng.choice([3, 7, 11, 14])), 0.2, hum(66)))
    for bar in range(205, 209):
        half(bar, 3)
    roll(208, 2)
    for k, bar in enumerate(range(209, 217)):               # 最後の山
        full(bar, "cbcecdef"[k], dense=True, perc=True)
    roll(216, 2)
    for bar in range(145, 153):                             # E: ほどける
        half(bar, 2 if bar < 149 else 0)
    for bar in (153, 155):
        n.append((K1, B(bar), 0.3, 70 - 10 * (bar - 153)))
    return n


def kit_open():             # キットのフィルタの開き方(v2 は早く開ける)
    if V1:
        return [(B(65), fr(1200)), (B(81), fr(5000))]
    return [(B(65), fr(3000)), (B(73), fr(9000)), (B(81), fr(19500))]


def t_kit():
    order = [e["name"] for cls in ("kick", "snare", "hat", "perc") for e in MAN["kit"] if e["cls"] == cls]
    assert len(order) == 16, order
    t, chain = rack("KIT", [(x, x) for x in order])
    fo = None
    for name in order:
        cp = [[chain[name], 0]]
        target = -14 if name.startswith("hat") else (-10 if name.startswith("perc") else (-7 if V1 else -4))
        setp(t, 0, {"Volume": clamp(target - M[name]["peak_db"], -24, 22)}, chain_path=cp)
        simpler_time(t, "Fade Out", 12 if V1 else (25 if name.startswith("hat") else 70), cp)
    af = afilter(t, 0, 180)
    if V1:
        sat = fx(t, "Saturator")
        setd(t, sat, {"Drive": 3.0}, iters=9)
    else:
        db_ = fx(t, "Drum Buss")
        setp(t, db_, {"Compressor On": 1, "Drive": 0.3, "Transients": 0.45, "Boom Amt": 0.15})
        rv = fx(t, "Reverb")                                    # 短い部屋鳴りで打音の切り口をつなぐ
        setp(t, rv, {"Decay Time": math.log(0.7 / 0.2) / math.log(300), "Dry/Wet": 0.12})
    u = utility(t)
    c = song_clip(t, "kit")
    print("  kit notes", add_notes(t, c, kit_notes()))
    env(t, c, af, "Frequency", [(0, fr(180)), (B(49), fr(180)), *kit_open(), (B(97), fr(19500)),
                                 (B(145), fr(19500)), (B(157), fr(300))])
    fade(t, c, u, [(0, -3), (B(65), -3 if V1 else -1), (B(97), 0), (B(145), 0), (B(157), -8)], cut=False)
    sends(t, [0.75, 0.05, 0.0])
    env_send(t, c, HALL, [(0, 0.75), (B(65), 0.4), (B(97), KH), (B(201), KH), (B(202), 0.45), (B(208), 0.45), (B(209), KH), (B(145), 0.1 if V1 else 0.2), (B(153), 0.6)])
    commit(t)


# ---------------------------------------------------------------- BASS / STAB
E2, G2, A2, B1, C2, D2, E3 = 45, 48, 50, 40, 41, 43, 57     # urban_G を2オクターブ下げて G1 = 36
BASS_PHR = [    # 4小節: Em Em C D。 (16分ステップ, 音, 長さ[16分], 強さ)
    [(0, E2, 3, 112), (3, E2, 2, 76), (6, G2, 2, 96), (10, E2, 3, 104), (14, D2, 2, 92)],
    [(0, E2, 3, 112), (6, B1, 2, 92), (8, E2, 2, 100), (11, E2, 2, 84), (14, G2, 2, 96)],
    [(0, C2, 5, 112), (6, C2, 2, 88), (10, C2, 2, 96), (12, E2, 2, 92), (14, G2, 2, 96)],
    [(0, D2, 5, 112), (6, D2, 2, 88), (8, D2, 2, 96), (10, B1, 2, 92), (12, D2, 1, 84), (14, D2, 2, 100)],
]


def bass_notes():
    n = []
    roots = [E2, E2, C2, D2]
    for bar in range(81, 97):                               # C: 長い音で入る
        r = roots[(bar - 81) % 4]
        n.append((r, B(bar), 3.4, 74 + (bar - 81)))
        if bar >= 89:
            n.append((r, st(bar, 14), 0.45, 80))
    for bar in range(205, 209):                             # 引きの後半: 長い音で戻る
        r = roots[(bar - 205) % 4]
        n.append((r, B(bar), 3.5, 96))
        n.append((r, st(bar, 14), 0.5, 84))
    if V5:                                                  # v5: ジュークの間は元のフレーズ、四つ打ちからは裏拍の8分
        for bar in range(97, 129):
            for s, p, ln, v in BASS_PHR[(bar - 97) % 4]:
                n.append((p, st(bar, s), ln * 0.25, v))
        for a in range(129, 187):
            for s in (2, 6, 10, 14):
                up = 12 if (s == 14 and a % 2 == 0 and a >= 153) else 0
                n.append((roots[(a - 97) % 4] + up, st(X(a), s), 0.5, 108 if s in (2, 10) else 100))
        n.append((E2, B(FIN), 4.0, 120))                    # 最後の一打(5:00 の手前まで伸ばす)
        return n
    for bar in list(range(97, 145)) + list(range(209, 217)):
        for s, p, ln, v in BASS_PHR[(bar - 97) % 4]:
            if bar >= 129 and s == 10 and bar % 2 == 0:
                p += 12                                     # D3: ときどきオクターブ上
            n.append((p, st(bar, s), ln * 0.25 * (0.9 if V1 else 1.0), v))
    for bar in range(145, 153):
        n.append((roots[(bar - 145) % 4], B(bar), 3.4, 92 - 6 * (bar - 145)))
    return n


def t_bass():
    t = sampler("BASS", "urban_G", -4, loop=(0.7, 0.3), att=4, rel=80 if V1 else 150, vel=0.3, start=0.05)
    setp(t, 0, {"Filt < Key": 0.0})
    simpler_time(t, "Filter Freq", 170)
    afilter(t, 1, 32)                                       # 2オクターブ下げで出る超低域を切る
    sat = fx(t, "Saturator")
    setd(t, sat, {"Drive": 8.0}, iters=9)
    u = utility(t)
    c = song_clip(t, "bass")
    print("  bass notes", add_notes(t, c, bass_notes()))
    fade(t, c, u, [(0, -6), (B(81), -6), (B(97), 0), (B(145), 0), (B(153), -6)], cut=False)
    sends(t, [0.0, 0.0, 0.0])
    commit(t)


def stab_notes():
    n = []
    for bar in range(81, 97, 2):                            # C: まばらに
        n.append((60, st(bar, 6), 0.5, 72))
    for bar in (201, 203, 205, 207):                        # 引き: 長い和音
        n.append((55 if bar == 207 else 60, B(bar), 1.5, 84))
    if V5:
        n.append((60, B(FIN), 4.0, 118))                    # 最後の一打(5:00 の手前まで伸ばす)
    for bar in list(range(97, 145)) + (list(range(301, FIN)) if V5 else list(range(209, 217))):
        pitch = 55 if (bar - 97) % 4 == 3 else 60
        steps = [3, 6] if bar % 2 else [11, 14]
        if bar >= 129:
            steps = steps + [9]
        for s in steps:
            n.append((pitch, st(bar, s), 0.4 if V1 else 0.75, 96 if s in (3, 11) else 82))
        if bar >= 113 and bar % 8 == 0:
            n.append((pitch + 12, st(bar, 15), 0.4, 80))
    for bar in (145, 149):
        n.append((60, B(bar), 1.5, 80))
    return n


def t_stab():
    t = sampler("STAB", "rhopalia_Am", 2, loop=None, att=2, rel=300 if V1 else 700, vel=0.5, start=0.05)
    afilter(t, 1, 250)
    u = utility(t)
    c = song_clip(t, "stab")
    print("  stab notes", add_notes(t, c, stab_notes()))
    fade(t, c, u, [(0, -4), (B(97), -4), (B(129), -2), (B(145), -4)], cut=False)
    sends(t, [0.25, 0.45, 0.2])
    commit(t)


# ---------------------------------------------------------------- 仕上げ
ORDER = [("SUB", t_sub), ("GLASS", t_glass), ("ORBIS", t_orbis), ("SHIMMER", t_shimmer), ("CHORD", t_chord),
         ("AIR", t_air), ("NOISE", t_noise), ("ROAR", t_roar), ("GRAINS", t_grains), ("LOOPS", t_loops),
         ("KIT", t_kit), ("BASS", t_bass), ("STAB", t_stab)]
MIX = json.load(open(os.path.join(ROOT, "work", "mix.json"))) if os.path.exists(os.path.join(ROOT, "work", "mix.json")) else {}
if V1 and MIX:
    MIX["KIT"] = -4


def mix():
    for name, v in MIX.items():
        t = find(name)
        if t is not None:
            vol(t, v)


def locators():
    for name, bar in [("Drone", 1), ("Stirring", 33), ("Pulse", 65), ("Break", 97), ("Chop", 113), ("Peak", 129),
                      ("Breakdown", 201), ("Final", 209), ("Dissolve", 145)]:
        q("set_current_song_time", {"time": B(bar)})
        time.sleep(0.3)
        q("create_locator", {"name": name, "time": B(bar)})


def clean():
    keep = set(dict(ORDER))
    while True:                     # 消すたびに既定名の番号が振り直されるので、毎回数え直す
        ns = names()
        extra = [i for i, n in enumerate(ns) if n not in keep]
        if not extra or len(ns) <= 1:
            break
        ok(q("delete_track", {"track_index": extra[-1]}))


if __name__ == "__main__":
    args = sys.argv[1:] or ["all"]
    t0 = time.time()
    if "all" in args:
        ok(q("set_tempo", {"tempo": float(BPM)}))
        clean()
    if "all" in args or "returns" in args:
        build_returns()
    if "all" in args or "master" in args:
        build_master()
    for name, fn in ORDER:
        if "all" in args or name in args:
            print("building", name, "(%.0fs)" % (time.time() - t0), flush=True)
            fn()
    if "all" in args or "clean" in args:
        clean()
    if "all" in args or "mix" in args:
        mix()
    if "all" in args or "locators" in args:
        locators()
    print("done in %.0fs" % (time.time() - t0), names(), flush=True)
