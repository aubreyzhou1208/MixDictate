"""热词候选挖掘。

这个功能有个必须守住的边界：**它只读本机那个转写日志**。最初的设计是
读当前输入框的内容来学词，那样能拿到更准的候选，但代价是去读用户正在
写的东西 —— 邮件、密码框旁边的字段、别人发来的消息。换成只看转写日志
之后，读到的东西全都是用户自己对着这个 App 说过的话。

另一条边界：**挖出来的只是候选，永远不自动入表**。听错的词一旦进了热词
表，会让模型把这个错误听得更稳定 —— 那比不加还糟。
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mixdictate_server.hotwords import (
    HotwordTable,
    append_alias,
    append_terms,
    mine_candidates,
    observe_correction,
    pending_corrections,
)

LOG = """2026-08-19 10:00:00  [1.0s]
  原始: 这个 pipeline 的 latency 有点高
  输出: 这个 pipeline 的 latency 有点高

2026-08-19 10:01:00  [1.0s]
  原始: 我们要不要换个 schema 这个 pipeline 太慢了
  输出: 我们要不要换个 schema，这个 pipeline 太慢了
"""


def test_repeated_term_becomes_a_candidate():
    assert ("pipeline", 2) in mine_candidates(LOG)


def test_a_term_said_only_once_is_not_enough():
    # 说过一次可能只是路过，说过两次才像是这个人会反复用的词
    terms = [term for term, _ in mine_candidates(LOG)]
    assert "schema" not in terms
    assert "latency" not in terms


def test_terms_already_in_the_table_are_skipped():
    assert mine_candidates(LOG, existing={"Pipeline"}) == []


def test_common_words_are_filtered_out():
    # 停用词表注定不完整 —— 手写的表永远会漏，所以它不是安全边界，
    # 只是省事。真正的保证是"挖出来的一律只是候选，要用户勾了才进表"。
    log = "\n".join(["  原始: this is the thing that you have"] * 5)
    assert mine_candidates(log) == []


def test_only_the_model_output_is_read():
    # 只看「原始」行。看「输出」等于把后处理改过的结果又喂回去，
    # 让规则自我强化。
    log = """  原始: 说了一句普通的话
  输出: postprocessed postprocessed postprocessed
"""
    assert mine_candidates(log, min_count=1) == []


def test_cjk_is_never_mined():
    # 中文词很难从统计上分清"用户的术语"和"听错的字"，
    # 把听错的加进热词表会让它错得更稳定
    log = "\n".join(["  原始: 咖啡内特斯 咖啡内特斯 咖啡内特斯"] * 3)
    assert mine_candidates(log) == []


def test_ranking_is_stable(tmp_path):
    log = "\n".join(
        ["  原始: alpha bravo alpha"] * 2 + ["  原始: bravo charlie charlie"] * 2
    )
    first = mine_candidates(log)
    assert first == mine_candidates(log)
    # 次数多的排前面
    counts = [count for _, count in first]
    assert counts == sorted(counts, reverse=True)


def test_append_writes_only_new_terms(tmp_path):
    path = tmp_path / "hotwords.txt"
    path.write_text("Kubernetes\n", encoding="utf-8")

    assert append_terms(path, ["pipeline", "Kubernetes"]) == 1
    table = HotwordTable.load(path)
    assert "pipeline" in table.terms
    assert table.terms.count("Kubernetes") == 1


def test_append_is_idempotent(tmp_path):
    path = tmp_path / "hotwords.txt"
    assert append_terms(path, ["pipeline"]) == 1
    assert append_terms(path, ["pipeline"]) == 0


def test_append_keeps_the_original_casing():
    # 大小写往往是有意义的：GitHub、k8s、gRPC
    log = "\n".join(["  原始: 用的是 GitHub Actions"] * 2)
    terms = [term for term, _ in mine_candidates(log)]
    assert "GitHub" in terms


# ---------------------------------------------------------------- 纠正学习

def test_same_correction_three_times_gets_learned(tmp_path):
    store = tmp_path / "corrections.json"
    assert observe_correction(store, "开普内特斯", "Kubernetes") == (1, False)
    assert observe_correction(store, "开普内特斯", "Kubernetes") == (2, False)
    # 一次是手滑，两次可能是巧合，三次就是"它每次都听错这个词"
    assert observe_correction(store, "开普内特斯", "Kubernetes") == (3, True)


def test_different_corrections_are_counted_separately(tmp_path):
    store = tmp_path / "corrections.json"
    observe_correction(store, "甲", "乙")
    observe_correction(store, "丙", "丁")
    assert observe_correction(store, "甲", "乙") == (2, False)


def test_a_no_op_correction_is_ignored(tmp_path):
    store = tmp_path / "corrections.json"
    assert observe_correction(store, "一样", "一样") == (0, False)
    assert observe_correction(store, "", "东西") == (0, False)


def test_a_corrupt_store_does_not_break_learning(tmp_path):
    # 这只是个计数器，存坏了不值得让听写跟着出错
    store = tmp_path / "corrections.json"
    store.write_text("{ 这不是 JSON", encoding="utf-8")
    assert observe_correction(store, "甲", "乙") == (1, False)


def test_learned_alias_is_written_once(tmp_path):
    path = tmp_path / "hotwords.txt"
    assert append_alias(path, "开普内特斯", "Kubernetes") is True
    assert append_alias(path, "开普内特斯", "Kubernetes") is False
    assert HotwordTable.load(path).aliases["开普内特斯"] == "Kubernetes"


def test_pending_lists_counts_below_the_threshold(tmp_path):
    store = tmp_path / "corrections.json"
    observe_correction(store, "甲", "乙")
    observe_correction(store, "甲", "乙")
    observe_correction(store, "丙", "丁")

    rows = pending_corrections(store)
    assert rows[0] == ("甲", "乙", 2)   # 次数多的排前面
    assert ("丙", "丁", 1) in rows
