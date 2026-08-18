"""路径解析的测试 —— 装进 venv 之后仓库目录可能不存在，不能依赖它。"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mixdictate_server import paths


def test_support_dir_honours_override(monkeypatch, tmp_path):
    monkeypatch.setenv("MIXDICTATE_HOME", str(tmp_path))
    assert paths.support_dir() == tmp_path


def test_hotwords_seeded_on_first_run(monkeypatch, tmp_path):
    monkeypatch.delenv("MIXDICTATE_HOTWORDS", raising=False)
    monkeypatch.setenv("MIXDICTATE_HOME", str(tmp_path))

    target = paths.hotwords_path()

    assert target == tmp_path / "hotwords.txt"
    assert target.exists(), "首次运行应当从包内种子词表复制一份出来"
    assert "Kubernetes" in target.read_text(encoding="utf-8")


def test_hotwords_not_overwritten_on_later_runs(monkeypatch, tmp_path):
    monkeypatch.delenv("MIXDICTATE_HOTWORDS", raising=False)
    monkeypatch.setenv("MIXDICTATE_HOME", str(tmp_path))

    first = paths.hotwords_path()
    first.write_text("我的自定义词表\n", encoding="utf-8")

    # 第二次调用不能把用户编辑过的词表覆盖回默认值
    assert paths.hotwords_path().read_text(encoding="utf-8") == "我的自定义词表\n"


def test_explicit_hotwords_env_wins(monkeypatch, tmp_path):
    custom = tmp_path / "elsewhere.txt"
    custom.write_text("Docker\n", encoding="utf-8")
    monkeypatch.setenv("MIXDICTATE_HOTWORDS", str(custom))
    assert paths.hotwords_path() == custom


def test_default_hotwords_ships_with_package():
    # 打包漏了这个文件的话，装到 venv 里就没东西可播种了
    assert paths.DEFAULT_HOTWORDS.exists()
