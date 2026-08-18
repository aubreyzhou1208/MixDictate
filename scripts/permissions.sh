#!/usr/bin/env bash
# 权限失效时用这个。
#
#   ./scripts/permissions.sh status   看授权状态和签名有没有变过
#   ./scripts/permissions.sh reset    重置麦克风和辅助功能授权，重新申请
#
# 为什么会失效：这个 App 是 **ad-hoc 签名**（`codesign --sign -`），没有开发者
# 证书。macOS 的 TCC 是按代码签名记授权的，而 ad-hoc 签名的哈希跟着二进制走 ——
# 每次重新编译，哈希就变一个，TCC 里那条记录就对不上了。
#
# 恶心的地方在于系统设置里那个开关**看着还是开的**，实际已经失效：麦克风照常
# 「工作」，只是送来的样本全是零。所以「我明明开了权限啊」是完全合理的困惑，
# 不是你记错了。

set -uo pipefail

BUNDLE_ID="dev.mixdictate.app"
APP="/Applications/MixDictate.app"
SUPPORT="$HOME/Library/Application Support/MixDictate"
STAMP="$SUPPORT/last_cdhash"

current_cdhash() {
    [ -d "$APP" ] || return 1
    codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1
}

case "${1:-status}" in
status)
    if [ ! -d "$APP" ]; then
        echo "App 还没装到 /Applications，先跑 ./install.sh"
        exit 0
    fi

    now="$(current_cdhash)"
    echo "Bundle ID  $BUNDLE_ID"
    echo "当前签名   ${now:-读不出来}"

    if [ -f "$STAMP" ]; then
        was="$(cat "$STAMP")"
        if [ "$now" = "$was" ]; then
            echo "签名自上次授权以来没变过 —— 授权应该还有效"
        else
            echo "上次记录   $was"
            echo
            echo "⚠️  签名变过了。系统设置里的开关可能看着是开的但已经失效。"
            echo "   跑 ./scripts/permissions.sh reset 重新走一遍授权。"
        fi
    else
        echo "还没记录过签名（这次装完会记上）"
    fi
    ;;

reset)
    echo "==> 重置授权"
    # 只重置这一个 bundle id，不动系统里其他 App 的授权
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null \
        && echo "麦克风  已重置" || echo "麦克风  重置失败（可能本来就没记录）"
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null \
        && echo "辅助功能 已重置" || echo "辅助功能 重置失败（可能本来就没记录）"

    echo
    echo "==> 重启 App"
    pkill -x MixDictate 2>/dev/null || true
    if [ -d "$APP" ]; then
        open "$APP"
        echo "麦克风会重新弹窗，点「允许」。"
        echo "辅助功能要手动加：系统设置 › 隐私与安全性 › 辅助功能 → + → MixDictate"
    else
        echo "App 不在 /Applications，先跑 ./install.sh"
    fi

    mkdir -p "$SUPPORT"
    current_cdhash > "$STAMP" 2>/dev/null || true
    ;;

*)
    echo "用法: $0 {status|reset}" >&2
    exit 1
    ;;
esac
