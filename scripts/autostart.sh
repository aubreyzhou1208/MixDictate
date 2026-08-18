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

    <!-- 崩了自动拉起，10 秒节流，避免出问题时疯狂重启刷屏 -->
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>

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
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "已卸载开机自启。"
    ;;

status)
    if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
        echo "$LABEL  已加载"
    else
        echo "$LABEL  未加载"
    fi
    ;;

*)
    echo "用法: $0 {install|uninstall|status}" >&2
    exit 1
    ;;
esac
