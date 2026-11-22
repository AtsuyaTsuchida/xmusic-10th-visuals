#!/bin/bash
# 音に合わせて動く横一本の波形だけの映像を作る(素材映像は使わない)。
#   wave.sh 音源.wav 出力.mp4 [開始秒 長さ秒]
# 画面は 1920x540 (32:9)。1コマに、その瞬間の音 1/FPS 秒ぶんを左から右へ描く。
# 倍の大きさで描いてから縮めて、線のギザギザを取っている。
set -e
IN="$1"; OUT="$2"; SS="${3:-0}"; DUR="$4"

W=1920; H=540        # 仕上がりの大きさ
FPS=30               # コマ数
SS2=2                # 何倍で描いてから縮めるか
GAIN=1.0             # 波の高さ(表示だけ。音は変えない)
THICK=2              # 線を太らせる回数
LAG=1                # 描画が音より遅れるコマ数(頭から捨てて合わせる。段差の試験音で確認済み)

BW=$((W*SS2)); BH=$((H*SS2))
RATE=$((FPS*BW))     # 横1列に音1点が来るよう、表示用にだけ細かく取り直す

DIL=""
for i in $(seq 1 $THICK); do DIL="$DIL,dilation"; done

RANGE=()
if [ -n "$DUR" ]; then RANGE=(-ss "$SS" -t "$DUR"); fi

ffmpeg -hide_banner -loglevel error -stats -y "${RANGE[@]}" -i "$IN" -filter_complex "
[0:a]asplit[a][v0];
[v0]pan=mono|c0=0.5*c0+0.5*c1,volume=${GAIN},aresample=${RATE},
    showwaves=s=${BW}x${BH}:mode=p2p:n=1:rate=${FPS}:colors=white:scale=lin:draw=full,
    trim=start_frame=${LAG},setpts=PTS-STARTPTS,tpad=stop=${FPS}:stop_mode=clone,
    format=gray${DIL},scale=${W}:${H}:flags=area,format=yuv420p[v]
" -map "[v]" -map "[a]" -fps_mode passthrough -shortest \
  -c:v libx264 -crf 14 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 320k -movflags +faststart "$OUT"
