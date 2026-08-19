#!/usr/bin/env bash
# 一次性收集排错需要的所有信息。
#
#   ./scripts/doctor.sh
#
# 把输出整段复制粘贴出来即可。不包含录音内容和任何密钥。

set -uo pipefail   # 故意不加 -e：某一项检查失败也要继续跑完剩下的

SUPPORT="$HOME/Library/Application Support/MixDictate"
VENV="$SUPPORT/venv"
LOGS="$SUPPORT/logs"
CONFIG="$HOME/.config/mixdictate/config.json"
APP="/Applications/MixDictate.app"
PORT="${MIXDICTATE_PORT:-8765}"

section() { printf '\n----- %s -----\n' "$1"; }
yes_no()  { if [ "$1" = 0 ]; then echo "是"; else echo "否"; fi; }

echo "MixDictate 诊断报告"

section "系统"
echo "macOS   $(sw_vers -productVersion 2>/dev/null)"
echo "架构    $(uname -m)"
echo "python3 $(python3 --version 2>&1)"

# 「我装上的到底是不是最新的」必须能一眼看出来。看不出来的时候，
# 「改了没生效」和「改了但没修好」长得一模一样，而这两件事完全不同。
section "版本"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="${MIXDICTATE_BRANCH:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || BRANCH="main"
# 仓库路径要显式打出来。克隆到哪儿完全取决于当初在哪儿敲的 git clone，
# 过几天没人记得住 —— 而所有维护命令都得在仓库里跑。
echo "仓库路径  $ROOT"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "本地仓库  $(git -C "$ROOT" log -1 --format='%h  %ad  %s' --date=format:'%m-%d %H:%M' 2>/dev/null)"
    remote_sha="$(git -C "$ROOT" ls-remote --heads origin "$BRANCH" 2>/dev/null | cut -f1)"
    local_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
    if [ -z "$remote_sha" ]; then
        echo "远端最新  查不到（可能是断网）"
    elif [ "$remote_sha" = "$local_sha" ]; then
        echo "远端最新  ${remote_sha:0:7}  已是最新"
    else
        echo "远端最新  ${remote_sha:0:7}  ← 本地落后，跑 ./scripts/autoupdate.sh now"
    fi
else
    echo "不是 git 仓库，无法判断版本"
fi

# 拉下来了不等于装上了：install.sh 要重新编译再拷进 /Applications。
# 这一行回答的是「跑着的那个 App 是什么时候编出来的」。
BIN="$APP/Contents/MacOS/MixDictate"
if [ -x "$BIN" ]; then
    echo "已安装 App 编译于  $(stat -f '%Sm' -t '%m-%d %H:%M' "$BIN" 2>/dev/null)"
    if [ "$BIN" -ot "$ROOT/app/Sources/MixDictate/AppDelegate.swift" ]; then
        echo "  ⚠️ 源码比它新 —— 装上的是旧版本，跑 ./install.sh"
    fi
fi

# App 自己写的状态。「按快捷键完全没反应」在终端里本来是不可见的 ——
# 权限有没有、监听装没装上、听的是哪个键，只有 App 知道，而它连窗口都没有。
section "App 自报状态"
STATUS="$LOGS/app_status.json"
if [ -f "$STATUS" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$STATUS") ))
    if [ "$age" -gt 30 ]; then
        echo "⚠️  状态是 ${age} 秒前写的 —— App 多半没在运行"
        echo "   打开它：open /Applications/MixDictate.app"
    else
        echo "App 在运行（状态 ${age} 秒前刷新）"
    fi
    cat "$STATUS"
    # 输入格式的声道数是关键：语音处理单元会把它变成多声道，
    # 而声道数不匹配的转换会安静地输出全零
    if grep -q '"inputFormat" : "[0-9]*Hz [2-9]' "$STATUS" 2>/dev/null \
        && grep -q '"echoCancellation" : true' "$STATUS" 2>/dev/null; then
        echo
        echo "⚠️  回声消除开着，且输入是多声道 —— 这个组合会让采集变成全零"
        echo "   ./scripts/config.sh set echoCancellation false"
    fi
    if grep -q '"accessibility" : false' "$STATUS" 2>/dev/null; then
        echo
        echo "⚠️  没有辅助功能权限 —— 按键事件根本到不了 App，快捷键必然毫无反应"
        echo "   1. 系统设置 › 隐私与安全性 › 辅助功能，把 MixDictate 那条用 − 删掉"
        echo "   2. ./scripts/permissions.sh reset"
        echo "   3. 重新用 + 把 /Applications/MixDictate.app 加回去并打开开关"
        echo "   （删掉再加回来是关键：开关看着是开的但记录已经失效，只关再开没用）"
    fi
else
    echo "还没有状态文件。App 没跑过，或者装的是旧版本。"
    echo "  open /Applications/MixDictate.app"
fi

section "安装状态"
[ -d "$APP" ]; echo "App 已安装（/Applications）  $(yes_no $?)"
[ -x "$VENV/bin/python" ]; echo "Python 环境已建立            $(yes_no $?)"

if [ -x "$VENV/bin/python" ]; then
    echo "venv Python  $("$VENV/bin/python" --version 2>&1)"
    if "$VENV/bin/python" -c "import mlx_qwen3_asr" 2>/dev/null; then
        echo "mlx-qwen3-asr 可导入          是"
    else
        echo "mlx-qwen3-asr 可导入          否  <<< 转写服务起不来的常见原因"
    fi
fi

section "进程"
if pgrep -x MixDictate >/dev/null 2>&1; then
    echo "App 进程          运行中（PID $(pgrep -x MixDictate | tr '\n' ' ')）"
else
    echo "App 进程          没在跑  <<< 去「应用程序」里双击 MixDictate"
fi

if pgrep -f mixdictate_server >/dev/null 2>&1; then
    echo "转写服务进程      运行中"
else
    echo "转写服务进程      没在跑"
fi

section "服务健康检查"
health="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" 2>&1)"
if [ -n "$health" ]; then
    echo "$health"
    echo
    echo "started_at 比你最近一次 ./install.sh 还早，说明跑的是残留的旧服务，"
    echo "新代码没生效。这样解决："
    echo "  pkill -f mixdictate_server; pkill -x MixDictate; open -a MixDictate"
else
    echo "连不上 http://127.0.0.1:${PORT}/health"
fi

section "模型缓存"
cache="$HOME/.cache/huggingface"
if [ -d "$cache" ]; then
    echo "$(du -sh "$cache" 2>/dev/null | cut -f1)  ($cache)"
    echo "（0.6B 模型下完大约 1-2 GB；明显小于这个数说明还在下或者下失败了）"
else
    echo "还没有模型缓存 —— 模型没下载过"
fi

section "配置"
if [ -f "$CONFIG" ]; then
    cat "$CONFIG"
else
    echo "没有配置文件，用的是全部默认值（说话键 = 右 Option）"
fi

section "转写服务日志（最后 40 行）"
if [ -f "$LOGS/server.log" ]; then
    tail -n 40 "$LOGS/server.log"
else
    echo "还没有日志 —— 服务从来没被启动过"
fi

section "最近一次录音"
if [ -f "$LOGS/last_request.wav" ]; then
    # 用 wc 而不是解析 ls 的输出：ls 的格式不保证，shellcheck 也会报 SC2012
    bytes="$(wc -c < "$LOGS/last_request.wav" | tr -d ' ')"
    echo "${bytes} 字节  $LOGS/last_request.wav"
    echo "用播放器打开听一下："
    echo "  open \"$LOGS/last_request.wav\""
    echo "能听清自己说话 → 录音链路没问题，问题在模型或热词"
    echo "听不清 / 是静音   → 问题在录音链路（麦克风权限、输入设备）"
else
    echo "还没有 —— 说明没有一次完整的转写请求到达过服务端"
fi

section "转写记录"
if [ -f "$LOGS/transcripts.log" ]; then
    echo "共 $(grep -c '^  原始:' "$LOGS/transcripts.log" 2>/dev/null || echo 0) 条"
    echo "最后 3 条："
    tail -n 12 "$LOGS/transcripts.log"
else
    echo "一条都没有 —— 说明音频从来没送到过服务端"
    echo "（按住说话键完全没反应时，最常见的原因是缺辅助功能权限："
    echo "  全局按键监听需要这个权限，没有它 App 收不到任何按键）"
fi

section "权限（命令行读不到，需要自己确认）"
echo "菜单栏图标 → 设置… → 顶部「权限」那一栏会同时显示麦克风和辅助功能的状态。"
echo
echo "· 麦克风未授权   —— 浮层出来但一直空着，松开也没有文字"
echo "   系统设置 › 隐私与安全性 › 麦克风"
echo
echo "· 辅助功能未授权 —— 按住说话键完全没反应，浮层都不出现"
echo "命令行读不到这个状态（系统限制）。"
echo "自己确认：菜单栏图标 → 设置… → 顶部「权限」那一栏。"
echo "或者：系统设置 › 隐私与安全性 › 辅助功能，看 MixDictate 的开关是不是开的。"
echo
echo "如果列表里找不到 MixDictate，或者开关打开了也没用："
echo "  权限是按代码签名记的，而每次 ./install.sh 都会重新 ad-hoc 签名，"
echo "  旧记录会跟新签名对不上。清空重来："
echo
echo "    tccutil reset Accessibility dev.mixdictate.app"
echo "    pkill -x MixDictate"
echo "    open -a MixDictate"
echo
echo "  重启后系统会重新弹授权对话框。"

section "常用命令（不用找菜单栏图标）"
cat <<CMDS
听最近一次录音：
  open "$LOGS/last_request.wav"

看转写记录（原始输出 vs 处理后）：
  open "$LOGS/transcripts.log"

看服务日志：
  open "$LOGS/server.log"

改热词表：
  open -e "$SUPPORT/hotwords.txt"

重启 App：
  pkill -x MixDictate; open -a MixDictate

菜单栏图标是个麦克风符号，在右侧时钟那一排。
按住 Cmd 拖动可以重新排序 —— 拖到时钟旁边就不会被刘海挤掉了。
CMDS

echo
echo "----- 报告结束 -----"
