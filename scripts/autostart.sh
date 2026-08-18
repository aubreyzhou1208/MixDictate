#!/usr/bin/env bash
# 装 / 卸开机自启（launchd LaunchAgent）。
#
#   ./scripts/autostart.sh install
#   ./scripts/autostart.sh uninstall
#   ./scripts/autostart.sh status
#
# 装两个 agent：转写服务 + 菜单栏 App。plist 在安装时按当前仓库路径生成，
# 所以仓库挪了位置要重新跑一次 install。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/mixdictate"

SERVER_LABEL="dev.mixdictate.server"
APP_LABEL="dev.mixdictate.app"
SERVER_PLIST="$AGENTS/$SERVER_LABEL.plist"
APP_PLIST="$AGENTS/$APP_LABEL.plist"

PYTHON="$ROOT/server/.venv/bin/python"
APP_BINARY="$ROOT/build/MixDictate.app/Contents/MacOS/MixDictate"

write_plist() {
    local path="$1" label="$2" program="$3" arg="${4:-}"
    local args="        <string>$program</string>"
    [ -n "$arg" ] && args="$args
        <string>$arg</string>"

    cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>

    <key>ProgramArguments</key>
    <array>
$args
    </array>

    <key>WorkingDirectory</key>
    <string>$ROOT</string>

    <key>RunAtLoad</key>
    <true/>

    <!-- 崩了自动拉起，但设 10 秒节流，避免配置写错时疯狂重启刷屏 -->
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>$LOGS/$label.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS/$label.err.log</string>
</dict>
</plist>
PLIST
}

case "${1:-}" in
install)
    [ -x "$PYTHON" ] || { echo "找不到 $PYTHON —— 先跑 make setup"; exit 1; }
    [ -x "$APP_BINARY" ] || { echo "找不到 $APP_BINARY —— 先跑 make app"; exit 1; }

    mkdir -p "$AGENTS" "$LOGS"

    write_plist "$SERVER_PLIST" "$SERVER_LABEL" "$PYTHON" "-mmixdictate_server.main"
    write_plist "$APP_PLIST" "$APP_LABEL" "$APP_BINARY"

    # bootout 会在 agent 没装过时返回非 0，这里不算错误
    launchctl bootout "gui/$UID/$SERVER_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$UID/$APP_LABEL" 2>/dev/null || true

    launchctl bootstrap "gui/$UID" "$SERVER_PLIST"
    launchctl bootstrap "gui/$UID" "$APP_PLIST"

    echo "已安装。日志在 $LOGS/"
    echo "注意：模型加载要几秒，开机后菜单栏图标出现得比登录稍晚。"
    ;;

uninstall)
    launchctl bootout "gui/$UID/$SERVER_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$UID/$APP_LABEL" 2>/dev/null || true
    rm -f "$SERVER_PLIST" "$APP_PLIST"
    echo "已卸载。"
    ;;

status)
    for label in "$SERVER_LABEL" "$APP_LABEL"; do
        if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
            echo "$label  运行中"
        else
            echo "$label  未加载"
        fi
    done
    ;;

*)
    echo "用法: $0 {install|uninstall|status}" >&2
    exit 1
    ;;
esac
