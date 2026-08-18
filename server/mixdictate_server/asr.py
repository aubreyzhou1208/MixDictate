"""mlx-qwen3-asr 的薄封装。

模型只在进程内加载一次（首次转写时懒加载），之后每次听写复用同一个
Session。0.6B 在 M2 Pro 上首次加载约 3-10 秒，之后单次几秒钟的音频
延迟在 1 秒以内。

设了 MIXDICTATE_BACKEND=mock 时走假后端，方便在非 Apple Silicon 机器上
跑测试和调后处理链路。
"""

from __future__ import annotations

import asyncio
import logging
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

log = logging.getLogger(__name__)

DEFAULT_MODEL = "Qwen/Qwen3-ASR-0.6B"


def extract_text(result: object) -> str:
    """从模型返回值里取出转写文本。

    不同版本的 mlx-qwen3-asr 返回的东西不一样：可能是带 .text 的对象、
    直接的字符串、字典，或者一串分段。原来只认 .text 一种形状，
    其余情况一律静默变成空字符串 —— 这种失败方式最难查，因为它跟
    "模型确实没听出内容"长得一模一样。
    """
    if result is None:
        return ""

    if isinstance(result, str):
        return result.strip()

    if isinstance(result, dict):
        for key in ("text", "transcription", "transcript"):
            value = result.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        segments = result.get("segments")
        if segments:
            return join_segments(segments)
        return ""

    for attribute in ("text", "transcription", "transcript"):
        value = getattr(result, attribute, None)
        if isinstance(value, str) and value.strip():
            return value.strip()

    segments = getattr(result, "segments", None)
    if segments:
        return join_segments(segments)

    # 分段列表直接被返回的情况
    if isinstance(result, (list, tuple)) and result:
        return join_segments(result)

    return ""


def join_segments(segments: object) -> str:
    """把分段列表拼成一整句。段与段之间不加空格 —— 中文不用空格分词。"""
    if not isinstance(segments, (list, tuple)):
        return ""

    parts: list[str] = []
    for segment in segments:
        if isinstance(segment, str):
            parts.append(segment)
        elif isinstance(segment, dict):
            parts.append(str(segment.get("text", "")))
        else:
            parts.append(str(getattr(segment, "text", "")))
    return "".join(parts).strip()


@dataclass
class ASRResult:
    text: str
    language: str | None = None


class Transcriber:
    """所有 MLX 操作都固定在同一个线程上执行。

    MLX 的 GPU stream 是线程局部的：在 A 线程加载模型、到 B 线程做推理，
    会直接抛 "There is no Stream(gpu, 1) in current thread."。
    用 asyncio.to_thread 就正好踩中这个 —— 每次可能落到不同的工作线程上。

    所以这里用一个 max_workers=1 的执行器：模型加载和每次推理都在它那
    唯一的线程上跑。事件循环不会被阻塞，线程亲和性也得到保证。
    顺带还天然把推理串行化了（模型本来也不是线程安全的）。
    """

    def __init__(self, model: str = DEFAULT_MODEL) -> None:
        self.model = model
        self._session = None
        self._mock = os.environ.get("MIXDICTATE_BACKEND") == "mock"
        self._executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="mixdictate-asr"
        )
        # 实际执行推理的线程名。所有调用都必须落在同一个线程上 ——
        # 这个字段让这件事可观测、可测试，而不是靠约定。
        self.worker_thread: str | None = None

    # ---------------------------------------------------------- 只在专用线程上跑

    def _ensure_loaded(self) -> None:
        if self._session is not None or self._mock:
            return

        from mlx_qwen3_asr import Session  # 仅 Apple Silicon 可用

        log.info("正在加载模型 %s ...", self.model)
        self._session = Session(model=self.model)
        log.info("模型加载完成（线程 %s）", threading.current_thread().name)

    def _run(self, audio_path: str, context: str) -> ASRResult:
        self.worker_thread = threading.current_thread().name

        if self._mock:
            return ASRResult(
                text=os.environ.get("MIXDICTATE_MOCK_TEXT", ""), language="zh"
            )

        self._ensure_loaded()
        assert self._session is not None

        try:
            result = self._session.transcribe(audio_path, context=context or None)
        except TypeError:
            # 老版本的 mlx-qwen3-asr 可能没有 context 参数，降级为无偏置
            log.warning("当前 mlx-qwen3-asr 不支持 context 参数，热词偏置已跳过")
            result = self._session.transcribe(audio_path)

        text = extract_text(result)
        if not text.strip():
            # 取不到文字时把返回值的形状打出来。原来这里是
            # getattr(result, "text", "")，一旦库的返回结构跟假设不一样
            # 就会静默返回空字符串 —— 表现和"模型没听出来"完全一样，
            # 排查时会一直往错误的方向找。
            log.warning(
                "没能从模型返回值里取到文字。类型=%s 属性=%s 内容=%.400r",
                type(result).__name__,
                [a for a in dir(result) if not a.startswith("_")][:20],
                result,
            )

        return ASRResult(text=text, language=getattr(result, "language", None))

    # ---------------------------------------------------------- 对外接口

    def warmup(self) -> None:
        """在服务启动时预热，避免第一次听写卡住好几秒。"""
        self._executor.submit(self._ensure_loaded).result()

    def transcribe(self, audio_path: str, *, context: str = "") -> ASRResult:
        """同步调用（自检脚本用）。仍然走那个专用线程。"""
        return self._executor.submit(self._run, audio_path, context).result()

    async def transcribe_async(self, audio_path: str, *, context: str = "") -> ASRResult:
        """异步调用（HTTP 服务用）。推理不会阻塞事件循环。"""
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor, self._run, audio_path, context
        )
