#!/usr/bin/env bash
# 装 / 卸开机自启。
#
#   ./scripts/autostart.sh install
#   ./scripts/autostart.sh uninstall
#   ./scripts/autostart.sh status
#
# 只需要拉起 App —— 转写服务由 App 自己启动和关闭，不用单独管。

set -euo pipefail

AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/mixdictate"
LABEL="dev.mixdictate.app"
PLIST="$AGENTS/$LABEL.plist"
APP_BINARY="/Applications/MixDictate.app/Contents/MacOS/MixDictate"

die_missing() {
    echo "找不到 $APP_BINARY —— 先跑一次 ./install.sh" >&2
    exit 1
}

case "${1:-}" in
install)
    [ -x "$APP_BINARY" ] || die_missing
    mkdir -p "$AGENTS" "$LOGS"

    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$APP_BINARY</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- 没有 KeepAlive：它会在 App 退出后把它拉回来，菜单里的「退出」
         就变成"闪一下又回来"。开机自启的意思是登录时起一次，
         不是"你不许退出"。设置界面里那个开关装的是同一份 plist。 -->

    <key>StandardOutPath</key>
    <string>$LOGS/$LABEL.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS/$LABEL.err.log</string>
</dict>
</plist>
PLIST_EOF

    # 没装过时 bootout 会返回非 0，不算错误
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$PLIST"

    echo "已安装开机自启。日志在 $LOGS/"
    echo "登录后菜单栏图标会晚几秒出现 —— 那几秒在加载模型。"
    ;;

uninstall)
    # 先删 plist —— 决定"下次登录还起不起"的就是这个文件。
    rm -f "$PLIST"

    # bootout 会把 launchd 正管着的那个进程 SIGTERM 掉。App 正开着的时候
    # 取消开机自启，不该顺手把它关了 —— 用户说的是"以后别自己启动"。
    if launchctl print "gui/$UID/$LABEL" 2>/dev/null | grep -qE '^[[:space:]]*state = running'; then
        echo "已取消开机自启。当前这个 MixDictate 继续开着，下次登录不再自动启动。"
    else
        launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
        echo "已卸载开机自启。"
    fi
    ;;

status)
    # 看 plist 在不在，而不是看 job 加载没加载：登录时 launchd 扫的就是
    # ~/Library/LaunchAgents，job 现在在不在是本次会话的事。
    if [ -f "$PLIST" ]; then
        echo "$LABEL  开机自启：已开"
    else
        echo "$LABEL  开机自启：未开"
    fi
    if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
        echo "$LABEL  当前会话里 launchd 管着它"
    fi
    ;;

*)
    echo "用法: $0 {install|uninstall|status}" >&2
    exit 1
    ;;
esac
