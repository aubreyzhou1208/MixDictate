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

# 变量后面紧跟中文标点时必须用 ${} —— macOS 自带的 bash 3.2 在 UTF-8
# 环境下会把多字节字符的字节算进变量名，于是它会去找一个根本不存在的
# 变量（名字里带上了那个中文括号的字节），配上 set -u 直接报
# unbound variable。CI 里有一条规则专门挡这种写法。
step "准备 Python 环境（${VENV}）"

mkdir -p "$SUPPORT"
if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
fi

"$VENV/bin/python" -m pip install --upgrade pip --quiet

# 非 editable 安装：装完之后 App 就不依赖这个仓库目录了，
# 你可以把源码挪走甚至删掉，App 照常运行
step "安装转写服务"
"$VENV/bin/python" -m pip install "$ROOT/server" --quiet

# 这一步要下几百 MB，不能用 --quiet —— 屏幕空白好几分钟，谁都会以为卡死了
step "安装 mlx-qwen3-asr（几百 MB，会显示进度）"
if ! "$VENV/bin/python" -m pip install "$ROOT/server[mlx]"; then
    py_version="$("$VENV/bin/python" --version)"
    {
        printf '\n\033[31m错误：mlx-qwen3-asr 安装失败。\033[0m\n'
        printf '常见原因是 Python 版本太新，还没有对应的预编译包。\n'
        printf '当前版本：%s\n\n' "$py_version"
        printf '可以换 Python 3.12 再试：\n'
        printf '  brew install python@3.12\n'
        printf '  rm -rf "%s"\n' "$VENV"
        # shellcheck disable=SC2016  # 故意不展开：这是给用户复制的字面命令
        printf '  "$(brew --prefix)/bin/python3.12" -m venv "%s"\n' "$VENV"
        printf '  ./install.sh\n'
    } >&2
    exit 1
fi

# ---------------------------------------------------------------- 编译 App

step "编译 App"
"$ROOT/scripts/build_app.sh" >/dev/null

[ -d "$ROOT/build/$APP_NAME.app" ] || die "编译产物不存在，构建可能失败了。"

# ---------------------------------------------------------------- 安装

step "安装到「应用程序」"

# 旧版本还开着的话先关掉，否则复制会失败。
#
# 转写服务必须一起杀掉：App 退出时本该顺带关掉它，但只要有一次没关干净，
# 新 App 启动时就会探测到这个残留服务并直接接管（那是为了避免端口冲突
# 特意写的逻辑）—— 结果服务端代码更新了却永远不生效，而且毫无征兆。
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -f mixdictate_server 2>/dev/null || true
sleep 1

if [ -d "$INSTALLED" ]; then
    rm -rf "$INSTALLED"
fi
cp -R "$ROOT/build/$APP_NAME.app" "$INSTALLED"

# 每次重新编译，ad-hoc 签名的哈希都会变一个，而 macOS 的 TCC 是按签名记
# 授权的 —— 于是麦克风/辅助功能的授权可能悄悄失效，系统设置里的开关却还
# 显示是开的。表现是「明明给了权限，却一直说没听到声音」。
#
# 没法在这里替用户重新授权（那是系统的事），但至少要把话说在前面，
# 不然他会对着一个开着的开关百思不得其解。
STAMP="$SUPPORT/last_cdhash"
NEW_HASH="$(codesign -dvvv "$INSTALLED" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
if [ -f "$STAMP" ] && [ -n "$NEW_HASH" ] && [ "$NEW_HASH" != "$(cat "$STAMP")" ]; then
    printf '\n⚠️  App 签名变了，麦克风和辅助功能授权可能已失效\n'
    printf '   （系统设置里的开关会照常显示为开，但实际上不生效）\n'
    printf '   要是听写说「没有听到声音」，跑：./scripts/permissions.sh reset\n\n'
fi
[ -n "$NEW_HASH" ] && printf '%s' "$NEW_HASH" > "$STAMP"

# 装完直接启动。不只是省一步 —— macOS 只有在 App 主动请求辅助功能权限时
# 才会把它加进「隐私与安全性 › 辅助功能」的列表里。App 没跑过，用户去那个
# 列表里就是找不到它，只能手动点 + 号翻文件夹。
step "启动 MixDictate"
open "$INSTALLED"
sleep 4

# 装完自动复查一遍那些犯过的错。**不能靠人记得去跑** —— 之前失败的
# 那一环恰恰就是"记得去查"。清单只有自动执行才有意义。
# 复查不通过不算安装失败（App 已经装好了），所以不让它中断脚本。
step "复查"
"$ROOT/scripts/verify.sh" || true

step "完成"

cat <<'DONE'

MixDictate 已经装到「应用程序」里了。

现在去启动台或「应用程序」文件夹里双击 MixDictate 就能用。
它只在菜单栏显示图标，不会出现在 Dock 里。

首次启动要做两件事，都是一次性的：

  1. 授权
     · 麦克风     —— 会自动弹窗，点「允许」

     · 辅助功能   —— 关键。没有这个权限，App 收不到任何按键，
                     按住说话键会完全没反应。

                     刚才启动 App 时应该弹了一个系统对话框，点「打开系统设置」
                     然后把 MixDictate 的开关打开就行。

                     如果没弹窗，或者列表里找不到 MixDictate：
                       系统设置 › 隐私与安全性 › 辅助功能
                       点 + 号 → 在文件选择框里按 Cmd+Shift+G
                       → 输入 /Applications → 选 MixDictate

                     开关打开后不用重启 App，它每 2 秒自己检查一次，
                     生效时会弹窗告诉你。

  2. 等模型下载
     菜单栏图标是沙漏时说明还在启动。首次要从网上下模型，
     几分钟很正常。变成麦克风图标就可以用了。

用法：按住右 Option 说话，松开，文字出现在光标处。

想让它开机自动启动：./scripts/autostart.sh install

DONE
