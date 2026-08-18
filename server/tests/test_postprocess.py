import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mixdictate_server.hotwords import HotwordTable
from mixdictate_server.postprocess import (
    fix_spacing,
    postprocess,
    strip_fillers,
    to_fullwidth_punct,
)


# ------------------------------------------------------------ 填充词

def test_strips_leading_filler():
    assert strip_fillers("嗯我觉得这个方案可以") == "我觉得这个方案可以"


def test_strips_filler_after_punctuation():
    assert strip_fillers("先看数据，呃然后再决定") == "先看数据，然后再决定"


def test_collapses_stutter():
    assert strip_fillers("就是就是这个意思") == "就是这个意思"
    assert strip_fillers("我我我知道") == "我知道"


def test_keeps_legitimate_reduplication():
    # "谢谢""看看"是正常中文，不能被当成卡壳压缩掉
    assert strip_fillers("谢谢你") == "谢谢你"
    assert strip_fillers("我看看再说") == "我看看再说"


def test_keeps_demonstratives():
    # "这个""那个"有实义，不在填充词表里
    assert strip_fillers("这个方案不行") == "这个方案不行"


# ------------------------------------------------------------ 空格

def test_adds_space_between_cjk_and_latin():
    assert fix_spacing("这个pipeline的latency有点高") == "这个 pipeline 的 latency 有点高"


def test_removes_spurious_space_between_cjk():
    assert fix_spacing("这 个 方 案") == "这个方案"


def test_leaves_pure_english_alone():
    assert fix_spacing("the latency is too high") == "the latency is too high"


# ------------------------------------------------------------ 标点

def test_converts_punctuation_after_chinese():
    assert to_fullwidth_punct("你好,世界") == "你好，世界"
    assert to_fullwidth_punct("真的吗?") == "真的吗？"


def test_preserves_decimals_and_filenames():
    # 半角句点前面不是中文，必须原样保留
    assert to_fullwidth_punct("误差是 3.14 左右") == "误差是 3.14 左右"
    assert to_fullwidth_punct("改 config.json 这个文件") == "改 config.json 这个文件"


def test_converts_punctuation_when_sentence_ends_in_english():
    # 中英混说的典型形态：整句是中文，但结尾落在英文词上。
    # 标点要跟整句走，不能因为紧邻字符是字母就放过。
    assert to_fullwidth_punct("我们要不要换个schema?") == "我们要不要换个schema？"
    assert to_fullwidth_punct("这版我们用 Python.") == "这版我们用 Python。"


def test_preserves_glued_ascii_punctuation():
    # 两侧都紧贴 ASCII 字母数字时不动，保住时间和内联代码
    assert to_fullwidth_punct("会议改到 3:30 开") == "会议改到 3:30 开"


def test_language_resets_after_sentence_end():
    # 前一句是中文，不该把后面纯英文句子的标点也带成全角
    got = to_fullwidth_punct("先这样。Ship it, then iterate.")
    assert got == "先这样。Ship it, then iterate."


def test_preserves_english_punctuation():
    assert to_fullwidth_punct("I think, therefore I am.") == "I think, therefore I am."


# ------------------------------------------------------------ 热词

def _table(tmp_path, body):
    p = tmp_path / "hotwords.txt"
    p.write_text(body, encoding="utf-8")
    return HotwordTable.load(p)


def test_normalizes_casing(tmp_path):
    table = _table(tmp_path, "Kubernetes\nGitHub\n")
    assert table.apply("我们把它部署到 kubernetes 上") == "我们把它部署到 Kubernetes 上"
    assert table.apply("推到 github 去") == "推到 GitHub 去"


def test_applies_alias(tmp_path):
    table = _table(tmp_path, "k8s => Kubernetes\n")
    assert table.apply("跑在 k8s 集群里") == "跑在 Kubernetes 集群里"


def test_alias_respects_word_boundary(tmp_path):
    table = _table(tmp_path, "API\n")
    # "APIs" 不该被当成 "API" 边界内的独立词而改动周围
    assert table.apply("多个 APIs 一起") == "多个 APIs 一起"


def test_ignores_comments_and_blanks(tmp_path):
    table = _table(tmp_path, "# 注释\n\nDocker  # 行尾注释\n")
    assert table.terms == ["Docker"]


def test_context_is_space_separated(tmp_path):
    table = _table(tmp_path, "Kubernetes\nDocker\n")
    assert table.context() == "Kubernetes Docker"


# ------------------------------------------------------------ 端到端

def test_full_chain():
    raw = "嗯,这个pipeline的latency有点高,我们要不要换个schema?"
    assert postprocess(raw) == "这个 pipeline 的 latency 有点高，我们要不要换个 schema？"


def test_empty_input():
    assert postprocess("") == ""
    assert postprocess("   ") == ""


# ------------------------------------------------------------ 开关

def test_fullwidth_punctuation_can_be_disabled():
    # 写代码的场景里半角标点更顺手，得留个开关
    raw = "这个 schema 要改吗?"
    assert postprocess(raw, fullwidth_punctuation=False) == "这个 schema 要改吗?"
    assert postprocess(raw, fullwidth_punctuation=True) == "这个 schema 要改吗？"


def test_filler_stripping_can_be_disabled():
    assert postprocess("嗯我知道", strip_filler_words=False) == "嗯我知道"
