#!/bin/bash
# Slack などに上げるための MP4 を、原本(ProRes)から作る。
#   ./export_mp4.sh [原本.mov] [出力.mp4] [全体の大きさの目標(MB)]
# - H.264(High、色は 4:2:0。ブラウザや Slack の中でそのまま再生できる形式)、音は AAC 320kbps。
# - 2 回に分けて圧縮する: 1 回目で場面ごとの難しさを測り、2 回目で、全体が目標の大きさになるようデータ量を配分する
#   (黒い場面で余ったぶんが、粒子の細かい場面に回る)。Slack の上限は 1 ファイル 1GB なので、既定は 900MB。
# - 完全に劣化なしではない。止めて拡大すると、粒子のいちばん細かい点がわずかに丸くなる。高画質の原本は ProRes のほう。
set -e
cd "$(dirname "$0")"
SRC="${1:-out/xmusic_10th_1920x540.mov}"
OUT="${2:-out/xmusic_10th_1920x540_slack.mp4}"
MB="${3:-900}"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")
VB=$(echo "($MB * 8000 / $DUR) - 330" | bc)      # 映像に使えるビットレート(kbps)。音と入れ物のぶんを引く
LOG=$(mktemp -d)/x264
COMMON=(-c:v libx264 -preset slow -profile:v high -pix_fmt yuv420p -b:v ${VB}k -maxrate $(echo "$VB * 2" | bc)k -bufsize $(echo "$VB * 4" | bc)k
        -color_primaries bt709 -color_trc bt709 -colorspace bt709 -passlogfile "$LOG")
ffmpeg -v error -y -i "$SRC" "${COMMON[@]}" -pass 1 -an -f null /dev/null
ffmpeg -v error -y -i "$SRC" "${COMMON[@]}" -pass 2 -c:a aac -b:a 320k -movflags +faststart "$OUT"
echo "できました: $OUT (映像 ${VB} kbps)"
