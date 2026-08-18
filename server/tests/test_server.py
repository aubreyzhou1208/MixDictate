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
# 指向包内的种子词表。必须在 import main 之前设好 —— main 在模块级
# 就解析路径了，晚设一步就会去碰真实的 Application Support 目录。
os.environ.setdefault(
    "MIXDICTATE_HOTWORDS",
    str(Path(__file__).resolve().parents[1] / "mixdictate_server" / "default_hotwords.txt"),
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


def test_health_reports_identity_for_staleness_checks(client):
    """残留的旧服务会被新 App 直接接管，光看「服务在跑」分辨不出来。

    启动时刻和进程号能一眼看出跑着的是不是刚装的那份代码。
    """
    body = client.get("/health").json()
    assert body["pid"] > 0
    assert len(body["started_at"]) == 19  # YYYY-MM-DD HH:MM:SS
    assert "saves_audio" in body


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
    """raw 是模型的原始输出，text 是后处理之后的。两个都要返回 ——
    只看最终结果分不清是模型听错了还是后处理改坏了。"""
    raw = "嗯,这个方案不错"
    body = _transcribe(client, raw)
    assert body["raw"] == raw
    assert body["text"] == "这个方案不错"


# ------------------------------------------------------------ 错误分支

def test_empty_audio_is_rejected(client):
    response = client.post(
        "/transcribe", files={"audio": ("speech.wav", b"", "audio/wav")}
    )
    assert response.status_code == 400
    assert response.json()["error"]


# ------------------------------------------------------------ 转写日志

def test_transcript_log_records_raw_and_output(client, tmp_path, monkeypatch):
    """调准确率全靠这个日志，原始输出和处理后结果都得留下。"""
    from mixdictate_server import paths

    monkeypatch.setenv("MIXDICTATE_HOME", str(tmp_path))

    _transcribe(client, "把它部署到kubernetes上面")

    logged = (paths.log_dir() / "transcripts.log").read_text(encoding="utf-8")
    assert "kubernetes" in logged, "原始输出要能看到，否则分不清是模型错还是后处理错"
    assert "Kubernetes" in logged, "处理后的结果也要记"


def test_fullwidth_punct_flag_reaches_postprocess(client):
    os.environ["MIXDICTATE_MOCK_TEXT"] = "这个 schema 要改吗?"
    response = client.post(
        "/transcribe",
        files={"audio": ("speech.wav", _wav(), "audio/wav")},
        data={"strip_fillers": "true", "fullwidth_punct": "false"},
    )
    assert response.json()["text"] == "这个 schema 要改吗?"


# ------------------------------------------------------------ 边说边转写

def test_partial_results_are_not_logged(client, tmp_path, monkeypatch):
    """中间结果不能进转写记录 —— 一次听写十几条会把最终结果淹掉。"""
    from mixdictate_server import paths

    monkeypatch.setenv("MIXDICTATE_HOME", str(tmp_path))
    os.environ["MIXDICTATE_MOCK_TEXT"] = "这是中间结果"

    response = client.post(
        "/transcribe",
        files={"audio": ("speech.wav", _wav(), "audio/wav")},
        data={"partial": "true"},
    )
    assert response.status_code == 200
    assert response.json()["partial"] is True
    assert response.json()["text"] == "这是中间结果"

    log_file = paths.log_dir() / "transcripts.log"
    assert not log_file.exists() or "这是中间结果" not in log_file.read_text(encoding="utf-8")


def test_final_result_defaults_to_not_partial(client):
    body = _transcribe(client, "最终结果")
    assert body["partial"] is False


def test_concurrent_requests_are_serialised(client):
    """并发打进来不能炸 —— 模型不是线程安全的，服务端要串行处理。"""
    import concurrent.futures

    os.environ["MIXDICTATE_MOCK_TEXT"] = "并发测试"

    def call():
        return client.post(
            "/transcribe",
            files={"audio": ("speech.wav", _wav(), "audio/wav")},
            data={"partial": "true"},
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        responses = [f.result() for f in [pool.submit(call) for _ in range(6)]]

    assert all(r.status_code == 200 for r in responses)
    assert all(r.json()["text"] == "并发测试" for r in responses)


# ------------------------------------------------------------ 预热

def test_warmup_endpoint_exists(client):
    """录音一开始就调它，把 Metal 计算核的编译开销提前付掉 ——
    否则那笔开销会落在用户的第一句话上。"""
    response = client.post("/warmup")
    assert response.status_code == 200
    assert "warming" in response.json()


def test_warmup_is_a_no_op_right_after_inference(client):
    # 刚推理过就不必再热，重复热只是白烧电
    _transcribe(client, "刚刚说过话")
    assert client.post("/warmup").json()["warming"] is False
