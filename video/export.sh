#!/bin/bash
# 通しの映像を 1 本の動画に書き出す(1920x540、30 コマ/秒、音つき)。
#   ./export.sh [出力.mov]
# - 絵はアプリが 1 コマずつ順に描いた生の画素を、そのまま ffmpeg に渡す(画面の取り込みではない)。
# - 映像は ProRes 4444 XQ(色を間引かない 4:4:4。目で分かる劣化のない、いちばん上の画質)。音は元の WAV のまま(PCM 24bit)。
# - 最後の日付(2026/11/22)が出て 5 秒たったら、5 秒かけて映像と音が一緒に消える。そのあと 1 秒の黒と無音で終わる(全体 308.1 秒)。
#   音のフェードは ffmpeg でかけている(映像側のフェードと同じ時刻・同じなめらかな曲線)。
set -e
cd "$(dirname "$0")"
OUT="${1:-out/xmusic_10th_1920x540.mov}"
APP=app/build/WaveMesh.app/Contents/MacOS/WaveMesh
AUDIO=../x-music-collage_v9_master.wav
FADE_AT=302.1         # フェードが始まる時刻 = 最後のキック 296.7 + 0.4 + 5 秒
FADE_LEN=5            # フェードの長さ(アプリの dateGlowLen と同じ)
TOTAL=308.1           # 動画の長さ(秒)
FRAMES=9243           # TOTAL × 30
"$APP" --set mode=3 --export-raw $FRAMES 2>out/export_log.txt | ffmpeg -v error -y \
  -f rawvideo -pix_fmt rgba -s 1920x540 -r 30 -i - -i "$AUDIO" \
  -filter_complex "[1:a]afade=t=out:st=${FADE_AT}:d=${FADE_LEN}:curve=hsin[a]" -map 0:v -map "[a]" \
  -c:v prores_ks -profile:v 4444xq -pix_fmt yuv444p10le -vendor apl0 -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_s24le -t $TOTAL "$OUT"
echo "できました: $OUT"
