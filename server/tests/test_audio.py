"""音频体检的测试。

这段代码存在的意义就是回答一个问题：模型没输出时，到底是音频有问题，
还是音频没问题而模型确实没听出来。所以它必须能准确描述收到的东西。
"""

import math
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mixdictate_server.audio import inspect_wav


def make_wav(samples: list[int], *, sample_rate: int = 16000, channels: int = 1) -> bytes:
    pcm = b"".join(struct.pack("<h", s) for s in samples)
    header = (
        b"RIFF"
        + struct.pack("<I", 36 + len(pcm))
        + b"WAVEfmt "
        + struct.pack(
            "<IHHIIHH",
            16, 1, channels, sample_rate,
            sample_rate * channels * 2, channels * 2, 16,
        )
        + b"data"
        + struct.pack("<I", len(pcm))
    )
    return header + pcm


def test_reads_format_and_duration():
    info = inspect_wav(make_wav([0] * 8000))
    assert info is not None
    assert info.sample_rate == 16000
    assert info.channels == 1
    assert info.sample_width == 2
    assert math.isclose(info.duration, 0.5, rel_tol=1e-6)


def test_silence_has_zero_peak():
    info = inspect_wav(make_wav([0] * 1000))
    assert info is not None
    assert info.peak == 0.0


def test_loud_audio_has_high_peak():
    info = inspect_wav(make_wav([0, 16000, -32000, 200]))
    assert info is not None
    assert info.peak > 0.9


def test_rejects_non_wav():
    # 这个返回值本身就是诊断结论：客户端发来的根本不是 WAV
    assert inspect_wav(b"this is not audio at all") is None
    assert inspect_wav(b"") is None


def test_summary_mentions_the_useful_numbers():
    summary = inspect_wav(make_wav([0, 16000] * 8000)).summary()
    assert "16000Hz" in summary
    assert "1ch" in summary
    assert "16bit" in summary
    assert "峰值" in summary
