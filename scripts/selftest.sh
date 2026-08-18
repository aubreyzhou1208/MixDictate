#!/usr/bin/env bash
# 用 App 自己的 Python 环境跑一次完整链路自检。
#
#   ./scripts/selftest.sh            用最近一次录音
#   ./scripts/selftest.sh some.wav   用指定文件

set -euo pipefail

VENV="$HOME/Library/Application Support/MixDictate/venv"

if [ ! -x "${VENV}/bin/python" ]; then
    echo "找不到 Python 环境，先跑一次 ./install.sh" >&2
    exit 1
fi

exec "${VENV}/bin/python" -m mixdictate_server.selftest "$@"
