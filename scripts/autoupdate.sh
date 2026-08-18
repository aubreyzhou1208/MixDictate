#!/usr/bin/env bash
# 自动更新：定期检查远端有没有新提交，有就拉下来重新安装。
#
#   ./scripts/autoupdate.sh run        立刻检查一次
#   ./scripts/autoupdate.sh install    装成后台任务（每分钟查一次）
#   ./scripts/autoupdate.sh uninstall  卸掉
#   ./scripts/autoupdate.sh status     看状态和最近日志
#
# 安全策略（都是为了不在你正用着的时候把 App 拆了）：
#   · 工作区有未提交的改动就跳过 —— 绝不覆盖你自己的修改
#   · 只做快进合并，不自动解决冲突
#   · 三分钟内用过听写就跳过这轮，等下一轮
#   · 编译失败时旧版本原封不动（install.sh 先编译成功才动 /Applications）

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="claude/open-source-speech-to-text-9ntena"
LABEL="dev.mixdictate.autoupdate"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/mixdictate"
LOG="$LOG_DIR/autoupdate.log"
TRANSCRIPTS="$HOME/Library/Application Support/MixDictate/logs/transcripts.log"

say() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

notify() {
    osascript -e "display notification \"$1\" with title \"MixDictate\"" 2>/dev/null || true
}

recently_used() {
    # 三分钟内写过转写记录 = 正在用，这轮别打扰
    [ -f "$TRANSCRIPTS" ] || return 1
    local age
    age=$(( $(date +%s) - $(stat -f %m "$TRANSCRIPTS") ))
    [ "$age" -lt 180 ]
}

do_run() {
    cd "$ROOT"

    local local_sha remote_sha
    local_sha="$(git rev-parse HEAD)"

    # 先用 ls-remote 问一句"远端最新是什么"。它只走一次 HTTPS 往返、
    # 不下载任何对象，几十毫秒就回来 —— 便宜到可以每分钟跑一次，
    # 效果上就接近"推完立刻装"。真有更新时才做完整的 fetch。
    #
    # 拿不到就安静退出：可能只是断网或者在飞行模式，不值得吵用户。
    remote_sha="$(git ls-remote --heads origin "$BRANCH" 2>/dev/null | cut -f1)"
    if [ -z "$remote_sha" ]; then
        return 0
    fi

    # 没有变化时什么都不记 —— 每分钟写一行"已是最新"只会把日志淹掉，
    # 真正出问题的那几行反而找不着
    if [ "$local_sha" = "$remote_sha" ]; then
        return 0
    fi

    if [ -n "$(git status --porcelain)" ]; then
        say "有新版本，但工作区有未提交的改动，跳过（不覆盖你自己的修改）"
        return 0
    fi

    git fetch --quiet origin "$BRANCH"

    if recently_used; then
        say "刚用过听写，这轮先跳过，等下一轮"
        return 0
    fi

    say "发现新版本 ${local_sha:0:7} → ${remote_sha:0:7}，开始更新"
    notify "正在更新到 ${remote_sha:0:7}…"

    # 只快进。有分叉说明本地有额外提交，那种情况需要人来判断
    if ! git merge --ff-only "origin/${BRANCH}"; then
        say "无法快进合并（本地有分叉提交），需要手动处理"
        notify "自动更新失败：本地有分叉提交"
        return 1
    fi

    if ./install.sh; then
        say "更新完成：${remote_sha:0:7}"
        notify "已更新到 ${remote_sha:0:7}"
    else
        say "install.sh 失败，旧版本保持不变"
        notify "更新失败，仍在用旧版本"
        return 1
    fi
}

case "${1:-run}" in
run)
    mkdir -p "$LOG_DIR"
    # 没有更新时 do_run 不产出任何内容，日志不会被每分钟一行的噪音淹掉
    do_run 2>&1 | tee -a "$LOG"
    ;;

install)
    mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${ROOT}/scripts/autoupdate.sh</string>
        <string>run</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${ROOT}</string>

    <!-- 每分钟查一次。一次检查只是 git ls-remote：一次 HTTPS 往返、
         不下载对象、几十毫秒。真有更新才会 fetch 并重新编译。 -->
    <key>StartInterval</key>
    <integer>60</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/${LABEL}.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/${LABEL}.err.log</string>
</dict>
</plist>
PLIST_EOF

    launchctl bootout "gui/${UID}/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/${UID}" "$PLIST"

    echo "已开启自动更新，每分钟检查一次。"
    echo "日志：$LOG"
    echo "以后我推送的改动会自己装到你机器上，不用再手动跑命令。"
    ;;

uninstall)
    launchctl bootout "gui/${UID}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    echo "已关闭自动更新。"
    ;;

status)
    if launchctl print "gui/${UID}/${LABEL}" >/dev/null 2>&1; then
        echo "自动更新：已开启（每分钟检查一次）"
    else
        echo "自动更新：未开启"
    fi
    echo
    if [ -f "$LOG" ]; then
        echo "最近记录："
        tail -n 15 "$LOG"
    else
        echo "还没有更新日志"
    fi
    ;;

*)
    echo "用法: $0 {run|install|uninstall|status}" >&2
    exit 1
    ;;
esac
