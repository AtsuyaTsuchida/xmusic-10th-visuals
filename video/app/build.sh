#!/bin/bash
# WaveMesh.app を作る(Swift + Metal、外部ライブラリなし)。
#   ./build.sh [音源.wav]
# 音源はアプリの中(Contents/Resources/audio.wav)にコピーするので、できた .app だけで動く。
# 音源を省くと ../../x-music-collage_v9_master.wav を入れる。
set -e
cd "$(dirname "$0")"
AUDIO="${1:-../../x-music-collage_v9_master.wav}"
APP=build/WaveMesh.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -o "$APP/Contents/MacOS/WaveMesh" Sources/*.swift \
  -framework Cocoa -framework Metal -framework MetalKit -framework AVFoundation

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WaveMesh</string>
  <key>CFBundleDisplayName</key><string>WaveMesh</string>
  <key>CFBundleIdentifier</key><string>local.wavemesh</string>
  <key>CFBundleExecutable</key><string>WaveMesh</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

if [ -f "$AUDIO" ]; then
  CUES="${AUDIO%.*}.cues.json"   # ドラムが鳴る時刻の一覧(tools/cues.py で作る)。あれば一緒に入れる
  if [ -f "$CUES" ]; then cp "$CUES" "$APP/Contents/Resources/audio.cues.json"; echo "時刻の一覧: $CUES"; fi
  cp "$AUDIO" "$APP/Contents/Resources/audio.wav"
  echo "音源: $AUDIO"
else
  echo "音源が見つかりません: $AUDIO (起動時に選ぶ窓が出ます)"
fi
# 脳のシーンで使うメッシュ(左右の半球)。あれば一緒に入れる
BRAIN="${BRAIN_MESH_DIR:-../../../brain-mesh}"
if [ -f "$BRAIN/lh-nih3d.stl" ] && [ -f "$BRAIN/rh-nih3d.stl" ]; then
  cp "$BRAIN/lh-nih3d.stl" "$BRAIN/rh-nih3d.stl" "$APP/Contents/Resources/"
  echo "脳のメッシュ: $BRAIN"
else
  echo "脳のメッシュが見つかりません: $BRAIN (脳のシーンは出ません)"
fi
# 脳のシーンで出す CT 画像(横断・冠状断・矢状断の連番)。あれば一緒に入れる
CT="${CT_DIR:-../../../brain-ct/slices}"
if ls "$CT"/axial/*.png >/dev/null 2>&1; then
  for d in axial coronal sagittal; do mkdir -p "$APP/Contents/Resources/ct/$d" && cp "$CT/$d"/*.png "$APP/Contents/Resources/ct/$d/"; done
  echo "CT 画像: $CT"
else
  echo "CT 画像が見つかりません: $CT (スキャンに画像は出ません)"
fi
# 通しの終盤に流す動画(tools/kickreel.py で前もって 1 本に組んだもの)。あれば一緒に入れる
REEL="${KICKREEL:-../work/kickreel.mp4}"
if [ -f "$REEL" ]; then cp "$REEL" "$APP/Contents/Resources/kickreel.mp4"; echo "終盤の動画: $REEL"; else echo "終盤の動画がありません: $REEL (その区間は脳のシーンのままになります)"; fi
# タイポグラフィのパートの後半に置くロゴの形(tools/logo_mask.py で抜き出したもの)。あれば一緒に入れる
LOGO="${LOGO_MASK:-../assets/xmusic_logo_mask.png}"
if [ -f "$LOGO" ]; then cp "$LOGO" "$APP/Contents/Resources/xmusic_logo_mask.png"; echo "ロゴ: $LOGO"; fi
ICON="${ICON_MASK:-../assets/neuromusic_icon_mask.png}"
if [ -f "$ICON" ]; then cp "$ICON" "$APP/Contents/Resources/neuromusic_icon_mask.png"; echo "アイコン: $ICON"; fi
WORD="${WORDMARK_MASK:-../assets/neuromusic_wordmark_mask.png}"
if [ -f "$WORD" ]; then cp "$WORD" "$APP/Contents/Resources/neuromusic_wordmark_mask.png"; fi
# x-Music のロゴのうしろに流す、小田急のドラムセッションの動画。あれば一緒に入れる
ODAKYU="${ODAKYU:-$(ls ../../../x-music-videos/notext/*Odakyu*.mp4 2>/dev/null | head -1)}"
if [ -f "$ODAKYU" ]; then cp "$ODAKYU" "$APP/Contents/Resources/odakyu.mp4"; echo "小田急の動画: $ODAKYU"; fi
CYCLE="${CYCLEREEL:-../work/cyclereel.mp4}"
if [ -f "$CYCLE" ]; then cp "$CYCLE" "$APP/Contents/Resources/cyclereel.mp4"; echo "順番の動画: $CYCLE"; fi
codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "できました: $(pwd)/$APP"
