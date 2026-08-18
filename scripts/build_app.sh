#!/usr/bin/env bash
# 把 SPM 产物打成一个真正的 .app bundle。
#
# 为什么不能直接跑 swift build 出来的可执行文件：
#   1. 麦克风权限弹窗要求 Info.plist 里有 NSMicrophoneUsageDescription，
#      裸二进制没有 Info.plist，会直接崩
#   2. 辅助功能授权是按"应用身份"记的，裸二进制每次重新编译身份都变，
#      你得反复重新授权
# 所以要 bundle + ad-hoc 签名。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MixDictate"
BUILD_DIR="$ROOT/app/.build/release"
BUNDLE="$ROOT/build/$APP_NAME.app"

echo "==> 编译"
cd "$ROOT/app"
swift build -c release

echo "==> 组装 $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>dev.mixdictate.app</string>
    <key>CFBundleVersion</key>           <string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>

    <!-- 菜单栏 App：不在 Dock 显示图标 -->
    <key>LSUIElement</key>               <true/>

    <key>NSMicrophoneUsageDescription</key>
    <string>MixDictate 需要麦克风来录下你的语音并在本机转成文字。音频不会离开这台电脑。</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc 签名"
codesign --force --deep --sign - "$BUNDLE"

echo
echo "构建完成： $BUNDLE"
echo "运行：     open $BUNDLE"
echo
echo "首次运行需要授予两个权限："
echo "  · 麦克风       —— 会自动弹窗"
echo "  · 辅助功能     —— 系统设置 › 隐私与安全性 › 辅助功能，手动把 $APP_NAME 加进去并打开"
echo "    （没有这个权限，转写出的文字插不进输入框）"
