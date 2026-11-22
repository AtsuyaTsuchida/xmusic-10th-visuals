#!/bin/bash
# 書き出した音源をマスタリングする(ffmpeg だけを使う。Python では音を加工しない)。
#   master.sh 入力.wav 出力.wav [長さ秒] [終わりのフェード秒]
# 1. 24Hz より下を切る  2. 4.5kHz あたりを少し抑える(ビートの部分の耳に痛い帯域)
# 3. ゆっくり効く圧縮で、大きい部分を少し下げて全体をそろえる  4. 4倍の細かさでピークを抑え、-1 dBTP に収める
set -e
IN="$1"; OUT="$2"; LEN="${3:-420}"; FLEN="${4:-0.1}"
HP=24            # 低域カット(Hz)
EQF=4500; EQG=-2.0; EQQ=0.8     # 高めの中域の抑え
THR=-22; RATIO=1.6; MAKEUP=4.2  # 圧縮(しきい値 dB、比、持ち上げ dB)
LIMIT=-1.1       # ピークの上限(dB)
FADE=$(echo "$LEN - $FLEN" | bc)
ffmpeg -hide_banner -loglevel error -y -i "$IN" -t "$LEN" -af "
highpass=f=${HP}:poles=2,
equalizer=f=${EQF}:t=q:w=${EQQ}:g=${EQG},
acompressor=threshold=${THR}dB:ratio=${RATIO}:attack=150:release=1500:knee=6:detection=rms:link=average:makeup=${MAKEUP}dB,
aresample=192000:filter_size=64,
alimiter=limit=${LIMIT}dB:attack=5:release=80:level=false,
aresample=48000:filter_size=64,
afade=t=out:st=${FADE}:d=${FLEN}
" -c:a pcm_s24le "$OUT"
