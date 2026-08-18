"""本地 HTTP 服务：接收一段录音，返回处理好的文字。

只监听 127.0.0.1，不对外暴露。音频写到临时文件后立刻删除，不留痕。
"""

from __future__ import annotations

import asyncio
import logging
import os
import tempfile
import time
from datetime import datetime
from pathlib import Path

from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse

from . import paths
from .asr import DEFAULT_MODEL, Transcriber
from .audio import inspect_wav
from .hotwords import HotwordTable
from .postprocess import postprocess

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s  %(levelname)-7s %(message)s"
)
log = logging.getLogger("mixdictate")

HOTWORDS_PATH = paths.hotwords_path()
MODEL = os.environ.get("MIXDICTATE_MODEL", DEFAULT_MODEL)
PORT = int(os.environ.get("MIXDICTATE_PORT", 8765))
# 把最后一次正式转写的音频留一份，方便排查"模型没听出来"到底是音频的问题
# 还是模型的问题。只留最新一份，会被反复覆盖。设成 0 可以关掉。
SAVE_AUDIO = os.environ.get("MIXDICTATE_SAVE_AUDIO", "1") == "1"

transcriber = Transcriber(model=MODEL)
_hotwords = HotwordTable.load(HOTWORDS_PATH)
_hotwords_mtime = HOTWORDS_PATH.stat().st_mtime if HOTWORDS_PATH.exists() else 0.0


def current_hotwords() -> HotwordTable:
    """热词表改了就自动重载，不用重启服务。"""
    global _hotwords, _hotwords_mtime
    if not HOTWORDS_PATH.exists():
        return _hotwords
    mtime = HOTWORDS_PATH.stat().st_mtime
    if mtime != _hotwords_mtime:
        log.info("热词表已更新，重新加载")
        _hotwords = HotwordTable.load(HOTWORDS_PATH)
        _hotwords_mtime = mtime
    return _hotwords


@asynccontextmanager
async def lifespan(_: FastAPI):
    log.info("模型: %s", MODEL)
    log.info("热词表: %s（%d 条）", HOTWORDS_PATH, len(_hotwords.terms))
    if os.environ.get("MIXDICTATE_WARMUP", "1") == "1":
        # 预热放在启动阶段，第一次听写就不会卡在加载模型上
        transcriber.warmup()
    log.info("就绪，监听 http://127.0.0.1:%s", PORT)
    yield


app = FastAPI(title="MixDictate", docs_url=None, redoc_url=None, lifespan=lifespan)


def save_last_audio(payload: bytes) -> None:
    """留一份最近的录音，用来验证音频本身对不对（拿播放器打开听一下）。"""
    try:
        (paths.log_dir() / "last_request.wav").write_bytes(payload)
    except OSError as exc:
        log.warning("保存音频副本失败：%s", exc)


def record_transcript(*, raw: str, text: str, elapsed: float) -> None:
    """把每次转写的原始输出和处理后结果并排记下来。

    调准确率靠的就是这个文件：说一段话，回头看哪些词听错了，
    把它们加进热词表。只看最终结果分不清是模型听错了还是后处理改坏了，
    所以两个都要留。
    """
    try:
        line = (
            f"{datetime.now():%Y-%m-%d %H:%M:%S}  [{elapsed:.2f}s]\n"
            f"  原始: {raw}\n"
            f"  输出: {text}\n\n"
        )
        with (paths.log_dir() / "transcripts.log").open("a", encoding="utf-8") as handle:
            handle.write(line)
    except OSError as exc:
        # 日志写不了不该影响听写本身
        log.warning("转写日志写入失败：%s", exc)


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "model": MODEL,
        "hotwords": len(current_hotwords().terms),
        # App 靠这个找到热词表 —— .app 启动时工作目录是 "/"，自己猜不出来
        "hotwords_path": str(HOTWORDS_PATH.resolve()),
    }


@app.post("/transcribe")
async def transcribe(
    audio: UploadFile = File(...),
    strip_fillers: bool = Form(True),
    fullwidth_punct: bool = Form(True),
    partial: bool = Form(False),
) -> JSONResponse:
    started = time.monotonic()
    payload = await audio.read()
    if not payload:
        return JSONResponse({"text": "", "error": "空音频"}, status_code=400)

    table = current_hotwords()

    # 先给音频做个体检并记进日志。模型返回空结果时，光看结果分不清是
    # 客户端发来的 WAV 有问题，还是音频没问题而模型确实没听出来。
    info = inspect_wav(payload)
    if info is None:
        log.warning("收到的数据不是合法 WAV（%d 字节）", len(payload))
    elif not partial:
        log.info("收到音频 %s", info.summary())

    tmp_path = ""
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(payload)
            tmp_path = tmp.name

        if SAVE_AUDIO and not partial:
            save_last_audio(payload)

        # 推理是同步的重活，直接在事件循环里跑会把整个服务卡住 ——
        # 边说边转写时最终请求就会排在一堆中间请求后面动不了。
        result = await asyncio.to_thread(
            transcriber.transcribe, tmp_path, context=table.context()
        )

        # 结果为空时，先怀疑是热词偏置把解码带跑偏了 —— 去掉 context 再试一次。
        # 这既是自动修复，也是诊断：日志会说清楚是哪一种情况。
        if not result.text.strip() and table.context():
            log.warning("带热词偏置的结果为空，去掉 context 重试")
            retry = await asyncio.to_thread(transcriber.transcribe, tmp_path, context="")
            if retry.text.strip():
                log.warning("去掉 context 后有结果了 —— 空结果是热词偏置造成的")
                result = retry
            else:
                log.warning("去掉 context 仍然是空 —— 不是热词的问题")
    except Exception as exc:  # 服务不能因为一次失败就崩掉
        log.exception("转写失败")
        return JSONResponse({"text": "", "error": str(exc)}, status_code=500)
    finally:
        if tmp_path:
            Path(tmp_path).unlink(missing_ok=True)

    raw = result.text
    text = table.apply(raw)
    text = postprocess(
        text,
        strip_filler_words=strip_fillers,
        fullwidth_punctuation=fullwidth_punct,
    )

    elapsed = time.monotonic() - started

    # 中间结果不记日志也不打印 —— 一次听写会产生十几条，
    # 全记下来会把真正有用的最终结果淹掉
    if not partial:
        log.info("[%.2fs] %s", elapsed, text or "（无内容）")
        if not raw.strip() and info is not None:
            # 音频是好的但模型没输出，这条日志能省掉一轮来回猜测
            log.warning("模型返回空结果，但音频看起来正常：%s", info.summary())
        record_transcript(raw=raw, text=text, elapsed=elapsed)

    return JSONResponse(
        {
            "text": text,
            "raw": raw,
            "language": result.language,
            "elapsed_ms": round(elapsed * 1000),
            "partial": partial,
        }
    )


def run() -> None:
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=PORT)


if __name__ == "__main__":
    run()
