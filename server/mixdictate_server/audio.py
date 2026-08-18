"""收到的音频到底是什么样子 —— 用来区分"客户端发错了"和"模型没听出来"。

模型返回空结果时，光看结果分不清是哪一种：
  · 客户端的 WAV 封装错了（采样率写错、声道数不对、数据是空的）
  · 音频没问题，但模型确实没识别出内容

所以每个请求都体检一遍并记进日志。
"""

from __future__ import annotations

import array
import io
import math
import struct
import wave
from dataclasses import dataclass


@dataclass
class WavInfo:
    sample_rate: int
    channels: int
    sample_width: int
    frames: int

    @property
    def duration(self) -> float:
        return self.frames / self.sample_rate if self.sample_rate else 0.0

    peak: float = 0.0
    """最大振幅，0…1。接近 0 说明是静音。"""

    def summary(self) -> str:
        return (
            f"{self.duration:.2f}s  {self.sample_rate}Hz  "
            f"{self.channels}ch  {self.sample_width * 8}bit  峰值 {self.peak:.3f}"
        )


def inspect_wav(payload: bytes) -> WavInfo | None:
    """解析 WAV 头并算出峰值。解析不了就返回 None —— 这本身就是有用的信息。"""
    try:
        with wave.open(io.BytesIO(payload), "rb") as handle:
            channels = handle.getnchannels()
            width = handle.getsampwidth()
            rate = handle.getframerate()
            frames = handle.getnframes()
            raw = handle.readframes(frames)
    except (wave.Error, EOFError, ValueError):
        return None

    info = WavInfo(
        sample_rate=rate, channels=channels, sample_width=width, frames=frames
    )

    # 只处理 16 位 —— 我们的客户端只发这个。别的位深不算峰值，但其他信息仍然有用。
    # 注意不能用 audioop：Python 3.13 已经把它删掉了。
    if width == 2 and raw:
        samples = array.array("h")
        samples.frombytes(raw[: len(raw) // 2 * 2])
        if samples:
            info.peak = max(abs(int(s)) for s in samples) / 32767.0

    return info


def warmup_wav(seconds: float = 0.6, sample_rate: int = 16_000) -> bytes:
    """生成一段极轻微的音频，专门用来预热。

    不能用纯静音：解码器可能走短路，那样就白热了。用一段很轻的正弦波，
    保证完整的推理路径真的被跑过一遍 —— 首次推理要编译 Metal 计算核，
    那笔开销必须提前付掉，不能落在用户的第一句话上。
    """
    frames = int(seconds * sample_rate)
    pcm = b"".join(
        struct.pack("<h", int(600 * math.sin(2 * math.pi * 220 * i / sample_rate)))
        for i in range(frames)
    )
    header = (
        b"RIFF"
        + struct.pack("<I", 36 + len(pcm))
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16)
        + b"data"
        + struct.pack("<I", len(pcm))
    )
    return header + pcm
