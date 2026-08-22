"""锁定语言这条路必须真的走到模型那里。

这个参数最容易出的错是"加了但没传下去"：界面上选了粤语、配置里也写着，
而请求到了服务端被忽略掉 —— 表现和没这个功能一模一样，而且没有任何报错。
所以这里直接盯住传给 Session.transcribe 的关键字。
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mixdictate_server.asr import Transcriber


class _FakeSession:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    def transcribe(self, audio_path, **kwargs):
        self.calls.append(kwargs)

        class _Result:
            text = "好"
            language = kwargs.get("language")

        return _Result()


def _transcriber_with(session: _FakeSession) -> Transcriber:
    t = Transcriber()
    t._session = session          # 跳过真正的模型加载
    t._mock = False
    return t


def test_language_reaches_the_model() -> None:
    session = _FakeSession()
    _transcriber_with(session).transcribe("x.wav", language="Cantonese")
    assert session.calls[-1].get("language") == "Cantonese"


def test_empty_language_is_not_sent() -> None:
    """空 = 自动识别。这时候不能传 language= ——
    传个空字符串下去等于把语种锁成了"空"，那是另一回事。"""
    session = _FakeSession()
    _transcriber_with(session).transcribe("x.wav", language="")
    assert "language" not in session.calls[-1]


def test_hotword_context_still_goes_through() -> None:
    session = _FakeSession()
    _transcriber_with(session).transcribe("x.wav", context="k8s", language="Chinese")
    assert session.calls[-1] == {"context": "k8s", "language": "Chinese"}


def test_old_library_without_language_degrades_instead_of_failing() -> None:
    """库太老不认 language 时，应该退回去继续转写，而不是整句失败。"""

    class _OldSession(_FakeSession):
        def transcribe(self, audio_path, **kwargs):
            if "language" in kwargs:
                raise TypeError("unexpected keyword argument 'language'")
            return super().transcribe(audio_path, **kwargs)

    session = _OldSession()
    result = _transcriber_with(session).transcribe(
        "x.wav", context="k8s", language="Cantonese"
    )
    assert result.text == "好"
    assert session.calls[-1] == {"context": "k8s"}
