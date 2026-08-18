"""拿一份录音直接跑完整链路，把每一步的中间结果都打出来。

    python -m mixdictate_server.selftest [音频文件]

不指定文件就用 logs/last_request.wav（最近一次录音）。

存在的意义：转写出不来东西时，光看最终结果分不清是模型没输出、
热词偏置把解码带跑偏了、还是后处理把内容洗没了。这三种情况的
解法完全不同，必须先看清楚是哪一种。
"""

from __future__ import annotations

import sys
from pathlib import Path

from . import paths
from .asr import DEFAULT_MODEL, Transcriber, extract_text
from .audio import inspect_wav
from .hotwords import HotwordTable
from .postprocess import postprocess


def show(label: str, value: str) -> None:
    print(f"{label:<16} {value if value else '（空）'}")


def main() -> int:
    if len(sys.argv) > 1:
        audio = Path(sys.argv[1]).expanduser()
    else:
        audio = paths.log_dir() / "last_request.wav"

    print("=" * 60)
    print("MixDictate 自检")
    print("=" * 60)

    if not audio.exists():
        print(f"\n找不到音频文件：{audio}")
        print("先按住说话键说一句话，松开之后再跑这个命令。")
        return 1

    print(f"\n音频文件  {audio}")
    info = inspect_wav(audio.read_bytes())
    if info is None:
        print("这个文件不是合法的 WAV —— 问题出在客户端录音那一侧。")
        return 1
    print(f"音频信息  {info.summary()}")

    if info.peak < 0.01:
        print("\n峰值接近 0，这是一段静音。问题在录音，不在模型。")
        return 1

    table = HotwordTable.load(paths.hotwords_path())
    print(f"热词      {len(table.terms)} 条")

    print(f"\n加载模型 {DEFAULT_MODEL} …（首次要几秒）")
    transcriber = Transcriber()
    transcriber.warmup()

    print("\n" + "-" * 60)
    print("第 1 步：带热词偏置转写")
    print("-" * 60)
    with_context = transcriber.transcribe(str(audio), context=table.context())
    show("原始输出", with_context.text)

    print("\n" + "-" * 60)
    print("第 2 步：不带热词偏置转写")
    print("-" * 60)
    without_context = transcriber.transcribe(str(audio), context="")
    show("原始输出", without_context.text)

    raw = with_context.text or without_context.text

    print("\n" + "-" * 60)
    print("第 3 步：后处理")
    print("-" * 60)
    corrected = table.apply(raw)
    show("热词纠正后", corrected)
    show("最终输出", postprocess(corrected))

    print("\n" + "=" * 60)
    print("结论")
    print("=" * 60)
    if not with_context.text and not without_context.text:
        print("两次转写都是空的 —— 模型对这段音频没有输出。")
        print("上面应该有一条 WARNING 打印了返回值的类型和内容，")
        print("把它一起发出来。")
    elif not with_context.text and without_context.text:
        print("带热词是空的、不带热词有结果 —— 是热词偏置把解码带跑偏了。")
        print(f"热词表：{paths.hotwords_path()}")
    elif raw and not postprocess(table.apply(raw)):
        print("模型有输出，但后处理把内容洗没了 —— 这是后处理的 bug。")
    else:
        print("整条链路正常。转写服务这边没问题。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
