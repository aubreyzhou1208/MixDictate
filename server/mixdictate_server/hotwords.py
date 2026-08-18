"""热词表：喂给解码器做词汇偏置，再对输出做一次确定性纠正。

两层机制互补：
  · context 偏置是"软"的 —— 让模型更倾向于听出这些词，但不保证
  · 别名替换是"硬"的 —— 模型仍然听错时，按规则强行改回来

词表格式（config/hotwords.txt）：
    # 井号开头是注释
    Kubernetes              ← 普通热词：偏置 + 大小写归一
    Supabase
    k8s
    咖啡内特斯 => Kubernetes  ← 别名：左边听错的写法强制改成右边
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

# context 太长会拖慢解码且稀释偏置效果，超出部分截断
MAX_CONTEXT_TERMS = 120
MAX_CONTEXT_CHARS = 1000

_HAS_LATIN = re.compile(r"[A-Za-z]")


@dataclass
class HotwordTable:
    terms: list[str] = field(default_factory=list)
    aliases: dict[str, str] = field(default_factory=dict)

    # ------------------------------------------------------------ 加载

    @classmethod
    def load(cls, path: str | Path) -> "HotwordTable":
        table = cls()
        p = Path(path)
        if not p.exists():
            return table

        for raw in p.read_text(encoding="utf-8").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if "=>" in line:
                wrong, _, right = line.partition("=>")
                wrong, right = wrong.strip(), right.strip()
                if wrong and right:
                    table.aliases[wrong] = right
                    if right not in table.terms:
                        table.terms.append(right)
            elif line not in table.terms:
                table.terms.append(line)
        return table

    # ------------------------------------------------------------ 偏置

    def context(self) -> str:
        """给 mlx-qwen3-asr 的 context= 参数用的空格分隔串。"""
        picked: list[str] = []
        total = 0
        for term in self.terms[:MAX_CONTEXT_TERMS]:
            if total + len(term) + 1 > MAX_CONTEXT_CHARS:
                break
            picked.append(term)
            total += len(term) + 1
        return " ".join(picked)

    # ------------------------------------------------------------ 纠正

    def apply(self, text: str) -> str:
        """别名替换 + 拉丁词大小写归一。"""
        if not text:
            return text

        # 长的别名先替换，避免短词把长词切碎
        for wrong in sorted(self.aliases, key=len, reverse=True):
            text = self._replace_term(text, wrong, self.aliases[wrong])

        # 只对含拉丁字母的热词做大小写归一 —— 中文词没有大小写问题
        for term in self.terms:
            if _HAS_LATIN.search(term):
                text = self._replace_term(text, term, term, ignore_case=True)
        return text

    @staticmethod
    def _replace_term(
        text: str, needle: str, replacement: str, *, ignore_case: bool = False
    ) -> str:
        # 不用 \b：热词里常有 "C++"、".NET"、"k8s" 这类含非单词字符的写法，
        # \b 在它们边界上的行为不符合直觉。这里显式要求两侧不是字母数字。
        pattern = (
            r"(?<![A-Za-z0-9])" + re.escape(needle) + r"(?![A-Za-z0-9])"
        )
        flags = re.IGNORECASE if ignore_case else 0
        return re.sub(pattern, replacement.replace("\\", "\\\\"), text, flags=flags)
