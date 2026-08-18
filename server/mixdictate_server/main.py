"""本地 HTTP 服务：接收一段录音，返回处理好的文字。

只监听 127.0.0.1，不对外暴露。音频写到临时文件后立刻删除，不留痕。
"""

from __future__ import annotations

import logging
import os
import tempfile
import time
from pathlib import Path

from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse

from . import paths
from .asr import DEFAULT_MODEL, Transcriber
from .hotwords import HotwordTable
from .postprocess import postprocess

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s  %(levelname)-7s %(message)s"
)
log = logging.getLogger("mixdictate")

HOTWORDS_PATH = paths.hotwords_path()
MODEL = os.environ.get("MIXDICTATE_MODEL", DEFAULT_MODEL)
PORT = int(os.environ.get("MIXDICTATE_PORT", 8765))

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
) -> JSONResponse:
    started = time.monotonic()
    payload = await audio.read()
    if not payload:
        return JSONResponse({"text": "", "error": "空音频"}, status_code=400)

    table = current_hotwords()

    tmp_path = ""
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp.write(payload)
            tmp_path = tmp.name

        result = transcriber.transcribe(tmp_path, context=table.context())
    except Exception as exc:  # 服务不能因为一次失败就崩掉
        log.exception("转写失败")
        return JSONResponse({"text": "", "error": str(exc)}, status_code=500)
    finally:
        if tmp_path:
            Path(tmp_path).unlink(missing_ok=True)

    raw = result.text
    text = table.apply(raw)
    text = postprocess(text, strip_filler_words=strip_fillers)

    elapsed = time.monotonic() - started
    log.info("[%.2fs] %s", elapsed, text or "（无内容）")

    return JSONResponse(
        {
            "text": text,
            "raw": raw,
            "language": result.language,
            "elapsed_ms": round(elapsed * 1000),
        }
    )


def run() -> None:
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=PORT)


if __name__ == "__main__":
    run()
