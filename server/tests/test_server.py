"""HTTP 层的端到端测试，用 mock 后端跑，不需要模型。

覆盖 multipart 解析 → 热词纠正 → 后处理 → JSON 返回的完整链路。
"""

import os
import struct
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

fastapi = pytest.importorskip("fastapi", reason="需要 fastapi 才能跑服务层测试")
from fastapi.testclient import TestClient  # noqa: E402

os.environ.setdefault("MIXDICTATE_BACKEND", "mock")
os.environ.setdefault("MIXDICTATE_WARMUP", "0")
os.environ.setdefault(
    "MIXDICTATE_HOTWORDS",
    str(Path(__file__).resolve().parents[2] / "config" / "hotwords.txt"),
)

from mixdictate_server.main import app  # noqa: E402


def _wav(samples: int = 1600) -> bytes:
    """一段最小的合法 WAV。mock 后端不解码，只需要格式上说得过去。"""
    pcm = b"\x00\x00" * samples
    header = (
        b"RIFF"
        + struct.pack("<I", 36 + len(pcm))
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
        + b"data"
        + struct.pack("<I", len(pcm))
    )
    return header + pcm


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def _transcribe(client, mock_text: str) -> dict:
    os.environ["MIXDICTATE_MOCK_TEXT"] = mock_text
    response = client.post(
        "/transcribe",
        files={"audio": ("speech.wav", _wav(), "audio/wav")},
        data={"strip_fillers": "true"},
    )
    assert response.status_code == 200, response.text
    return response.json()


# ------------------------------------------------------------ 健康检查

def test_health_reports_hotword_path(client):
    body = client.get("/health").json()
    assert body["ok"] is True
    assert body["hotwords"] > 0
    # App 靠这个字段定位热词表，不能少
    assert body["hotwords_path"].endswith("hotwords.txt")


# ------------------------------------------------------------ 转写链路

def test_code_switching_sentence(client):
    body = _transcribe(client, "嗯,这个pipeline的latency有点高,我们要不要换个schema?")
    assert body["text"] == "这个 pipeline 的 latency 有点高，我们要不要换个 schema？"


def test_hotwords_applied_through_http(client):
    body = _transcribe(client, "把它部署到kubernetes上面,用github actions跑CI")
    assert body["text"] == "把它部署到 Kubernetes 上面，用 GitHub actions 跑 CI"


def test_numbers_and_filenames_survive(client):
    body = _transcribe(client, "会议改到3:30,误差是3.14左右,改config.json这个文件")
    assert body["text"] == "会议改到 3:30，误差是 3.14 左右，改 config.json 这个文件"


def test_raw_text_is_returned_for_debugging(client):
    raw = "就是就是这个意思"
    body = _transcribe(client, raw)
    assert body["raw"] == raw
    assert body["text"] == "就是这个意思"


# ------------------------------------------------------------ 错误分支

def test_empty_audio_is_rejected(client):
    response = client.post(
        "/transcribe", files={"audio": ("speech.wav", b"", "audio/wav")}
    )
    assert response.status_code == 400
    assert response.json()["error"]
