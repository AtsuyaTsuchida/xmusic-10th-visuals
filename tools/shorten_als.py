#!/usr/bin/env python3
"""Live セット(.als)の頭のアンビエント部分を短くした別ファイルを作る。

  python3 shorten_als.py 元.als 出力.als

元のファイルは書き換えない。Live を操作もしない(保存済みのファイルを読むだけ)。
やっていることは「時間の付け替え」だけで、音は作っていない。

SECTIONS の各区間を短くする。区間より後ろは、短くした分だけ前へずらす。
  - オートメーション: 区間の中を同じ比率で縮める(動きは同じで、速くなる。段差ができない)
  - 伸ばしっぱなしの音(ドローン): 始まりと終わりを同じ比率で縮める。始まりは小節の頭に寄せる
  - 刻む音(キット、グレイン、ループ): 縮めると速くなってしまうので、区間の中の一部だけを残す
"""
import gzip
import statistics
import sys
import xml.etree.ElementTree as ET

# (元の開始拍, 元の終了拍, 新しい長さ(拍), 刻む音で残す範囲の開始拍)
SECTIONS = [
    (0.0, 288.0, 48.0, 240.0),     # 小節 1-72 のアンビエント → 12 小節。刻む音は最後の 12 小節ぶんを残す
    (288.0, 384.0, 32.0, 320.0),   # 小節 73-96 の鼓動 → 8 小節。1小節おきに打つ 81-88 小節を残す
]
REGION_END = SECTIONS[-1][1]
REMOVED = sum(b - a - n for a, b, n, _ in SECTIONS)
BAR = 4.0
DRONE_MIN = 8.0          # 区間内のノートの長さの中央値がこれ以上なら「伸ばしっぱなしの音」とみなす


def squeeze(t):
    """縮める付け替え。オートメーションとドローンに使う。"""
    if t < 0:
        return t                                  # オートメーション先頭の番兵(-63072000)はそのまま
    out = 0.0
    for a, b, n, _ in SECTIONS:
        if t < a:
            return out + (t - a)                  # 区間同士は連続している前提なので、ここには来ない
        if t <= b:
            return out + (t - a) * n / (b - a)
        out += n
    return t - REMOVED


def cut(t):
    """切り取る付け替え。刻む音の始まりに使う。残さない所は None。"""
    out = 0.0
    for a, b, n, keep in SECTIONS:
        if a <= t < b:
            return out + (t - keep) if keep <= t < keep + n else None
        out += n
    return t - REMOVED


def num(x):
    x = round(x, 9)
    return str(int(x)) if x == int(x) else ("%.12f" % x).rstrip("0")


def val(el, path):
    return float(el.find(path).attrib["Value"])


def setval(el, path, x):
    el.find(path).attrib["Value"] = num(x)


def remap_notes(clip, name, log):
    keytracks = clip.find("Notes/KeyTracks")
    if keytracks is None:
        return
    durs = [float(n.attrib["Duration"]) for k in keytracks for n in k.find("Notes") if float(n.attrib["Time"]) < REGION_END]
    if not durs:
        mode = "none"
    else:
        mode = "drone" if statistics.median(durs) >= DRONE_MIN else "beat"
    kept = dropped = 0
    for k in list(keytracks):
        notes = k.find("Notes")
        inner, closing = notes.text, (list(notes)[-1].tail if len(notes) else None)   # 字下げを元どおりに保つ
        out = []
        for n in list(notes):
            t, d = float(n.attrib["Time"]), float(n.attrib["Duration"])
            if t >= REGION_END:
                ns, ne = t - REMOVED, t - REMOVED + d
            elif mode == "drone":
                ns = round(squeeze(t) / BAR) * BAR
                ne = squeeze(t + d)
                if ne - ns < 1.0:
                    ns = None
            else:
                ns = cut(t)
                ne = None if ns is None else ns + d
            if ns is None:
                notes.remove(n); dropped += 1
                continue
            out.append([ns, ne, n]); kept += 1
        out.sort(key=lambda x: x[0])
        for i, (ns, ne, n) in enumerate(out):
            if i + 1 < len(out) and ne > out[i + 1][0]:
                ne = out[i + 1][0]                # 同じ高さの音が重ならないようにする
            n.attrib["Time"], n.attrib["Duration"] = num(ns), num(ne - ns)
        for n in list(notes):
            notes.remove(n)
        for i, (_, _, n) in enumerate(out):
            n.tail = closing if i == len(out) - 1 else inner
            notes.append(n)
        if not out:
            keytracks.remove(k)
    log.append("  %-10s 区間内の扱い=%-5s 残したノート %5d  区間内で消したノート %4d" % (name, mode, kept, dropped))


def serialize(root):
    """Live が書くのと同じ表記にする(改行の文字参照だけ ElementTree と違う)。"""
    return ET.tostring(root, encoding="unicode").replace("&#10;", "&#x0A;")


def main(src, dst):
    raw = gzip.open(src).read()
    head = raw[:raw.index(b"<Ableton")].decode()
    root = ET.fromstring(raw)
    # 読み書きしただけで表記が変わる行(属性を ' で囲んだ行など)は、あとで元の表記に戻す
    orig_lines = raw.decode("utf-8").split("\n")
    rt_lines = (head + serialize(root) + "\n").split("\n")
    if len(orig_lines) != len(rt_lines):
        raise SystemExit("読み書きしただけで行数が変わる。書式を確かめること")
    restore = {r: o for o, r in zip(orig_lines, rt_lines) if o != r}
    ls = root.find("LiveSet")
    log = []

    tracks = list(ls.find("Tracks"))
    for extra in ("MainTrack", "MasterTrack", "PreHearTrack"):
        t = ls.find(extra)
        if t is not None:
            tracks.append(t)

    for t in tracks:
        name_el = t.find("Name/EffectiveName")
        name = name_el.attrib["Value"] if name_el is not None else t.tag
        # アレンジメントのクリップ
        for c in t.findall(".//ArrangerAutomation/Events/*"):
            s, e = val(c, "CurrentStart"), val(c, "CurrentEnd")
            if s >= REGION_END:                   # 区間より後ろ: そのまま前へずらす
                c.attrib["Time"] = num(s - REMOVED)
                setval(c, "CurrentStart", s - REMOVED); setval(c, "CurrentEnd", e - REMOVED)
            elif s == 0 and e >= REGION_END and val(c, "Loop/StartRelative") == 0 and val(c, "Loop/LoopStart") == 0 and val(c, "Loop/LoopEnd") >= e:
                if c.tag != "MidiClip":
                    raise SystemExit("MIDI 以外のクリップが区間にかかっている: " + name)
                remap_notes(c, name, log)         # 区間をまたぐクリップ: 中のノートを付け替え、長さを縮める
                setval(c, "CurrentEnd", e - REMOVED)
                for p in ("Loop/LoopEnd", "Loop/OutMarker"):
                    if val(c, p) >= REGION_END:
                        setval(c, p, val(c, p) - REMOVED)
            else:
                raise SystemExit("想定していない置き方のクリップ: %s %s-%s" % (name, s, e))
        # トラックのオートメーション
        for ev in t.findall("AutomationEnvelopes/Envelopes/AutomationEnvelope/Automation/Events/*"):
            ev.attrib["Time"] = num(squeeze(float(ev.attrib["Time"])))

    for loc in ls.findall("Locators/Locators/Locator"):
        setval(loc, "Time", squeeze(val(loc, "Time")))
    tr = ls.find("Transport")
    ls0, ll = val(tr, "LoopStart"), val(tr, "LoopLength")
    setval(tr, "LoopStart", squeeze(ls0)); setval(tr, "LoopLength", squeeze(ls0 + ll) - squeeze(ls0))
    setval(tr, "CurrentTime", 0)

    lines = [restore.get(l, l) for l in (head + serialize(root) + "\n").split("\n")]
    with gzip.open(dst, "wb") as f:
        f.write("\n".join(lines).encode("utf-8"))
    print("元の表記に戻した行:", len(restore))
    print("削った長さ: %g 拍 = %g 小節" % (REMOVED, REMOVED / BAR))
    print("\n".join(log))
    print("->", dst)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
