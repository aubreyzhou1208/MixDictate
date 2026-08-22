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
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

log = logging.getLogger(__name__)

DEFAULT_MODEL = "Qwen/Qwen3-ASR-0.6B"

# 冷启动预热要跑的几个音频长度（秒）。
#
# 为什么不是一个：MLX 的 Metal 计算核是**按张量形状**编译的，而输入长度
# 直接决定形状。只用一个 0.6 秒的样本预热，编出来的核只服务于 0.6 秒左右
# 的输入 —— 用户真正说的那句两三秒的话仍然要现编一次。用户的原话是
# 「用的次数越多它反应越快」，说的就是这个：每碰到一个新长度就多编一批核，
# 编过的越多、撞上缓存的概率越大。
#
# 所以预热要覆盖常见的几档长度，把这笔开销在启动时一次付清。
COLD_WARMUP_SECONDS = (0.8, 2.5, 6.0)

# 闲置后的重热只要一档就够 —— 核已经编好了，这里要的只是把权重和
# 上下文重新拉回热状态，跑满三档纯属浪费电。
STALE_WARMUP_SECONDS = (1.2,)


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
        # 上次预热的时刻。闲置太久要重新热一次。
        self.warmed_at: float = 0.0

    # ---------------------------------------------------------- 只在专用线程上跑

    def _ensure_loaded(self) -> None:
        if self._session is not None or self._mock:
            return

        from mlx_qwen3_asr import Session  # 仅 Apple Silicon 可用

        log.info("正在加载模型 %s ...", self.model)
        self._session = Session(model=self.model)
        log.info("模型加载完成（线程 %s）", threading.current_thread().name)

    def _run(self, audio_path: str, context: str, language: str = "") -> ASRResult:
        self.worker_thread = threading.current_thread().name
        self.warmed_at = time.monotonic()

        if self._mock:
            return ASRResult(
                text=os.environ.get("MIXDICTATE_MOCK_TEXT", ""), language="zh"
            )

        self._ensure_loaded()
        assert self._session is not None

        # language 为空 = 让模型自己判断（默认）。指定了就锁死 ——
        # 短句子的语种判定最容易错，而粤语和英语在音节上重合不少，
        # 模型一犹豫就会整句倒向英文。
        kwargs: dict[str, object] = {}
        if context:
            kwargs["context"] = context
        if language:
            kwargs["language"] = language

        try:
            result = self._session.transcribe(audio_path, **kwargs)
        except TypeError:
            # 老版本的库可能没有这些关键字。逐个退，而不是一次全丢 ——
            # 先丢 language（少了它只是不锁语种），再丢 context（少了它热词偏置失效）。
            if "language" in kwargs:
                log.warning("当前 mlx-qwen3-asr 不支持 language 参数，已跳过语言锁定")
                kwargs.pop("language")
                try:
                    result = self._session.transcribe(audio_path, **kwargs)
                except TypeError:
                    log.warning("当前 mlx-qwen3-asr 不支持 context 参数，热词偏置已跳过")
                    result = self._session.transcribe(audio_path)
            else:
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

    @property
    def is_loaded(self) -> bool:
        """权重进内存了没有。/health 报出去 —— 「服务活着」和「模型能用了」
        是两回事，首次启动要下载模型，中间那几分钟服务是活的但转不了。"""
        return self._mock or self._session is not None

    def warmup(self) -> None:
        """预热：加载模型 **并且真的跑几次推理**。

        只加载权重是不够的 —— MLX 的 Metal 计算核是首次推理时才编译的，
        不提前跑一遍，那笔开销就会落在用户的第一句话上。而且核是按张量
        形状编的，所以要跑好几个长度，见 COLD_WARMUP_SECONDS。
        """
        self._executor.submit(self._warmup_now, COLD_WARMUP_SECONDS).result()

    def _warmup_now(
        self, durations: tuple[float, ...] = COLD_WARMUP_SECONDS
    ) -> None:
        import tempfile
        from pathlib import Path as _Path

        from .audio import warmup_wav

        self._ensure_loaded()

        for seconds in durations:
            tmp = ""
            try:
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
                    handle.write(warmup_wav(seconds))
                    tmp = handle.name
                self._run(tmp, "")
            except Exception as exc:  # 预热失败不该拦住服务启动
                log.warning("预热失败（%.1f 秒那档），第一次听写可能偏慢：%s",
                            seconds, exc)
                break
            finally:
                if tmp:
                    _Path(tmp).unlink(missing_ok=True)

        self.warmed_at = time.monotonic()
        log.info(
            "预热完成：%s 秒各跑了一遍（计算核已编译）",
            "/".join(f"{s:g}" for s in durations),
        )

    def warmup_if_stale(self, max_age_seconds: float = 120.0) -> bool:
        """久没推理就再热一次。

        闲置一段时间后系统可能把相关资源换出去，下一次推理又会变慢。
        录音一开始就调这个 —— 那时离真正的转写请求还有约 0.8 秒，
        足够热完，又不用在后台一直空转烧电。
        """
        if self._mock:
            return False
        if time.monotonic() - self.warmed_at < max_age_seconds:
            return False
        self._executor.submit(self._warmup_now, STALE_WARMUP_SECONDS)
        return True

    def transcribe(
        self, audio_path: str, *, context: str = "", language: str = ""
    ) -> ASRResult:
        """同步调用（自检脚本用）。仍然走那个专用线程。"""
        return self._executor.submit(self._run, audio_path, context, language).result()

    async def transcribe_async(
        self, audio_path: str, *, context: str = "", language: str = ""
    ) -> ASRResult:
        """异步调用（HTTP 服务用）。推理不会阻塞事件循环。"""
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor, self._run, audio_path, context, language
        )
