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

    <key>CFBundleIconFile</key>          <string>AppIcon</string>

    <key>NSMicrophoneUsageDescription</key>
    <string>MixDictate 需要麦克风来录下你的语音并在本机转成文字。音频不会离开这台电脑。</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------- 图标

# 从 assets/icon.png 现做 .icns。图标是用 Python 画的（assets/make_icon.py），
# 仓库里不放二进制的 .icns —— 想换配色改几行重跑就行。
ICON_SRC="$ROOT/assets/icon.png"
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1; then
    echo "==> 生成图标"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                "128 128x128" "256 128x128@2x" "256 256x256" \
                "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
        px="${spec%% *}"
        name="${spec##* }"
        sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/icon_${name}.png" \
            >/dev/null 2>&1
    done
    if iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns" \
        2>/dev/null; then
        echo "    图标已嵌入"
    else
        # 没有图标不该让构建失败 —— 那只是不好看，不是不能用
        echo "    图标生成失败，跳过（不影响功能）"
    fi
    rm -rf "$(dirname "$ICONSET")"
fi

# 有固定身份就用固定身份。差别不在"更安全"，在于 TCC 认的是什么：
# ad-hoc 没有身份，macOS 只能拿二进制哈希当身份 —— 重编译一次哈希就变，
# 麦克风和辅助功能的授权全部对不上，而且系统设置里的开关照常显示为开。
SIGN_IDENTITY="${MIXDICTATE_SIGN_IDENTITY:-MixDictate Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> 用固定身份签名：$SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" "$BUNDLE"
    echo "    （权限不会因为重新编译而失效）"
else
    echo "==> Ad-hoc 签名"
    codesign --force --sign - "$BUNDLE"
    echo "    ⚠️  每次重编译签名都会变，麦克风/辅助功能授权会静默失效。"
    echo "       一劳永逸：./scripts/signing.sh setup"
fi

echo
echo "构建完成： $BUNDLE"
echo "运行：     open $BUNDLE"
echo
echo "首次运行需要授予两个权限："
echo "  · 麦克风       —— 会自动弹窗"
echo "  · 辅助功能     —— 系统设置 › 隐私与安全性 › 辅助功能，手动把 $APP_NAME 加进去并打开"
echo "    （没有这个权限，转写出的文字插不进输入框）"
