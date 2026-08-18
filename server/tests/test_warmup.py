"""预热要覆盖多个音频长度。

MLX 的 Metal 计算核是按张量形状编译的，输入长度直接决定形状。只用一个
长度预热，编出来的核只服务于那个长度 —— 用户真正说的那句话仍然要现编，
表现就是「第一次特别慢，用得越多越快」。

这条很容易在重构里悄悄退化回单个长度（看起来只是少跑两次推理，省时间），
所以用测试钉住。
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

os.environ["MIXDICTATE_BACKEND"] = "mock"

from mixdictate_server.audio import inspect_wav, warmup_wav
from mixdictate_server.asr import COLD_WARMUP_SECONDS, STALE_WARMUP_SECONDS, Transcriber


def _record_runs(transcriber, monkeypatch):
    seen = []
    original = transcriber._run

    def spy(audio_path, context):
        seen.append(audio_path)
        return original(audio_path, context)

    monkeypatch.setattr(transcriber, "_run", spy)
    return seen


def test_cold_warmup_covers_several_lengths(monkeypatch):
    transcriber = Transcriber()
    seen = _record_runs(transcriber, monkeypatch)
    transcriber.warmup()
    assert len(seen) == len(COLD_WARMUP_SECONDS)


def test_cold_warmup_uses_more_than_one_shape():
    # 一个长度只编一种形状的核，等于没解决问题
    assert len(COLD_WARMUP_SECONDS) > 1
    assert len(set(COLD_WARMUP_SECONDS)) == len(COLD_WARMUP_SECONDS)


def test_cold_warmup_spans_realistic_utterances():
    # 真实的一句话大多在 1-8 秒之间，预热得覆盖到这个范围，
    # 只热 0.6 秒那种"技术上跑过一次推理"是不够的
    assert min(COLD_WARMUP_SECONDS) <= 1.0
    assert max(COLD_WARMUP_SECONDS) >= 5.0


def test_stale_rewarm_is_cheaper_than_cold():
    # 闲置重热时核已经编好了，跑满全套纯属浪费电
    assert len(STALE_WARMUP_SECONDS) < len(COLD_WARMUP_SECONDS)


def test_warmup_marks_the_transcriber_fresh():
    transcriber = Transcriber()
    transcriber.warmup()
    assert transcriber.warmed_at > 0
    # 刚热完就不该再被判定为需要重热
    assert transcriber.warmup_if_stale(max_age_seconds=60) is False


def test_warmup_wav_length_follows_the_requested_duration():
    for seconds in COLD_WARMUP_SECONDS:
        info = inspect_wav(warmup_wav(seconds))
        assert info is not None
        assert abs(info.duration - seconds) < 0.05
        # 纯静音可能被解码器短路掉，预热就白热了
        assert info.peak > 0
