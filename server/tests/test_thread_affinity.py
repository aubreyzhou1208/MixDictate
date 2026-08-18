"""MLX 的线程亲和性回归测试。

MLX 的 GPU stream 是线程局部的：在 A 线程加载模型、到 B 线程做推理，
会直接抛

    RuntimeError: There is no Stream(gpu, 1) in current thread.

之前用 asyncio.to_thread 正好踩中 —— 每次调用可能落到线程池里不同的
工作线程上。自检脚本在主线程直接调模型所以一直正常，HTTP 服务却每次
都 500，两边表现完全相反，非常难查。

所以这条必须锁死：不管从哪个线程、用哪个接口调用，模型都只在同一个
专用线程上跑。
"""

import asyncio
import os
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

os.environ["MIXDICTATE_BACKEND"] = "mock"

from mixdictate_server.asr import Transcriber


def test_sync_calls_run_on_the_dedicated_thread():
    transcriber = Transcriber()
    transcriber.transcribe("ignored.wav")
    assert transcriber.worker_thread is not None
    assert transcriber.worker_thread.startswith("mixdictate-asr")


def test_worker_thread_is_never_the_caller_thread():
    # 直接在调用者线程上跑就没有亲和性可言了
    transcriber = Transcriber()
    transcriber.transcribe("ignored.wav")
    assert transcriber.worker_thread != threading.current_thread().name


def test_calls_from_different_threads_share_one_worker():
    transcriber = Transcriber()
    seen: list[str] = []

    def call() -> None:
        transcriber.transcribe("ignored.wav")
        seen.append(transcriber.worker_thread or "")

    threads = [threading.Thread(target=call) for _ in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert len(set(seen)) == 1, f"推理落到了多个线程上：{set(seen)}"


def test_async_and_sync_share_the_same_worker():
    """服务走 async、自检走 sync —— 两条路必须落在同一个线程上。"""
    transcriber = Transcriber()

    transcriber.transcribe("ignored.wav")
    from_sync = transcriber.worker_thread

    asyncio.run(transcriber.transcribe_async("ignored.wav"))
    from_async = transcriber.worker_thread

    assert from_sync == from_async


def test_warmup_uses_the_same_thread_as_inference():
    """模型必须在跑推理的那个线程上加载，否则 stream 对不上。"""
    transcriber = Transcriber()
    transcriber.warmup()
    transcriber.transcribe("ignored.wav")
    assert transcriber.worker_thread.startswith("mixdictate-asr")
