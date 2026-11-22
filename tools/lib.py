"""Helpers on top of AbletonMCP (port 9877): find/create tracks, load devices, set parameters."""
import time
from live import q

GLX = {
    "Click": "Presets/Instruments/Max Instrument/GLX/GLX Click",
    "Seq": "Presets/MIDI Effects/Max MIDI Effect/GLX/GLX Seq",
    "Stutter": "Presets/Audio Effects/Max Audio Effect/GLX/GLX Stutter",
    "Chaos": "Presets/Audio Effects/Max Audio Effect/GLX/GLX Chaos",
    "Util": "Presets/Audio Effects/Max Audio Effect/GLX/GLX Util",
}


def ok(r):
    if r.get("status") != "success":
        raise RuntimeError(r.get("message", r))
    return r["result"]


def names():
    n = ok(q("get_session_info"))["track_count"]
    return [ok(q("get_track_info", {"track_index": i}))["name"] for i in range(n)]


def find(name):
    ns = names()
    return ns.index(name) if name in ns else None


def devices(t, kind="track"):
    if kind == "track":
        return [d["name"] for d in ok(q("get_track_info", {"track_index": t}))["devices"]]
    return None


def make_track(name, midi=True, replace=True):
    """Create track NAME; an existing one is replaced in place (other indices stay unchanged)."""
    i = find(name)
    if i is not None and not replace:
        return i
    t = ok(q("create_midi_track" if midi else "create_audio_track", {"index": -1 if i is None else i}))["index"]
    if i is not None:
        ok(q("delete_track", {"track_index": i + 1}))
    ok(q("set_track_name", {"track_index": t, "name": name}))
    ok(q("set_track_routing", {"track_index": t, "arm": 0}))
    return t


def load_glx(t, which, wait=2.5):
    r = ok(q("load_user_sample", {"track_index": t, "path": GLX[which]}))
    time.sleep(wait)
    return r


def load_uri(t, uri, kind="track", wait=1.5):
    r = ok(q("load_browser_item_ex", {"track_index": t, "uri": uri, "kind": kind}))
    time.sleep(wait)
    return r


def params(t, d, kind="track", chain_path=None):
    p = {"track_index": t, "device_index": d, "kind": kind}
    if chain_path:
        p["chain_path"] = chain_path
    r = ok(q("get_device_parameters_ex", p))
    return {x["name"]: x for x in r["parameters"]}


def setp(t, d, values, kind="track", chain_path=None):
    p = {"track_index": t, "device_index": d, "values": values, "kind": kind}
    if chain_path:
        p["chain_path"] = chain_path
    return ok(q("set_device_parameter_ex", p))["set"]


def dev_index(t, name, kind="track"):
    info = ok(q("get_track_info", {"track_index": t})) if kind == "track" else None
    for i, d in enumerate(info["devices"]):
        if d["name"] == name:
            return i
    return None


def browse(path):
    r = ok(q("get_browser_items_at_path", {"path": path}))
    return r.get("items", []), r


def uri_of(path):
    parent, name = path.rsplit("/", 1)
    items, _ = browse(parent)
    for it in items:
        if it["name"] == name or it["name"].rsplit(".", 1)[0] == name:
            return it["uri"]
    raise KeyError("not in browser: " + path)


def load_path(t, path, kind="track", wait=2.0):
    """Load a browser item by path, e.g. 'packs/Skitter and Step/Drums/Aero Kit'."""
    return load_uri(t, uri_of(path), kind, wait)


import re as _re


def parse_display(s):
    s = s.strip()
    if "inf" in s:
        return -1e9 if s.startswith("-") else 1e9
    m = _re.search(r"[-+]?\d*\.?\d+", s)
    if not m:
        return None
    v = float(m.group(0))
    rest = s[m.end():].strip()
    if rest.startswith("k"):
        v *= 1000
    elif rest.startswith("s"):          # seconds -> ms
        v *= 1000
    return v


def setd(t, d, values, kind="track", chain_path=None, iters=22):
    """Set parameters to DISPLAY values (Hz, ms, dB, % ...) by bisection on the raw value.
    Seconds are compared in ms (pass targets for time parameters in ms)."""
    ps = params(t, d, kind, chain_path)
    out = {}
    for name, target in values.items():
        p = ps[name]
        lo, hi = p["min"], p["max"]
        f = lambda raw: parse_display(setp(t, d, {name: raw}, kind, chain_path)[name])
        flo, fhi = f(lo), f(hi)
        inc = fhi >= flo
        for _ in range(iters):
            mid = (lo + hi) / 2
            v = f(mid)
            if v is None:
                break
            if (v < target) == inc:
                lo = mid
            else:
                hi = mid
        out[name] = setp(t, d, {name: (lo + hi) / 2}, kind, chain_path)[name]
    return out


UTIL_PROPS = ["playback_mode", "slicing_playback_mode", "slicing_style", "slicing_beat_division",
              "slicing_sensitivity", "warping", "warp_mode", "voices", "retrigger", "gain", "slices",
              "delete_arrangement_clip_at"]


def util_apply(t, util_dev, target_track, target_dev, prop, value=0, chain=-1, inner=0):
    """Use GLX Util (device util_dev on track t) to set PROP on a Simpler; returns the Result."""
    setp(t, util_dev, {"Track": target_track, "Device": target_dev, "Chain": chain, "Inner": inner,
                       "Prop": UTIL_PROPS.index(prop), "Value": value, "Apply": 0})
    setp(t, util_dev, {"Apply": 1})
    time.sleep(0.4)
    setp(t, util_dev, {"Apply": 0})
    return params(t, util_dev)["Result"]["value"]


def set_enum(t, d, name, label, kind="track"):
    """Set a quantized parameter by its display label."""
    p = params(t, d, kind)[name]
    for v in range(int(p["min"]), int(p["max"]) + 1):
        if setp(t, d, {name: v}, kind)[name].strip().lower() == label.lower():
            return v
    raise ValueError("%s has no option %s" % (name, label))
