#!/usr/bin/env python3
"""Record every music track's output (post-FX) plus the master in ONE real-time pass.

usage: stems.py OUTDIR [START SECS]
Creates audio tracks "_S_<NAME>" at the end of the set (existing indices stay unchanged),
arms them all with input = that track, records, aligns each file to START and writes
OUTDIR/<NAME>.wav. The _S_ tracks are removed afterwards.
"""
import glob, os, sys, time
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from live import q
from analyze import read_wav
from rec import tracks, write_wav, fresh_rec_track

SKIP = {"_REC"}


def snapshot():
    return q("get_session_snapshot", {"include_notes": False, "include_params": False})["result"]


def main():
    out = sys.argv[1]
    start = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 364.0
    os.makedirs(out, exist_ok=True)
    names = [n for n in tracks() if n not in SKIP and not n.startswith("_S_")]
    if os.environ.get("XMC_ONLY_MASTER"):      # マスターだけ録る
        names = []
    if os.environ.get("XMC_ONLY"):             # 例 XMC_ONLY=KIT,LOOPS : 挙げたトラックとマスターだけ録る
        names = [n for n in names if n in os.environ["XMC_ONLY"].split(",")]
    # ソロが入っているとマスターにそのトラックしか入らない(気づかずに5分録ってしまった)。先に確かめて止める
    soloed = [n for i, n in enumerate(tracks()) if q("get_track_info", {"track_index": i})["result"].get("solo")]
    if soloed and not os.environ.get("XMC_ALLOW_SOLO"):
        print("ソロが入っているので録音しません:", ", ".join(soloed))
        sys.exit(2)
    rec_i = fresh_rec_track()
    stem_idx = {}
    for n in names + ["MASTER"]:
        t = q("create_audio_track", {"index": -1})["result"]["index"]
        q("set_track_name", {"track_index": t, "name": "_S_" + n})
        q("set_mixer", {"track_index": t, "mute": True})
        src = "Resampling" if n == "MASTER" else n
        r = q("set_track_routing", {"track_index": t, "input_routing": src, "monitoring": 2, "arm": 1})
        if r.get("status") != "success":
            print("routing failed", n, r)
        stem_idx[n] = t
    tempo = q("get_session_info")["result"]["tempo"]
    spb = 60.0 / tempo
    # 録音用以外のトラックの録音待機を外す(待機のままだと MIDI クリップが空の録音で上書きされる)
    for i, n in enumerate(tracks()):
        if not n.startswith("_S_"):
            q("set_track_routing", {"track_index": i, "arm": 0})
    q("set_song_props", {"loop": False, "record_mode": False})
    q("start_playback")
    time.sleep(0.15)
    q("set_current_song_time", {"time": float(max(0, start - 3))})
    retry = time.time() + 1.0
    while True:
        pos = q("get_session_info")["result"]["current_song_time"]
        if pos >= start - 1.5 and pos < start + 1:
            break
        if time.time() > retry:            # the jump was ignored: ask again
            q("set_current_song_time", {"time": float(max(0, start - 3))})
            retry = time.time() + 1.0
        time.sleep(0.01)
    mark = time.time()
    q("set_song_props", {"record_mode": True})
    # 曲の位置で終わりを決める(壁時計だけに頼ると、途中で止まったときに気づけない)
    end_beat = start + (secs + 1.0) / spb
    cap = time.time() + secs * 2 + 60
    last = time.time()
    while time.time() < cap:
        info = q("get_session_info")["result"]
        pos = info["current_song_time"]
        if pos >= end_beat:
            break
        if not info["is_playing"]:
            print("  再生が止まった t=%.1f (経過 %.0fs)" % (pos, time.time() - mark), flush=True)
            break
        if time.time() - last >= 20:
            last = time.time()
            print("  t=%.1f (経過 %.0fs)" % (pos, time.time() - mark), flush=True)
        time.sleep(min(2.0, max(0.05, (end_beat - pos) * spb)))
    q("stop_playback")
    q("set_song_props", {"record_mode": False})
    time.sleep(3)
    snap = snapshot()
    files = glob.glob(os.path.expanduser("~/Music/Ableton/Live Recordings/**/*.wav"), recursive=True)
    # セットを保存済みのときは、録音はそのプロジェクトの Samples/Recorded に入る
    files += glob.glob(os.path.expanduser("~/Documents/PrivatePJ/*/Samples/Recorded/*.wav"))
    for n, t in stem_idx.items():
        tr = snap["tracks"][t]
        clips = tr["arrangement_clips"]
        cand = [f for f in files if os.path.getmtime(f) > mark and os.path.basename(f).startswith("_S_%s " % n)]
        if not clips or not cand:
            print("missing", n)
            continue
        f = max(cand, key=os.path.getmtime)
        y, sr = read_wav(f)
        off = int(round((start - clips[0]["start_time"]) * spb * sr))
        y = y[off:] if off >= 0 else np.vstack([np.zeros((-off, y.shape[1])), y])
        write_wav(os.path.join(out, n + ".wav"), y[:int(secs * sr)], sr)
    # remove stem tracks (highest index first)
    for n, t in sorted(stem_idx.items(), key=lambda x: -x[1]):
        q("delete_track", {"track_index": t})
    print("stems written to", out)


if __name__ == "__main__":
    main()
