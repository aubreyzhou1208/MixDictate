#!/usr/bin/env bash
# MixDictate 一键安装。
#
#   ./install.sh
#
# 干四件事：建 Python 环境、装依赖、编译 App、装到「应用程序」。
# 装完之后就是个正常的 macOS App —— 双击启动，转写服务由 App 自己
# 拉起来和关掉，不用再碰终端。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT="$HOME/Library/Application Support/MixDictate"
VENV="$SUPPORT/venv"
APP_NAME="MixDictate"
INSTALLED="/Applications/$APP_NAME.app"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m错误：%s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- 环境检查

step "检查环境"

[ "$(uname -s)" = "Darwin" ] || die "这个脚本只能在 macOS 上跑。"

if [ "$(uname -m)" != "arm64" ]; then
    die "需要 Apple Silicon（M 系列芯片）。MLX 依赖 Metal，Intel Mac 跑不了。"
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || die "需要 macOS 13 或更新，当前是 $(sw_vers -productVersion)。"

command -v python3 >/dev/null || die "找不到 python3。装一个：brew install python@3.12"

if ! xcode-select -p >/dev/null 2>&1; then
    die "缺少 Xcode 命令行工具。先跑：xcode-select --install"
fi

command -v swift >/dev/null || die "找不到 swift。先跑：xcode-select --install"

echo "macOS $(sw_vers -productVersion) · $(uname -m) · $(python3 --version)"

# ---------------------------------------------------------------- Python 环境

step "准备 Python 环境（$VENV）"

mkdir -p "$SUPPORT"
if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
fi

"$VENV/bin/python" -m pip install --upgrade pip --quiet

# 非 editable 安装：装完之后 App 就不依赖这个仓库目录了，
# 你可以把源码挪走甚至删掉，App 照常运行
step "安装转写服务（含 mlx-qwen3-asr，几百 MB，慢一点）"
"$VENV/bin/python" -m pip install "$ROOT/server" --quiet
"$VENV/bin/python" -m pip install "$ROOT/server[mlx]" --quiet

# ---------------------------------------------------------------- 编译 App

step "编译 App"
"$ROOT/scripts/build_app.sh" >/dev/null

[ -d "$ROOT/build/$APP_NAME.app" ] || die "编译产物不存在，构建可能失败了。"

# ---------------------------------------------------------------- 安装

step "安装到「应用程序」"

if [ -d "$INSTALLED" ]; then
    # 旧版本还开着的话先关掉，否则复制会失败
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "$INSTALLED"
fi
cp -R "$ROOT/build/$APP_NAME.app" "$INSTALLED"

step "完成"

cat <<'DONE'

MixDictate 已经装到「应用程序」里了。

现在去启动台或「应用程序」文件夹里双击 MixDictate 就能用。
它只在菜单栏显示图标，不会出现在 Dock 里。

首次启动要做两件事，都是一次性的：

  1. 授权
     · 麦克风     —— 会自动弹窗，点「允许」
     · 辅助功能   —— 需要手动：系统设置 › 隐私与安全性 › 辅助功能，
                     点 + 号把「应用程序」里的 MixDictate 加进去并打开
                     （没有这个权限，转写出的文字插不进输入框）

  2. 等模型下载
     菜单栏图标是沙漏时说明还在启动。首次要从网上下模型，
     几分钟很正常。变成麦克风图标就可以用了。

用法：按住右 Option 说话，松开，文字出现在光标处。

想让它开机自动启动：./scripts/autostart.sh install

DONE
