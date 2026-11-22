#!/bin/bash
# 全動画について (1) 文字の検出 (2) 1コマごとの画面変化量と明るさ を work/ に書き出す。動画は読むだけ。
# usage: scan_all.sh 動画フォルダ
SRC="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/../work"
mkdir -p "$WORK/text" "$WORK/scene"
one() {
    f="$1"
    id="$(echo "$f" | sed -E 's/.*\[([A-Za-z0-9_-]{11})\]\.mp4/\1/')"
    [ -s "$WORK/text/$id.done" ] || { "$HERE/textscan" "$f" 0.5 "$WORK/text/$id.jsonl" && echo ok > "$WORK/text/$id.done"; }
    [ -s "$WORK/scene/$id.done" ] || {
        ffmpeg -hide_banner -nostats -loglevel error -i "$f" -an \
            -vf "scale=320:-2,select='gte(scene,0)',metadata=print:key=lavfi.scene_score:file='$WORK/scene/$id.scene.txt',signalstats,metadata=print:key=lavfi.signalstats.YAVG:file='$WORK/scene/$id.yavg.txt'" \
            -f null - && echo ok > "$WORK/scene/$id.done"; }
    echo "done $id"
}
export -f one
export HERE WORK
ls -S "$SRC"/*.mp4 | tr '\n' '\0' | xargs -0 -n 1 -P 4 bash -c 'one "$0"'
echo ALL DONE
