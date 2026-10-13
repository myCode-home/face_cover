#!/usr/bin/env bash
#
# 无头自检（不需要摄像头、不需要任何权限）：
#   1. 合成逻辑   —— 坐标、缩放、偏移、镜像（含「遮罩和脸反向移动」的回归）
#   2. 录制管线   —— 真的录出 .mov 再解回来逐像素验证
#   3. 人脸跟踪   —— 相位延迟与抗抖
#   4. 音频混音   —— PCM 格式归一化、麦克风+系统声音混音、饱和、时间轴
#   5. 录像库     —— 扫描、排序、时长/大小、缩略图、删除
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(uname -m)-apple-macos14.0"
BUILD="$ROOT/.build"
mkdir -p "$BUILD"

STATUS=0
run() {
  local name="$1"; shift
  echo
  echo "=============================================="
  echo " $name"
  echo "=============================================="
  swiftc -swift-version 5 -target "$TARGET" -o "$BUILD/$1" "${@:2}"
  "$BUILD/$1" || STATUS=1
}

run "1/5  合成逻辑" CompositorCheck \
  "$ROOT/Sources/Compositor.swift" "$ROOT/Tests/Compositor/main.swift"

run "2/5  录制管线（端到端）" RecorderCheck \
  "$ROOT/Sources/Compositor.swift" "$ROOT/Sources/Recorder.swift" \
  "$ROOT/Tests/Recorder/main.swift"

run "3/5  人脸跟踪：相位延迟" TrackerCheck \
  "$ROOT/Sources/FaceTracker.swift" "$ROOT/Tests/Tracker/main.swift"

run "4/5  音频混音" MixerCheck \
  "$ROOT/Sources/AudioSource.swift" "$ROOT/Sources/AudioMixer.swift" \
  "$ROOT/Tests/Mixer/main.swift"

run "5/5  录像库" LibraryCheck \
  "$ROOT/Sources/AppPaths.swift" "$ROOT/Sources/Compositor.swift" \
  "$ROOT/Sources/Recorder.swift" "$ROOT/Sources/RecordingLibrary.swift" \
  "$ROOT/Tests/Library/main.swift"

echo
if [ "$STATUS" -eq 0 ]; then
  echo "所有自检通过 ✅"
else
  echo "有自检未通过 ❌"
fi
exit "$STATUS"
