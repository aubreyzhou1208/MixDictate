#!/usr/bin/env bash
# 从终端读写设置 —— 菜单栏图标常被刘海挤掉找不到，而 Cmd+, 对菜单栏 App
# 是不生效的（不在前台时菜单快捷键不响应）。所以必须有一条命令行的路。
#
#   ./scripts/config.sh                     看当前设置
#   ./scripts/config.sh set liveInsertion true
#   ./scripts/config.sh set pushToTalkKeyCode 54
#
# 改完立刻生效，App 会自己发现（每 2 秒查一次文件时间戳）。

set -euo pipefail

CONFIG="$HOME/.config/mixdictate/config.json"

usage() {
    cat <<'USAGE'
用法:
  ./scripts/config.sh                          显示当前设置
  ./scripts/config.sh set <字段> <值>          修改一项

常用字段：
  liveInsertion       true / false   边说边写进输入框（不用等松手，也没有粘贴那一步）
  showLiveOverlay     true / false   录音时显示浮层
  insertionMethod     paste / typing 输入方式
  pushToTalkKeyCode   61=右Option 58=左Option 54=右Command 62=右Control
  stripFillers        true / false   去掉「嗯」「呃」
  fullwidthPunctuation true / false  中文标点转全角
  model               Qwen/Qwen3-ASR-0.6B 或 Qwen/Qwen3-ASR-1.7B
USAGE
}

case "${1:-show}" in
show)
    if [ -f "$CONFIG" ]; then
        echo "$CONFIG"
        cat "$CONFIG"
    else
        echo "还没有配置文件（用的是全部默认值）"
        echo "会在第一次 set 时创建：$CONFIG"
    fi
    ;;

set)
    [ $# -eq 3 ] || { usage; exit 1; }
    mkdir -p "$(dirname "$CONFIG")"
    python3 - "$CONFIG" "$2" "$3" <<'PY'
import json
import sys
from pathlib import Path

path, key, raw = Path(sys.argv[1]), sys.argv[2], sys.argv[3]

data = {}
if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        print(f"配置文件不是合法 JSON，已重新开始：{path}")

# true/false/数字 要写成对应的 JSON 类型，写成字符串 App 会解析不出来
if raw.lower() in ("true", "false"):
    value = raw.lower() == "true"
else:
    try:
        value = int(raw)
    except ValueError:
        try:
            value = float(raw)
        except ValueError:
            value = raw

data[key] = value
path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8")
print(f"{key} = {json.dumps(value, ensure_ascii=False)}")
print(f"已写入 {path}")
print("App 会在 2 秒内自动生效，不用重启。")
PY
    ;;

*)
    usage
    exit 1
    ;;
esac
