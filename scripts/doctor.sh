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

echo
echo "----- 报告结束 -----"
