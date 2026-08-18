"""拿一份录音直接跑完整链路，把每一步的中间结果都打出来。

    python -m mixdictate_server.selftest [音频文件]

不指定文件就用 logs/last_request.wav（最近一次录音）。

存在的意义：转写出不来东西时，光看最终结果分不清是模型没输出、
热词偏置把解码带跑偏了、还是后处理把内容洗没了。这三种情况的
解法完全不同，必须先看清楚是哪一种。
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from . import paths
from .asr import DEFAULT_MODEL, Transcriber, extract_text
from .audio import inspect_wav
from .hotwords import HotwordTable
from .postprocess import postprocess


PORT = int(os.environ.get("MIXDICTATE_PORT", 8765))


def ask_live_server(audio: Path) -> tuple[bool, str]:
    """把同一个文件走 HTTP 打到正在跑的服务上。

    直接调模型能出字、走服务出不来字，说明问题在服务这一层（或者跑着的
    是残留的旧服务），而不是模型。这两种情况没法靠猜区分。
    """
    boundary = f"selftest.{uuid.uuid4()}"
    payload = audio.read_bytes()

    body = b"".join([
        f"--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="audio"; filename="speech.wav"\r\n',
        b"Content-Type: audio/wav\r\n\r\n",
        payload,
        f"\r\n--{boundary}--\r\n".encode(),
    ])

    request = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/transcribe",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return True, json.loads(response.read()).get("text", "")
    except urllib.error.HTTPError as exc:
        # 服务是活的，只是处理请求时出错了 —— 跟"连不上"完全是两回事。
        # 服务端出错时会把异常信息放在响应体里，那正是我们要的东西。
        detail = ""
        try:
            detail = json.loads(exc.read()).get("error", "")
        except (ValueError, OSError):
            pass
        return False, f"服务返回 HTTP {exc.code}：{detail or '（响应体里没有错误详情）'}"
    except urllib.error.URLError as exc:
        return False, f"连不上服务：{exc.reason}"
    except (ValueError, OSError) as exc:
        return False, f"请求失败：{exc}"


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

    print("\n" + "-" * 60)
    print("第 4 步：走正在运行的服务（跟 App 走的是同一条路）")
    print("-" * 60)
    reachable, live = ask_live_server(audio)
    if reachable:
        show("服务返回", live)
    else:
        print(live)
        print()
        print("服务日志最后 25 行：")
        print("-" * 60)
        log_file = paths.log_dir() / "server.log"
        if log_file.exists():
            lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
            for line in lines[-25:]:
                print(line)
        else:
            print(f"（没有 {log_file}）")
        print("-" * 60)

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
    elif reachable and not live.strip():
        print("直接调模型有结果，走服务却是空的 —— 问题在服务这一层。")
        print("最常见的原因是跑着的还是残留的旧服务：")
        print("  pkill -f mixdictate_server; pkill -x MixDictate; open -a MixDictate")
    elif not reachable:
        print("直接调模型没问题，但走服务这条路失败了。")
        print("上面的服务日志里应该有一段 traceback —— 那就是根因。")
    else:
        print("整条链路都正常，包括正在运行的服务。")
        print("现在按住说话键说一句话，文字应该会出现在光标处。")
        print("如果还是不行，问题在 App 那一侧 —— 把服务日志发出来：")
        print(f"  open \"{paths.log_dir() / 'server.log'}\"")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
