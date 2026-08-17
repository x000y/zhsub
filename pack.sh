#!/bin/bash
# 打包 zhsub.app (macOS)
#   bash pack.sh           → 瘦身版 (模型按需下载)
#   bash pack.sh --full    → 完整版 (内置英文模型, 开箱即用)
#   bash pack.sh --full 0.1.3 → 完整版 + 指定版本号
# 版本号自动从 git tag 读取: 发版流程 = git tag v0.1.3 && bash pack.sh && gh release create ...
set -e
cd "$(dirname "$0")"
APP=zhsub.app
SRC=~/zh-sub-engine

FULL=false
VERSION_ARG=""
for a in "$@"; do
  if [ "$a" = "--full" ]; then FULL=true; else VERSION_ARG="$a"; fi
done

# ---- 版本号: 参数 > git tag > 默认 ----
if [ -n "$VERSION_ARG" ]; then
  VERSION="$VERSION_ARG"
else
  VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//') || true
  [ -z "$VERSION" ] && VERSION="0.1.2"
fi
echo "📦 打包版本: v$VERSION  模式: $([ "$FULL" = true ] && echo '完整版(内置模型)' || echo '瘦身版(按需下载)')"

echo "▶ 1/5 编译 floater…"
swiftc -O "$SRC/floater.swift" -o /tmp/zhsub-bin-floater

echo "▶ 2/5 创建 .app 结构…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" \
         "$APP/Contents/Resources/venv" "$APP/Contents/Resources/assets"
if [ "$FULL" = true ]; then
  mkdir -p "$APP/Contents/Resources/models"
fi

echo "▶ 3/5 复制引擎 + 资源…"
cp /tmp/zhsub-bin-floater "$APP/Contents/MacOS/zhsub"
cp "$SRC"/zhsub.py "$SRC"/zhsub-dl.py "$SRC"/zhsub-mt.py "$SRC"/subtitles.sh "$APP/Contents/Resources/engine/"
cp -R "$SRC/assets"/* "$APP/Contents/Resources/assets/" 2>/dev/null || true
# 图标放 Resources 根目录 (CFBundleIconFile 要求)
cp "$SRC/assets/zhsub.icns" "$APP/Contents/Resources/zhsub.icns" 2>/dev/null || true
if [ "$FULL" = true ]; then
  echo "  (完整版) 内置英文模型…"
  cp -R "$SRC/models/streaming-zipformer-en-0626" "$APP/Contents/Resources/models/" 2>/dev/null || \
    echo "  ⚠ 英文模型未找到, 跳过内置"
fi

echo "▶ 4/5 复制 Python 环境 (深度精简: 删测试/文档/下载库/多余架构)…"
rsync -a --exclude='__pycache__' --exclude='*.pyc' --exclude='tests' --exclude='docs' \
  --exclude='*.dist-info/RECORD' --exclude='bin/activate*' --exclude='bin/pip*' --exclude='bin/pytest*' \
  "$SRC/.venv/" "$APP/Contents/Resources/venv/"
# 删除运行时不需要的包: huggingface_hub 是 mlx_lm 依赖必须保留!
# 只删: pygments / PyObjCTest / pytest / dateutil(部分不需要)
SP="$APP/Contents/Resources/venv/lib/python3.12/site-packages"
rm -rf "$SP/pygments" "$SP/pygments-"* "$SP/PyObjCTest" "$SP/pytest" "$SP/pytest-"* \
       "$SP/_pytest" 2>/dev/null || true
# 只保留 arm64 架构(去掉 x86_64 slice, 原生M系)
for f in "$SP/mlx"*/*.so "$SP/numpy"*/*.so "$SP/sherpa_onnx"/*.so "$SP/transformers"/*.so; do
  [ -f "$f" ] || continue
  lipo -archs "$f" 2>/dev/null | grep -q "arm64" && lipo -archs "$f" 2>/dev/null | grep -q "x86_64" && \
    lipo -thin arm64 "$f" -output "$f" 2>/dev/null && echo "  thin: $(basename "$f")"
done
# venv python 符号链接
cp -L "$SRC/.venv/bin/python3"* "$APP/Contents/Resources/venv/bin/" 2>/dev/null || true

echo "▶ 5/5 写 Info.plist…"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>zhsub</string>
    <key>CFBundleDisplayName</key><string>悬浮双语字幕</string>
    <key>CFBundleIdentifier</key><string>com.x000y.zhsub</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>zhsub</string>
    <key>CFBundleExecutable</key><string>zhsub</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSMicrophoneUsageDescription</key><string>用于捕获系统音频进行语音识别</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>用于实时语音识别生成字幕</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

chmod +x "$APP/Contents/MacOS/zhsub"
echo "✅ 打包完成: $APP ($(du -sh "$APP" | awk '{print $1}'))"
echo "   App: $SRC/$APP  (首次运行需在设置面板下载英文ASR模型)"
