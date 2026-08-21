#!/usr/bin/env bash
# 自动更新：定期检查远端有没有新提交，有就拉下来重新安装。
#
#   ./scripts/autoupdate.sh run        立刻检查一次
#   ./scripts/autoupdate.sh now        立刻更新，不管你是不是刚用过
#   ./scripts/autoupdate.sh install    装成后台任务（每分钟查一次）
#   ./scripts/autoupdate.sh uninstall  卸掉
#   ./scripts/autoupdate.sh status     看状态和最近日志
#
# 安全策略（都是为了不在你正用着的时候把 App 拆了）：
#   · 工作区有未提交的改动就跳过 —— 绝不覆盖你自己的修改
#   · 只做快进合并，不自动解决冲突
#   · 三分钟内用过听写就跳过这轮，等下一轮 —— 但最多让一个版本
#     等 10 分钟，到点照装（否则一边测一边等更新会永远等不到）
#   · 编译失败时旧版本原封不动（install.sh 先编译成功才动 /Applications）

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 跟当前检出的分支走，而不是写死某一个。
#
# 写死开发分支的话，别人 clone 下来之后会被拉去追一个跟他无关的分支 ——
# 他自己在 main 上，更新却把他推到别处，而且毫无提示。
BRANCH="${MIXDICTATE_BRANCH:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    BRANCH="main"
fi
LABEL="dev.mixdictate.autoupdate"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/mixdictate"
LOG="$LOG_DIR/autoupdate.log"
TRANSCRIPTS="$HOME/Library/Application Support/MixDictate/logs/transcripts.log"
# 记着某个远端版本是什么时候第一次被推迟的，用来给推迟设个上限
PENDING="$LOG_DIR/pending_update"
# 最多推迟这么久。超过就不再等空闲了。
MAX_DEFER=600
SUPPORT="$HOME/Library/Application Support/MixDictate"
# install.sh 失败之后重试的节流点。装不上是装不上，每分钟试一遍只会刷屏。
RETRY_MARK="$LOG_DIR/install_retry"

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
    local force="${1:-}"
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
        # 但"断网"和"这个分支在远端根本不存在"必须分开。
        #
        # 后者是**永久**的：每分钟检查一次，每次都拿到空，每次都安静返回 ——
        # 于是自动更新装得好好的，却一辈子不会有动静，而这件事在任何地方
        # 都看不出来。（真的发生过：本地跟着一个已经被删掉的分支。）
        # 跟坑 #4 是同一条规矩：任何"这轮先跳过"都得有个说话的出口。
        if git ls-remote --heads origin >/dev/null 2>&1; then
            if [ "$(cat "$LOG_DIR/missing_branch" 2>/dev/null || true)" != "$BRANCH" ]; then
                printf '%s\n' "$BRANCH" > "$LOG_DIR/missing_branch"
                say "远端没有分支 ${BRANCH} —— 自动更新永远不会有动静"
                say "  换个分支：MIXDICTATE_BRANCH=main ./scripts/autoupdate.sh install"
                notify "自动更新查不到分支 ${BRANCH}，一直没在更新"
            fi
        fi
        return 0
    fi
    rm -f "$LOG_DIR/missing_branch"

    # 判据是"远端有没有我们还没有的东西"，**不是"两个 sha 一不一样"**。
    #
    # 只比相等的话，本地领先（有还没推的提交）也会被判成"发现新版本"，
    # 然后把更新的装成更旧的 —— 日志里那句
    #   发现新版本 d732b79 → 96c1ffa，开始更新
    # 就是这么来的。在开发这台机器上后果尤其烦：每提交一次，一分钟内
    # 就整个重编译、重装、重启一次 App，正好打断你手上的活。
    #
    # 没有变化时什么都不记 —— 每分钟写一行"已是最新"只会把日志淹掉，
    # 真正出问题的那几行反而找不着。
    if git merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
        # **但"仓库到位"不等于"App 到位"。**
        #
        # 上面那个快进是先做的，install.sh 是后做的。install.sh 一失败，
        # git 已经停在新提交上了 —— 下一轮进到这里，sha 相同，直接返回，
        # 于是失败被自己盖住：仓库说"已是最新"，用户用的还是旧版本，
        # 而且没有任何一处会再提起这件事。真撞上过（launchd 的 PATH 里
        # 只有系统自带的 Python 3.9，install.sh 的版本检查过不去）。
        installed_sha="$(cat "$SUPPORT/installed_sha" 2>/dev/null || true)"
        if [ -n "$installed_sha" ] && [ "$installed_sha" != "$local_sha" ]; then
            local last_try now
            last_try="$(cat "$RETRY_MARK" 2>/dev/null || echo 0)"
            now="$(date +%s)"
            # 十分钟重试一次就够。装不上是装不上，每分钟试一遍只会刷屏。
            if [ "$(( now - last_try ))" -ge 600 ] && ! recently_used; then
                printf '%s\n' "$now" > "$RETRY_MARK"
                say "仓库已经是 ${local_sha:0:7}，但装着的 App 还停在 ${installed_sha:0:7} —— 重装一次"
                if ./install.sh; then
                    say "重装成功：${local_sha:0:7}"
                    notify "已装上 ${local_sha:0:7}"
                else
                    say "重装还是失败，App 停在 ${installed_sha:0:7}"
                    notify "更新装不上，App 还是旧版本 —— 跑 ./scripts/verify.sh 看原因"
                fi
            fi
        fi
        return 0
    fi

    if [ -n "$(git status --porcelain)" ]; then
        say "有新版本，但工作区有未提交的改动，跳过（不覆盖你自己的修改）"
        return 0
    fi

    git fetch --quiet origin "$BRANCH"

    # 「正在用就先别装」这条规则单独看是对的，但它有个致命的组合：
    # 你一边测一边等新版本，每分钟都在三分钟内用过，于是更新永远排不上队 ——
    # 表现就是「我明明改了，装到机器上却一直是旧的」。所以给推迟设上限：
    # 同一个版本最多等 10 分钟，到点照装。
    local now first_seen waited pending_sha pending_since
    now="$(date +%s)"
    pending_sha=""
    pending_since="$now"
    if [ -f "$PENDING" ]; then
        read -r pending_sha pending_since < "$PENDING" || true
    fi
    if [ "$pending_sha" != "$remote_sha" ]; then
        pending_since="$now"
        printf '%s %s\n' "$remote_sha" "$now" > "$PENDING"
        first_seen=yes
    else
        first_seen=no
    fi
    waited=$(( now - pending_since ))

    if [ -z "$force" ] && recently_used && [ "$waited" -lt "$MAX_DEFER" ]; then
        # 只在第一次推迟时记一行。每分钟写一行「先跳过」会把日志淹掉，
        # 真正出问题的那几行反而找不着。
        [ "$first_seen" = yes ] && say "刚用过听写，先跳过；最多等 $(( MAX_DEFER / 60 )) 分钟就装"
        return 0
    fi

    if [ "$waited" -ge "$MAX_DEFER" ]; then
        say "已推迟 $(( waited / 60 )) 分钟，不再等了"
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
        rm -f "$PENDING"
        say "更新完成：${remote_sha:0:7}"
        # install.sh 里已经跑过一遍 verify.sh，这里再跑一次只为拿退出码：
        # 自动更新是无人值守的，回归了必须主动说，不能等用户下次用坏了才发现
        if ! ./scripts/verify.sh >/dev/null 2>&1; then
            say "复查没通过，跑 ./scripts/verify.sh 看详情"
            notify "更新装好了，但复查没通过"
        fi
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

now)
    # 手动催一下。测试的时候「我刚说完话所以它不装」是最难受的等待，
    # 得有一条命令能直接跳过那个保护。
    mkdir -p "$LOG_DIR"
    do_run force 2>&1 | tee -a "$LOG"
    echo "（没有输出就说明已经是最新的）"
    ;;

install)
    # **launchd 起的进程读不到「桌面 / 文稿 / 下载」。**
    #
    # 这几个目录受隐私保护，而 launchd 拉起来的任务没有那份授权。仓库要是
    # 放在那儿，任务每分钟启动一次、每分钟 `Operation not permitted`，
    # 一次都跑不起来 —— 而这一切只写在一个没人会去看的 .err.log 里，
    # `launchctl print` 也照样说任务装好了。装之前先挡住。
    case "$ROOT/" in
    "$HOME/Desktop/"* | "$HOME/Documents/"* | "$HOME/Downloads/"*)
        echo "仓库在 $ROOT" >&2
        echo >&2
        echo "launchd 读不到桌面、文稿、下载这三个目录，自动更新装上去也跑不起来，" >&2
        echo "而且失败得一声不吭 —— 每分钟失败一次，只在 .err.log 里留一行。" >&2
        echo >&2
        echo "把仓库挪到别处（比如 ~/MixDictate）再装。" >&2
        exit 1
        ;;
    esac

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

    # 旧任务留下的错误日志跟新任务无关了。不清掉的话，下面那条
    # 「任务跑不起来」的检查会读到上一个任务的尸体，然后对着一个刚装好的
    # 任务报故障 —— 一个自己会说谎的检查比没有检查更糟。
    : > "$LOG_DIR/${LABEL}.err.log"

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
    echo "这个脚本在：$ROOT"

    # 装着的那个任务**未必**指向这份仓库 —— 机器上可以有好几份检出，
    # 而任务里写死的是装的时候那一份。报错时必须说出它真正指向哪儿，
    # 否则用户会去挪一个根本没问题的目录。
    installed_root=""
    if [ -f "$PLIST" ]; then
        installed_script="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" \
            "$PLIST" 2>/dev/null || true)"
        [ -n "$installed_script" ] &&
            installed_root="$(dirname "$(dirname "$installed_script")")"
    fi
    if [ -n "$installed_root" ] && [ "$installed_root" != "$ROOT" ]; then
        echo "任务指向的是：$installed_root"
    fi

    # 「装上了」跟「跑得起来」是两件事。任务跑不起来时 launchctl 照样
    # 说它在，唯一的痕迹在这个错误日志里。
    err_at="$(stat -f %m "$LOG_DIR/${LABEL}.err.log" 2>/dev/null || echo 0)"
    plist_at="$(stat -f %m "$PLIST" 2>/dev/null || echo 0)"
    if [ -s "$LOG_DIR/${LABEL}.err.log" ] && [ "$err_at" -ge "$plist_at" ] &&
        tail -n 20 "$LOG_DIR/${LABEL}.err.log" | grep -q "Operation not permitted"; then
        echo "⚠️  任务根本跑不起来：launchd 没权限读 ${installed_root:-$ROOT}"
        echo "    重装一份指向读得到的目录：cd $ROOT && ./scripts/autoupdate.sh install"
    fi
    if [ -f "$LOG_DIR/missing_branch" ]; then
        echo "⚠️  远端没有分支 $(cat "$LOG_DIR/missing_branch") —— 一直没在更新"
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
    echo "用法: $0 {run|now|install|uninstall|status}" >&2
    exit 1
    ;;
esac
