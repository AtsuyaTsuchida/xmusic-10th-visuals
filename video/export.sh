#!/bin/bash
# 通しの映像を 1 本の動画に書き出す(1920x540、30 コマ/秒、音つき)。
#   ./export.sh [出力.mov]
# - 絵はアプリが 1 コマずつ順に描いた生の画素を、そのまま ffmpeg に渡す(画面の取り込みではない)。
# - 映像は ProRes 4444 XQ(色を間引かない 4:4:4。目で分かる劣化のない、いちばん上の画質)。音は元の WAV のまま(PCM 24bit)。
# - 曲(6 分)が終わったあとも、最後の光を出し続ける。光が浮かび始めるのは 302.1 秒なので、そこから 10 分 = 902.1 秒で終わる。
#   曲のあとは同じ絵なので、最後のコマをそのまま延ばしている。音は無音。
set -e
cd "$(dirname "$0")"
OUT="${1:-out/xmusic_10th_1920x540.mov}"
APP=app/build/WaveMesh.app/Contents/MacOS/WaveMesh
AUDIO=../x-music-collage_v9_master.wav
FRAMES=10800          # 曲の長さ 360 秒 × 30
TOTAL=902.1           # 動画の長さ(秒)
PAD=$(echo "$TOTAL - 360" | bc)
"$APP" --set mode=3 --export-raw $FRAMES 2>out/export_log.txt | ffmpeg -v error -y \
  -f rawvideo -pix_fmt rgba -s 1920x540 -r 30 -i - -i "$AUDIO" \
  -filter_complex "[0:v]tpad=stop_mode=clone:stop_duration=${PAD}[v];[1:a]apad[a]" -map "[v]" -map "[a]" \
  -c:v prores_ks -profile:v 4444xq -pix_fmt yuv444p10le -vendor apl0 -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_s24le -t $TOTAL "$OUT"
echo "できました: $OUT"
