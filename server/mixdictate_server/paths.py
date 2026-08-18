"""统一的路径解析。

服务有两种运行方式，路径规则必须对两种都成立：
  · 开发时  —— 从仓库目录 pip install -e，模块在 server/ 下
  · 装好后  —— pip install 进 ~/Library/Application Support/MixDictate/venv，
               模块在 site-packages 里，仓库目录可能已经被删了

所以不能用"相对于 __file__ 往上数几层"去找仓库根目录。用户数据一律放在
Application Support 下，跟代码位置解耦。
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

APP_NAME = "MixDictate"

# 打包进 Python 包里的种子词表，首次运行时复制到用户目录
DEFAULT_HOTWORDS = Path(__file__).with_name("default_hotwords.txt")


def support_dir() -> Path:
    """用户数据目录。MIXDICTATE_HOME 可覆盖（测试和多实例用）。"""
    override = os.environ.get("MIXDICTATE_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / APP_NAME


def log_dir() -> Path:
    path = support_dir() / "logs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def hotwords_path() -> Path:
    """热词表位置。不存在就从打包的默认词表播种一份。

    播种而不是直接读包内文件，是因为用户要能编辑它 —— site-packages
    里的文件既不好找，也会在升级时被覆盖掉。
    """
    override = os.environ.get("MIXDICTATE_HOTWORDS")
    if override:
        return Path(override).expanduser()

    target = support_dir() / "hotwords.txt"
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        if DEFAULT_HOTWORDS.exists():
            shutil.copyfile(DEFAULT_HOTWORDS, target)
    return target
