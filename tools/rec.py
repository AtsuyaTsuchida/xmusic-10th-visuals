#!/usr/bin/env python3
"""Record Live's master (Resampling) or one track's output from beat START for SECS seconds.

usage: rec.py OUT.wav START_BEAT SECS [src=TRACK] [solo_track ...]

Setting the song position while stopped is ignored by Live (playback restarts at the start
marker), so we start playback, jump to just before START, punch recording in while playing,
then align the file to START using the recorded clip's actual start time.
"""
import glob, os, struct, sys, time
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from live import q
from analyze import read_wav

REC = "_REC"


def tracks():
    n = q("get_session_info")["result"]["track_count"]
    return [q("get_track_info", {"track_index": i})["result"]["name"] for i in range(n)]


def rec_track():
    names = tracks()
    if REC in names:
        return names.index(REC)
    t = q("create_audio_track", {"index": -1})["result"]["index"]
    q("set_track_name", {"track_index": t, "name": REC})
    return t


def write_wav(path, y, sr):
    data = y.astype("<f4").tobytes()
    ch = y.shape[1]
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 3, ch, sr, sr * ch * 4, ch * 4, 32) + b"data" + struct.pack("<I", len(data))
    open(path, "wb").write(hdr + data)


def rec_clips(r):
    snap = q("get_session_snapshot", {"include_notes": False, "include_params": False})["result"]
    return [(c["start_time"], c["length"]) for c in snap["tracks"][r]["arrangement_clips"]]


def fresh_rec_track():
    """Replace _REC by an empty one at the same index (other track indices stay unchanged)."""
    names = tracks()
    if REC not in names:
        return rec_track()
    i = names.index(REC)
    q("create_audio_track", {"index": i})
    q("set_track_name", {"track_index": i, "name": REC})
    q("delete_track", {"track_index": i + 1})
    return i


def record(out, start, secs, solo=(), source="Resampling", fresh=False, watch=False):
    r = fresh_rec_track() if fresh else rec_track()
    names = tracks()
    for i, n in enumerate(names):
        if i != r:
            q("set_track_routing", {"track_index": i, "arm": 0})
            q("set_mixer", {"track_index": i, "solo": bool(solo) and n in solo})
    q("set_mixer", {"track_index": r, "mute": True, "solo": False})
    q("set_track_routing", {"track_index": r, "input_routing": source, "monitoring": 2, "arm": 1})
    before = set(rec_clips(r))
    tempo = q("get_session_info")["result"]["tempo"]
    spb = 60.0 / tempo
    q("set_song_props", {"loop": False, "record_mode": False})
    q("start_playback")
    time.sleep(0.15)
    pre = min(3.0, start)
    q("set_current_song_time", {"time": float(start - pre)})
    deadline = time.time() + 10
    retry = time.time() + 1.0
    while time.time() < deadline:
        if time.time() > retry:
            q("set_current_song_time", {"time": float(start - pre)})
            retry = time.time() + 1.0
        pos = q("get_session_info")["result"]["current_song_time"]
        if pos >= start - 1.5 and pos < start + 1:
            break
        time.sleep(0.01)
    mark = time.time()
    q("set_song_props", {"record_mode": True})
    if watch:
        t_end = time.time() + secs + 1.0
        while time.time() < t_end:
            time.sleep(min(10, max(0, t_end - time.time())))
            info = q("get_session_info")["result"]
            tr = q("get_track_info", {"track_index": r})["result"]
            sp = q("set_song_props", {})["result"]
            print("  t=%.1f playing=%s rec=%s arm=%s" % (info["current_song_time"], info["is_playing"],
                                                      sp["record_mode"], tr["arm"]), flush=True)
    else:
        time.sleep(secs + 1.0)
    q("stop_playback")
    q("set_song_props", {"record_mode": False})
    q("set_track_routing", {"track_index": r, "arm": 0})
    for i, n in enumerate(names):
        q("set_mixer", {"track_index": i, "solo": False})
    time.sleep(1.5)
    new = sorted(set(rec_clips(r)) - before)
    files = [f for f in glob.glob(os.path.expanduser("~/Music/Ableton/Live Recordings/**/*.wav"), recursive=True)
             if os.path.getmtime(f) > mark and os.path.basename(f).startswith(REC)]
    if not files or not new:
        print("no recording found")
        return None
    f = max(files, key=os.path.getmtime)
    y, sr = read_wav(f)
    clip_start = new[0][0]
    off = int(round((start - clip_start) * spb * sr))
    y = y[off:] if off >= 0 else np.vstack([np.zeros((-off, y.shape[1])), y])
    y = y[:int(secs * sr)]
    write_wav(out, y, sr)
    print("recorded %s (clip at %.3f, aligned to %.3f) -> %s" % (os.path.basename(f), clip_start, start, out))
    return out


if __name__ == "__main__":
    a = sys.argv[4:]
    src = "Resampling"
    fresh = "--fresh" in a
    watch = "--watch" in a
    a = [x for x in a if not x.startswith("--")]
    if a and a[0].startswith("src="):
        src = a[0][4:]
        a = a[1:]
    record(sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), a, src, fresh, watch)
