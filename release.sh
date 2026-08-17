#!/bin/bash
# zhsub 一键发版 — 版本号自动同步
# 用法:
#   bash release.sh 0.1.3          # 发 v0.1.3: 改版本→提交→tag→push→打包→签名→dmg→发布
#   bash release.sh 0.1.3 --lite   # 只发布瘦身版(快)
#   bash release.sh --dry-run 0.1.3 # 只执行到打包, 不发布
#
# 流程: 更新版本号 → git 提交 → 打 tag → push → 打包(--full 完整版) →
#       签名 → 做 dmg → gh release create → 上传 dmg
set -e
cd "$(dirname "$0")"
SRC=~/zh-sub-engine

# ---- 解析参数 ----
VERSION=""
DRY=false
LITE_ONLY=false
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=true ;;
    --lite) LITE_ONLY=true ;;
    v*) VERSION="${a#v}" ;;
    *) VERSION="$a" ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "✗ 需要版本号: bash release.sh 0.1.3"
  exit 1
fi
TAG="v$VERSION"
echo "═══════════════════════════════════════"
echo "🚀 发版 zhsub $TAG  $([ "$DRY" = true ] && echo '[DRY-RUN 不发布]')"
echo "═══════════════════════════════════════"

# ---- 1. 检查版本号规范 (x.y.z) ----
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ 版本号格式应为 x.y.z (如 0.1.3)"; exit 1
fi
# 不能回退/重复
if git tag -l "$TAG" | grep -q "$TAG"; then
  echo "✗ tag $TAG 已存在! 请用新版本号"; exit 1
fi

# ---- 2. 更新源码里的版本号 ----
echo "▶ 1/8 更新版本号 → $VERSION"
# floater.swift 开发模式回退版本
sed -i '' "s/return \"[0-9]*\.[0-9]*\.[0-9]*\"/return \"$VERSION\"/" floater.swift
# pack.sh 默认版本
sed -i '' "s/\[ -z \"\$VERSION\" \] && VERSION=\"[0-9]*\.[0-9]*\.[0-9]*\"/[ -z \"\$VERSION\" ] \&\& VERSION=\"$VERSION\"/" pack.sh
echo "  ✓ 已更新 floater.swift / pack.sh"

# ---- 3. 提交 + 打 tag + push ----
echo "▶ 2/8 git 提交 + tag + push…"
git add -A
git commit -m "release v$VERSION" --allow-empty 2>&1 | tail -1
git tag "$TAG"
git push origin master 2>&1 | tail -1 || echo "  ⚠ push 可能慢, 稍后确认"
git push origin "$TAG" 2>&1 | tail -1 || echo "  ⚠ tag push 可能慢, 稍后确认"
echo "  ✓ tag: $TAG"

# ---- 4. 打包 (完整版) ----
echo "▶ 3/8 打包完整版…"
bash pack.sh --full "$VERSION" 2>&1 | tail -2

# ---- 5. 签名 ----
echo "▶ 4/8 签名…"
codesign --force -s - --timestamp=none zhsub.app/Contents/MacOS/zhsub 2>&1 | head -1
codesign --force -s - --timestamp=none zhsub.app 2>&1 | head -1
echo "  ✓ adhoc 签名完成"

# ---- 6. 做 dmg (完整版) ----
echo "▶ 5/8 制作 drag.dmg…"
rm -rf /tmp/dmgbuild && mkdir -p /tmp/dmgbuild
cp -R zhsub.app /tmp/dmgbuild/
ln -s /Applications /tmp/dmgbuild/Applications
hdiutil create -volname "zhsub 悬浮双语字幕" -srcfolder /tmp/dmgbuild -ov -format UDZO -fs HFS+ \
  "zhsub-$VERSION-drag.dmg" 2>&1 | tail -1
echo "  ✓ zhsub-$VERSION-drag.dmg ($(du -sh zhsub-$VERSION-drag.dmg | awk '{print $1}'))"

# ---- 7. 瘦身版 (可选) ----
if [ "$LITE_ONLY" = false ]; then
  echo "▶ 6/8 打包瘦身版…"
  bash pack.sh "$VERSION" 2>&1 | tail -1
  codesign --force -s - --timestamp=none zhsub.app/Contents/MacOS/zhsub 2>&1 | head -1
  codesign --force -s - --timestamp=none zhsub.app 2>&1 | head -1
  echo "▶ 7/8 制作 lite.dmg…"
  rm -rf /tmp/dmgbuild && mkdir -p /tmp/dmgbuild
  cp -R zhsub.app /tmp/dmgbuild/
  ln -s /Applications /tmp/dmgbuild/Applications
  hdiutil create -volname "zhsub 悬浮双语字幕" -srcfolder /tmp/dmgbuild -ov -format UDZO -fs HFS+ \
    "zhsub-$VERSION-lite.dmg" 2>&1 | tail -1
  echo "  ✓ zhsub-$VERSION-lite.dmg ($(du -sh zhsub-$VERSION-lite.dmg | awk '{print $1}'))"
fi

# ---- 8. 发布 ----
if [ "$DRY" = true ]; then
  echo "═══════════════════════════════════════"
  echo "⏸ DRY-RUN: 打包完成, 未发布。dmg 在本地, 可手动 gh release create"
  echo "  gh release create $TAG zhsub-$VERSION-drag.dmg [zhsub-$VERSION-lite.dmg] --title \"zhsub $TAG\" --notes \"...\""
  echo "═══════════════════════════════════════"
  exit 0
fi

echo "▶ 8/8 创建 GitHub Release + 上传…"
ASSETS="zhsub-$VERSION-drag.dmg"
[ "$LITE_ONLY" = false ] && ASSETS="$ASSETS zhsub-$VERSION-lite.dmg"
gh release create "$TAG" $ASSETS \
  --title "zhsub $TAG — 悬浮双语实时字幕" \
  --notes "## zhsub $TAG

### 安装
- **完整版** \`zhsub-$VERSION-drag.dmg\`: 内置英文模型, 开箱即用
- **瘦身版** \`zhsub-$VERSION-lite.dmg\`: 首次在设置面板下载模型

> 首次运行若提示\"无法验证开发者\": 右键 → 打开
> 若不出字幕: 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 勾选「悬浮双语字幕」

### 使用
- 拖动=移动窗口 | 滚轮=缩放 | Option+滚轮=缓冲延迟
- ⚙ 齿轮=设置(模型/渠道/代理/检查更新/退出)" 2>&1 | tail -3
echo ""
echo "═══════════════════════════════════════"
echo "✅ 发版完成: https://github.com/x000y/zhsub/releases/tag/$TAG"
echo "═══════════════════════════════════════"
