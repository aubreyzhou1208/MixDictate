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


# ---------------------------------------------------------------- 候选挖掘

# 常见词不该进热词表。偏置它们毫无意义，还会稀释真正需要偏置的那些 ——
# context 有长度上限，塞满了等于把有用的挤出去。
#
# 这个表**注定不完整**，手写的停用词表永远会漏。所以它不是安全边界，
# 只是省事：挖出来的东西一律是候选，要用户一条条勾了才进表。
# 真正的保证在那一步，不在这里。
_COMMON_LATIN = {
    "the", "and", "for", "you", "this", "that", "with", "have", "was", "are",
    "not", "but", "can", "all", "get", "out", "one", "how", "now", "what",
    "when", "then", "them", "they", "there", "here", "just", "like", "some",
    "about", "would", "could", "should", "make", "made", "your", "from",
    "ok", "okay", "yes", "no", "hi", "hey", "well", "very", "really",
    "thing", "things", "stuff", "kind", "sort", "part", "time", "way",
    "want", "need", "know", "think", "see", "look", "take", "come", "going",
    "good", "great", "nice", "little", "much", "more", "most", "other",
    "into", "over", "than", "because", "also", "only", "even", "still",
    "yeah", "yep", "hmm", "actually", "basically", "maybe", "probably",
}

_LATIN_TOKEN = re.compile(r"[A-Za-z][A-Za-z0-9._+-]{1,}")


def mine_candidates(
    transcripts: str,
    *,
    existing: set[str] | None = None,
    min_count: int = 2,
    limit: int = 40,
) -> list[tuple[str, int]]:
    """从转写记录里找可能值得加进热词表的词。

    只看 **原始** 那几行 —— 也就是模型自己吐出来的东西。看「输出」的话
    会把后处理改过的结果又喂回去，等于让规则自我强化。

    只挑英文/拉丁词：热词表最能帮上忙的正是这些（技术名词、产品名、
    缩写），而中文词很难从统计上判断是"用户常说的术语"还是"听错的字"，
    把听错的加进热词表会让它错得更稳定 —— 那比不加还糟。

    出现次数是唯一的证据，所以要求至少出现两次：说过一次的词可能只是
    路过，说过两次以上才像是这个人会反复用的词。
    """
    existing_lower = {term.lower() for term in (existing or set())}
    counts: dict[str, int] = {}
    seen_form: dict[str, str] = {}

    for line in transcripts.splitlines():
        stripped = line.strip()
        if not stripped.startswith("原始:"):
            continue
        body = stripped[len("原始:"):]

        for token in _LATIN_TOKEN.findall(body):
            lowered = token.lower()
            if lowered in _COMMON_LATIN or lowered in existing_lower:
                continue
            if len(token) < 3:
                continue
            counts[lowered] = counts.get(lowered, 0) + 1
            # 保留第一次见到的写法，大小写往往是有意义的（GitHub、k8s）
            seen_form.setdefault(lowered, token)

    ranked = [
        (seen_form[key], count)
        for key, count in counts.items()
        if count >= min_count
    ]
    # 次数多的在前；同样多的按字母序，保证结果稳定可测
    ranked.sort(key=lambda pair: (-pair[1], pair[0].lower()))
    return ranked[:limit]


def append_terms(path: str | Path, terms: list[str]) -> int:
    """把选中的词追加进词表，返回真正写进去的条数。

    重复的跳过 —— 用户可能连着点两次，词表里出现两条一样的没有意义。
    """
    p = Path(path)
    table = HotwordTable.load(p)
    existing = {term.lower() for term in table.terms}

    fresh = []
    for term in terms:
        cleaned = term.strip()
        if not cleaned or cleaned.lower() in existing:
            continue
        existing.add(cleaned.lower())
        fresh.append(cleaned)

    if not fresh:
        return 0

    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as handle:
        handle.write("\n# 从听写记录里挑出来的\n")
        for term in fresh:
            handle.write(term + "\n")
    return len(fresh)


# ---------------------------------------------------------------- 纠正学习

# 攒够这么多次同一个纠正才写进词表。
#
# 一次是手滑，两次可能是巧合，三次就是"它每次都听错这个词"。
# 门槛太低会把用户的临时改动学成规则，太高又永远学不到。
LEARN_THRESHOLD = 3


def observe_correction(
    store_path: str | Path,
    wrong: str,
    right: str,
    *,
    threshold: int = LEARN_THRESHOLD,
) -> tuple[int, bool]:
    """记一次"用户把 wrong 改成了 right"，返回（累计次数，这次是否入表）。

    计数存在本机一个 JSON 里，不联网、不上报。
    """
    import json

    wrong, right = wrong.strip(), right.strip()
    if not wrong or not right or wrong == right:
        return (0, False)

    p = Path(store_path)
    data: dict[str, int] = {}
    if p.exists():
        try:
            loaded = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                data = {k: int(v) for k, v in loaded.items() if isinstance(v, int)}
        except (json.JSONDecodeError, OSError, ValueError):
            # 存坏了就从头开始记。这只是个计数器，不值得为它中断听写。
            data = {}

    key = f"{wrong} => {right}"
    count = data.get(key, 0) + 1
    data[key] = count

    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True),
        encoding="utf-8",
    )

    return (count, count >= threshold)


def append_alias(path: str | Path, wrong: str, right: str) -> bool:
    """把学到的纠正写成一条别名规则。已经有了就不重复写。"""
    p = Path(path)
    table = HotwordTable.load(p)
    if table.aliases.get(wrong) == right:
        return False

    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as handle:
        handle.write(f"\n# 你改过 {LEARN_THRESHOLD} 次，自动学的\n")
        handle.write(f"{wrong} => {right}\n")
    return True


def pending_corrections(store_path: str | Path) -> list[tuple[str, str, int]]:
    """还没到门槛的纠正。列出来让用户可以提前手动确认。"""
    import json

    p = Path(store_path)
    if not p.exists():
        return []
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []
    if not isinstance(data, dict):
        return []

    out = []
    for key, count in data.items():
        if not isinstance(count, int) or "=>" not in key:
            continue
        wrong, _, right = key.partition("=>")
        out.append((wrong.strip(), right.strip(), count))
    out.sort(key=lambda row: (-row[2], row[0]))
    return out
