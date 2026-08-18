"""从模型返回值里取文字的测试。

原来的实现是 getattr(result, "text", "")：只要库的返回结构跟假设不一样，
就静默变成空字符串。这种失败跟"模型确实没听出内容"长得完全一样，
排查时会一直往错误的方向找 —— 所以这里把各种可能的形状都覆盖到。
"""

import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mixdictate_server.asr import extract_text


@dataclass
class WithText:
    text: str


@dataclass
class WithTranscription:
    transcription: str


@dataclass
class Segment:
    text: str


@dataclass
class WithSegments:
    segments: list


def test_object_with_text():
    assert extract_text(WithText("你好世界")) == "你好世界"


def test_plain_string():
    assert extract_text("你好世界") == "你好世界"


def test_dict_with_text():
    assert extract_text({"text": "你好世界"}) == "你好世界"


def test_alternative_attribute_name():
    assert extract_text(WithTranscription("你好世界")) == "你好世界"


def test_object_with_segments():
    result = WithSegments([Segment("这个 "), Segment("pipeline 有点慢")])
    assert extract_text(result) == "这个 pipeline 有点慢"


def test_bare_segment_list():
    assert extract_text([Segment("前半句"), Segment("后半句")]) == "前半句后半句"


def test_dict_with_segments():
    result = {"segments": [{"text": "前半句"}, {"text": "后半句"}]}
    assert extract_text(result) == "前半句后半句"


def test_segments_joined_without_spaces():
    # 中文不用空格分词，段之间加空格会污染输出
    assert extract_text([Segment("你好"), Segment("世界")]) == "你好世界"


def test_empty_shapes():
    assert extract_text(None) == ""
    assert extract_text("") == ""
    assert extract_text({}) == ""
    assert extract_text([]) == ""
    assert extract_text(WithText("")) == ""
    assert extract_text(object()) == ""


def test_whitespace_only_is_empty():
    assert extract_text(WithText("   \n  ")) == ""
