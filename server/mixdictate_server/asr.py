"""mlx-qwen3-asr 的薄封装。

模型只在进程内加载一次（首次转写时懒加载），之后每次听写复用同一个
Session。0.6B 在 M2 Pro 上首次加载约 3-10 秒，之后单次几秒钟的音频
延迟在 1 秒以内。

设了 MIXDICTATE_BACKEND=mock 时走假后端，方便在非 Apple Silicon 机器上
跑测试和调后处理链路。
"""

from __future__ import annotations

import logging
import os
import threading
from dataclasses import dataclass

log = logging.getLogger(__name__)

DEFAULT_MODEL = "Qwen/Qwen3-ASR-0.6B"


@dataclass
class ASRResult:
    text: str
    language: str | None = None


class Transcriber:
    def __init__(self, model: str = DEFAULT_MODEL) -> None:
        self.model = model
        self._session = None
        self._lock = threading.Lock()
        # 边说边转写会在录音过程中不断发请求，加上松手时的最终请求，
        # 同一个 MLX session 会被并发调用。模型不是线程安全的，必须串行。
        self._inference_lock = threading.Lock()
        self._mock = os.environ.get("MIXDICTATE_BACKEND") == "mock"

    # ---------------------------------------------------------- 加载

    def _ensure_loaded(self) -> None:
        if self._session is not None or self._mock:
            return
        with self._lock:
            if self._session is not None:
                return
            from mlx_qwen3_asr import Session  # 仅 Apple Silicon 可用

            log.info("正在加载模型 %s ...", self.model)
            self._session = Session(model=self.model)
            log.info("模型加载完成")

    def warmup(self) -> None:
        """在服务启动时预热，避免第一次听写卡住好几秒。"""
        self._ensure_loaded()

    # ---------------------------------------------------------- 转写

    def transcribe(self, audio_path: str, *, context: str = "") -> ASRResult:
        if self._mock:
            return ASRResult(text=os.environ.get("MIXDICTATE_MOCK_TEXT", ""), language="zh")

        self._ensure_loaded()
        assert self._session is not None

        with self._inference_lock:
            try:
                result = self._session.transcribe(audio_path, context=context or None)
            except TypeError:
                # 老版本的 mlx-qwen3-asr 可能没有 context 参数，降级为无偏置
                log.warning("当前 mlx-qwen3-asr 不支持 context 参数，热词偏置已跳过")
                result = self._session.transcribe(audio_path)

        return ASRResult(
            text=getattr(result, "text", "") or "",
            language=getattr(result, "language", None),
        )
