#!/bin/bash
# 打包 zhsub.app (macOS) — v0.1.2
# 用法: bash pack.sh
set -e
cd "$(dirname "$0")"
APP=zhsub.app
VERSION=0.1.2
SRC=~/zh-sub-engine

echo "▶ 1/5 编译 floater…"
swiftc -O "$SRC/floater.swift" -o /tmp/zhsub-bin-floater

echo "▶ 2/5 创建 .app 结构…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" \
         "$APP/Contents/Resources/venv" "$APP/Contents/Resources/models" \
         "$APP/Contents/Resources/assets"

echo "▶ 3/5 复制引擎 + 模型 + 资源…"
cp /tmp/zhsub-bin-floater "$APP/Contents/MacOS/zhsub"
cp "$SRC"/zhsub.py "$SRC"/zhsub-dl.py "$SRC"/zhsub-mt.py "$SRC"/subtitles.sh "$APP/Contents/Resources/engine/"
cp -R "$SRC/assets"/* "$APP/Contents/Resources/assets/" 2>/dev/null || true
cp -R "$SRC/models/streaming-zipformer-en-0626" "$APP/Contents/Resources/models/" 2>/dev/null || echo "  ⚠ 内置英文模型未找到(从源码目录复制)"; 

echo "▶ 4/5 复制 Python 环境 (精简)…"
# 排除缓存/测试/文档, 保留运行必需
rsync -a --exclude='__pycache__' --exclude='*.pyc' --exclude='tests' --exclude='docs' \
  --exclude='*.dist-info/RECORD' "$SRC/.venv/" "$APP/Contents/Resources/venv/"
# venv 的 python 是符号链接, 确保保留
cp -L "$SRC/.venv/bin/python3"* "$APP/Contents/Resources/venv/bin/" 2>/dev/null || true

echo "▶ 5/5 写 Info.plist + 图标…"
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
    <key>CFBundleExecutable</key><string>zhsub</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSMicrophoneUsageDescription</key><string>用于捕获系统音频进行语音识别</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>用于实时语音识别生成字幕</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
# 图标: 生成简单 app 图标 (用 GitHub mark 放大占位, 后续可换)
sips -z 512 512 "$APP/Contents/Resources/assets/github-mark.png" --out /tmp/zhsub-icon.png >/dev/null 2>&1 || true
iconutil -c icns /tmp/zhsub-icon.iconset 2>/dev/null || true

chmod +x "$APP/Contents/MacOS/zhsub"
echo "✅ 打包完成: $APP ($(du -sh "$APP" | awk '{print $1}'))"
echo "   App: $SRC/$APP"
