#!/usr/bin/env bash
# 复查一遍那些犯过的错有没有重新出现。
#
#   ./scripts/verify.sh
#
# install.sh 和自动更新会自己调它 —— 这是刻意的：之前失败的那一环
# 恰恰是"记得去查"。清单只有自动跑才有意义。
#
# 每一条对应 CLAUDE.md 里记着的一个坑。加新检查时也把坑记到那边去。

set -uo pipefail

SUPPORT="$HOME/Library/Application Support/MixDictate"
STATUS="$SUPPORT/logs/app_status.json"
CONFIG="$HOME/.config/mixdictate/config.json"
APP="/Applications/MixDictate.app"
PORT="${MIXDICTATE_PORT:-8765}"
IDENTITY="${MIXDICTATE_SIGN_IDENTITY:-MixDictate Dev}"

fails=0
warns=0

pass() { printf '  ✅ %s\n' "$1"; }
warn() { printf '  ⚠️  %s\n' "$1"; warns=$((warns + 1)); }
fail() { printf '  ❌ %s\n' "$1"; fails=$((fails + 1)); }
fix()  { printf '     → %s\n' "$1"; }

field() { sed -n "s/.*\"$1\" : \(.*\)/\1/p" "$STATUS" 2>/dev/null | tr -d '",' | head -1; }

echo "复查 MixDictate"
echo

# ---------------------------------------------------------------- App 活着吗
echo "App"
if [ ! -d "$APP" ]; then
    fail "没装到 /Applications"
    fix "./install.sh"
elif pgrep -x MixDictate >/dev/null 2>&1; then
    pass "在运行"
else
    fail "没在运行"
    fix "open $APP"
fi

# App 自报状态。菜单栏程序没有窗口，这是唯一能从终端看到内部状态的途径。
if [ -f "$STATUS" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$STATUS") ))
    if [ "$age" -gt 60 ]; then
        warn "状态文件是 ${age} 秒前写的，可能刚重启"
    else
        pass "状态文件新鲜（${age} 秒前）"
    fi
else
    fail "没有状态文件 —— App 没跑过或版本太旧"
    fix "./install.sh && open $APP"
fi

# ---------------------------------------------------------------- 权限（坑 #3）
echo
echo "权限"
if [ -f "$STATUS" ]; then
    if [ "$(field accessibility)" = "true" ]; then
        pass "辅助功能已授权"
    else
        fail "辅助功能未授权 —— 按快捷键会完全没反应"
        fix "系统设置 › 隐私与安全性 › 辅助功能，先用 − 删掉 MixDictate 再重新 + 加回来"
        fix "（只关再开没用：开关看着是开的，那条记录已经失效）"
    fi

    if [ "$(field microphone)" = "authorized" ]; then
        pass "麦克风已授权"
    else
        fail "麦克风未授权（$(field microphone)）"
        fix "./scripts/permissions.sh reset"
    fi

    if [ "$(field hotkeyMonitorInstalled)" = "true" ]; then
        pass "说话键监听已装上（$(field hotkeyName)）"
    else
        fail "说话键监听没装上"
        fix "重启 App"
    fi
fi

# 签名身份不固定的话，上面两条早晚会再失效一次
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    pass "签名身份固定（${IDENTITY}）—— 重编译不会再掉权限"
else
    warn "还在用 ad-hoc 签名 —— 每次重编译权限都会静默失效"
    fix "./scripts/signing.sh setup"
fi

# ---------------------------------------------------------------- 采集（坑 #1 #2）
echo
echo "录音"
echo_on="$(python3 -c "
import json,sys
try:
    print(json.load(open('$CONFIG')).get('echoCancellation', False))
except Exception:
    print(False)
" 2>/dev/null)"

if [ "$echo_on" = "True" ]; then
    warn "回声消除是开的 —— 它会压低整台电脑的音量，还可能让采集变成全零"
    fix "./scripts/config.sh set echoCancellation false"
else
    pass "回声消除已关（挡外放请用 voiceThreshold）"
fi

if [ -f "$STATUS" ]; then
    fmt="$(field inputFormat)"
    if [ -n "$fmt" ]; then
        case "$fmt" in
            *" 1ch") pass "输入格式 $fmt" ;;
            "")      : ;;
            *)       warn "输入是多声道（${fmt}）—— 声道映射没生效的话采集会是全零" ;;
        esac
    fi

    # -1 = 这次启动后还没听写过，没有数据可查，不是失败
    peak="$(field lastCapturePeak)"
    case "$peak" in
        ""|-*) : ;;
        *)
            if [ "$(python3 -c "print(1 if float('$peak') > 0.01 else 0)" 2>/dev/null)" = "1" ]; then
                pass "最近一次听写麦克风峰值 $peak"
            else
                fail "最近一次听写麦克风峰值 $peak —— 采集是全零"
                fix "./scripts/config.sh set echoCancellation false"
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------- 服务
echo
echo "转写服务"
health="$(curl -sS --max-time 5 "http://127.0.0.1:${PORT}/health" 2>/dev/null)"
if [ -n "$health" ]; then
    pass "在跑"
    case "$health" in
        *'"model_loaded":true'*|*'"model_loaded": true'*) pass "模型已加载" ;;
        *) warn "模型还没加载完（首次要下载，几分钟正常）" ;;
    esac
else
    fail "连不上 http://127.0.0.1:${PORT}"
    fix "菜单栏 › 重启转写服务，或看 ./scripts/doctor.sh"
fi

# ---------------------------------------------------------------- 结论
echo
if [ "$fails" -gt 0 ]; then
    echo "❌ ${fails} 项没过、${warns} 项要注意 —— 按上面的 → 处理"
    exit 1
elif [ "$warns" -gt 0 ]; then
    echo "⚠️  全部关键项通过，${warns} 项建议处理"
else
    echo "✅ 全部通过"
fi

echo
echo "最后一步只能你来：按住说话键说一句话，看文字有没有落进输入框。"
echo "采集链路是不是真的通，只有真说一句才知道。"
