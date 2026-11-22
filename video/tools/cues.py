#!/usr/bin/env python3
"""Live セット(.als)から、ドラムが鳴る時刻の一覧(.cues.json)を作る。

  python3 cues.py セット.als 出力.cues.json [音の遅れ(秒)]

映像アプリは、音源と同じ名前の .cues.json(例: 曲.wav → 曲.cues.json)があれば読み込み、
キックでブルーム、クラップで色の反転に使う。音は作らない(保存済みのセットを読むだけ)。

- 鳴っているものだけ拾う: トラックがオン、クリップが有効、ノートが有効、クリップの範囲の中。
- 拍 → 秒 は、セットのテンポ(途中で変わる場合はそのオートメーション)で換算する。
- 音の遅れ: ノートの位置から、書き出した音が実際に立ち上がるまでの時間。v9 では約 0.008 秒だった。
"""
import gzip
import json
import sys
import xml.etree.ElementTree as ET

# 列の名前 → [(トラック名, パッド名)]。同じ名前のトラックが複数あれば全部から拾う
LANES = {
    "kick": [("KIT", "kick_4")],
    "clap": [("BASS", "Snare Slap RK")],
    "hat": [("BASS", "Hihat Code")],                 # 1分あたりから入る、オープンハイハットのような音
    "hat2": [("BASS", "Hihat Closed Modular Salient 1")],   # その 0.3 秒あとに鳴る相方(いまは使っていない)
    "metal": [("BASS", "Hihat Closed Modular Salient 2")],  # 金物のついたハイハット
}
MERGE = 0.02     # これより近い同じ列の音は1つにまとめる(秒)。強いほうの強さを残す


def val(el, path):
    return el.find(path).attrib["Value"]


def tempo_map(ls):
    """拍 → 秒 の換算。テンポのオートメーション(段差か直線)を足し合わせる。"""
    mt = ls.find("MainTrack")
    if mt is None:
        mt = ls.find("MasterTrack")
    tempo = mt.find("DeviceChain/Mixer/Tempo")
    manual = float(val(tempo, "Manual"))
    tid = tempo.find("AutomationTarget").attrib["Id"]
    pts = []
    for env in mt.findall("AutomationEnvelopes/Envelopes/AutomationEnvelope"):
        if val(env, "EnvelopeTarget/PointeeId") == tid:
            pts = [(max(0.0, float(e.attrib["Time"])), float(e.attrib["Value"])) for e in env.find("Automation/Events")]
    if not pts:
        pts = [(0.0, manual)]

    def bpm(b):
        cur = pts[0][1]
        for i, (t, v) in enumerate(pts):
            if t > b:
                t0, v0 = pts[i - 1] if i else (t, v)
                return v0 + (v - v0) * (b - t0) / (t - t0) if t > t0 else v
            cur = v
        return cur

    def sec(b, step=0.25):
        s, x = 0.0, 0.0
        while x < b:                       # 細かく区切って足す(テンポが変わる所でも誤差が出ない細かさ)
            d = min(step, b - x)
            s += d * 60.0 / bpm(x + d / 2)
            x += d
        return s
    return sec


def notes_of(track):
    """トラックのアレンジメントで実際に鳴るノート: (拍, 高さ, 強さ)"""
    out = []
    for c in track.findall(".//ArrangerAutomation/Events/MidiClip"):
        if val(c, "Disabled") == "true":
            continue
        s, e = float(val(c, "CurrentStart")), float(val(c, "CurrentEnd"))
        l0, l1 = float(val(c, "Loop/LoopStart")), float(val(c, "Loop/LoopEnd"))
        rel, loop = float(val(c, "Loop/StartRelative")), val(c, "Loop/LoopOn") == "true"
        for k in c.findall("Notes/KeyTracks/KeyTrack"):
            p = int(val(k, "MidiKey"))
            for n in k.find("Notes"):
                if n.attrib.get("IsEnabled", "true") != "true":
                    continue
                nt, vel = float(n.attrib["Time"]), float(n.attrib["Velocity"])
                if loop:
                    if not l0 <= nt < l1:
                        continue
                    t = s + (nt - l0 - rel) % (l1 - l0)
                    while t < e:           # クリップがくり返す分
                        out.append((t, p, vel))
                        t += l1 - l0
                else:
                    t = s + nt - l0 - rel
                    if s <= t < e:
                        out.append((t, p, vel))
    return out


def main(src, dst, delay):
    ls = ET.fromstring(gzip.open(src).read()).find("LiveSet")
    sec = tempo_map(ls)
    lanes = {}
    for lane, sources in LANES.items():
        hits = []
        for t in ls.find("Tracks"):
            name = val(t, "Name/EffectiveName")
            if t.find("DeviceChain/Mixer/Speaker/Manual").attrib["Value"] != "true":
                continue
            pads = {128 - int(val(b, "BranchInfo/ReceivingNote")): val(b, "Name/EffectiveName") for b in t.findall(".//DrumBranch")}
            want = {p for p, pn in pads.items() if (name, pn) in sources}
            if want:
                hits += [(b, v) for b, p, v in notes_of(t) if p in want]
        cache, out = {}, []
        for b, v in sorted(hits):
            if b not in cache:
                cache[b] = sec(b) + delay
            t = cache[b]
            if out and t - out[-1][0] < MERGE:
                out[-1][1] = max(out[-1][1], v)
            else:
                out.append([t, v])
        lanes[lane] = [[round(t, 4), round(v / 127.0, 3)] for t, v in out]
        print("%-5s %4d 個  %s" % (lane, len(out), ("%.2f 〜 %.2f 秒" % (out[0][0], out[-1][0])) if out else ""))
    with open(dst, "w") as f:
        json.dump({"source": src.split("/")[-1], "delay": delay, "lanes": lanes}, f, separators=(",", ":"))
    print("->", dst)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 0.0)
