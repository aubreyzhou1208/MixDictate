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
  echoCancellation    true / false   回声消除（默认关！打开会让整台电脑音量变小）
  voiceThreshold      0…1            人声门限，低于它的声音直接丢掉（默认 0.05，0=关）
                                     外放还是被转进来就调大，小声说话被吞掉就调小
                                     不用猜：菜单里有「校准人声门限…」会给建议值
  maxPauseSeconds     秒             送给模型前把长停顿压到这么短（默认 0.35，0=不压）
                                     停顿时老是被自动加句号就调小
  rawOutput           true / false   只要模型原文，不做任何加工（排查"输出很怪"用）
  liveInsertion       true / false   边说边写进输入框（不用等松手，也没有粘贴那一步）
  showLiveOverlay     true / false   录音时显示浮层
  overlayOpacity      0.2…1          浮层不透明度（默认 0.75；位置直接用鼠标拖，会自动记住）
  insertionMethod     paste / typing 输入方式
  pushToTalkKeyCode   61=右Option 58=左Option 54=右Command 62=右Control
  model               Qwen/Qwen3-ASR-0.6B 或 Qwen/Qwen3-ASR-1.7B

对识别结果的加工（都可以单独关掉）：
  stripFillers        true / false   去掉「嗯」「呃」（默认开，几乎不会误伤）
  spokenNumbers       true / false   三点一四 → 3.14（默认开）
  spokenSymbols       true / false   艾特 gmail 点 com → @gmail.com（默认开）
  fullwidthPunctuation true / false  中文标点转全角（默认开，不改内容）
  collapseRepeats     true / false   合并卡壳重复（默认关，容易误删）
  mergePausePeriods   true / false   停顿处误加的句号降级成逗号（默认开，只改标点不删字）
  splitClauses        true / false   长句里给接续词补逗号（默认开，只加标点不删字）
  learnCorrections    true / false   学习你对听写结果的修改（默认关，唯一会碰输入框的功能）

觉得哪一项在乱改你的话，直接关掉它：
  ./scripts/config.sh set spokenNumbers false
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
