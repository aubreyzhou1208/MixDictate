import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mixdictate_server.hotwords import HotwordTable
from mixdictate_server.postprocess import (
    collapse_repeats,
    fix_spacing,
    merge_pause_sentences,
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
    assert collapse_repeats("就是就是这个意思") == "就是这个意思"
    assert collapse_repeats("我我我知道") == "我知道"


def test_keeps_legitimate_reduplication():
    # "谢谢""看看"是正常中文，不能被当成卡壳压缩掉
    assert collapse_repeats("谢谢你") == "谢谢你"
    assert collapse_repeats("我看看再说") == "我看看再说"


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


# ------------------------------------------------------------ 数字与符号

def test_spoken_decimal_through_full_chain():
    assert postprocess("圆周率大概是三点一四一五九") == "圆周率大概是 3.14159"


def test_spoken_email_through_full_chain():
    assert postprocess("发到 zhou 艾特 gmail 点 com") == "发到 zhou@gmail.com"


def test_number_conversion_can_be_disabled():
    assert postprocess("三点一四", spoken_numbers=False) == "三点一四"


def test_symbol_conversion_can_be_disabled():
    assert postprocess("A 杠 B", spoken_symbols=False) == "A 杠 B"


def test_idioms_survive_the_full_chain():
    # 整条链跑下来也不能把固定搭配拆成数字
    assert postprocess("十分感谢你的帮助") == "十分感谢你的帮助"
    assert postprocess("我们一起走吧") == "我们一起走吧"


# ------------------------------------------------------------ 自我重复

def test_collapses_repeated_phrase():
    # 口述时改口或卡壳，很容易把前半句重说一遍
    assert collapse_repeats("我觉得我觉得这个方案不错") == "我觉得这个方案不错"
    assert collapse_repeats("就是说就是说这个问题") == "就是说这个问题"


def test_collapses_long_repeat():
    assert collapse_repeats("这个方案这个方案确实可以") == "这个方案确实可以"


def test_non_adjacent_repeat_is_kept():
    # 隔了字的重复是正常表达，不是卡壳
    text = "这个方案好，这个方案确实好"
    assert collapse_repeats(text) == text


def test_legitimate_reduplication_survives_phrase_collapse():
    assert collapse_repeats("谢谢谢谢") == "谢谢"
    assert collapse_repeats("我看看再说") == "我看看再说"


def test_repeats_are_kept_by_default():
    """默认不去重。「超级超级好」是刻意的强调，不是卡壳 ——
    删错的代价比留着重复大得多：用户能一眼看出多余的重复并删掉，
    但被删掉的内容他根本不知道曾经存在过。"""
    assert postprocess("超级超级好") == "超级超级好"
    assert postprocess("我觉得我觉得这个方案") == "我觉得我觉得这个方案"


def test_repeat_collapse_when_explicitly_enabled():
    raw = "嗯,我觉得我觉得这个 schema 要改"
    assert postprocess(raw, collapse_repeated=True) == "我觉得这个 schema 要改"


def test_repeated_reduplication_collapses_to_the_word():
    # 「谢谢谢谢」以单字重复四次的形式匹配，压成「谢」就错了
    assert collapse_repeats("谢谢谢谢") == "谢谢"
    assert collapse_repeats("看看看看") == "看看"


# ---------------------------------------------------------------- 停顿句号

def test_period_before_a_continuation_word_becomes_a_comma():
    # 「说完了」和「在想下一句」在音频里都是一段安静，模型分不开。
    # 但后面跟着「然后」，说明这句还没说完。
    assert (
        merge_pause_sentences("我觉得这个方案。然后我们再看别的")
        == "我觉得这个方案，然后我们再看别的"
    )


def test_all_continuation_words_are_handled():
    for word in ("但是", "而且", "所以", "因为", "就是", "还有", "其实"):
        assert merge_pause_sentences(f"前面一句。{word}后面") == f"前面一句，{word}后面"


def test_sentence_final_particle_after_a_period_is_a_break_error():
    assert merge_pause_sentences("你说的对。吗") == "你说的对，吗"


def test_a_real_sentence_boundary_is_left_alone():
    # 后面不是接续词，就没有理由怀疑这个句号
    text = "我先去吃饭。我们晚点再说。"
    assert merge_pause_sentences(text) == text


def test_decimal_points_are_never_touched():
    assert merge_pause_sentences("版本是 1.然后") == "版本是 1.然后"
    assert merge_pause_sentences("3.14 就是圆周率") == "3.14 就是圆周率"


def test_fullwidth_period_after_a_digit_still_merges():
    # 半角句点前面是数字要防着小数点，全角句号不用 —— 那个数字是巧合
    assert merge_pause_sentences("圆周率是3.14。然后呢") == "圆周率是3.14，然后呢"


def test_halfwidth_period_keeps_its_spacing():
    assert merge_pause_sentences("换个 schema. 然后重启") == "换个 schema, 然后重启"


def test_the_final_period_survives():
    assert merge_pause_sentences("就这样。").endswith("。")


def test_it_never_deletes_characters():
    # 这一步只降级标点。删掉的内容用户根本不知道曾经存在过，
    # 多余的标点他一眼就能看见并改掉 —— 两种错误的代价完全不对等。
    for text in (
        "我觉得这个方案。然后我们再看别的",
        "前面。但是后面",
        "你说的对。吗",
    ):
        before = [c for c in text if c not in "。，.,"]
        after = [c for c in merge_pause_sentences(text) if c not in "。，.,"]
        assert before == after


def test_merging_can_be_turned_off():
    text = "我觉得这个方案。然后我们再看别的"
    assert "。" in postprocess(text, merge_pause_periods=False)
    assert "。" not in postprocess(text, merge_pause_periods=True)
