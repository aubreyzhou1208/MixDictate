"""中英混说场景的转写后处理。

Qwen3-ASR 的原始输出在中英混说时有几个稳定的毛病：
  1. 口语填充词全部保留（"嗯"、"呃"、"就是就是"）
  2. 中文之间偶尔插入空格，中英之间反而不加空格
  3. 标点是半角的，中文语境下看着别扭
  4. 英文术语大小写随机（"kubernetes"、"github"）

这里按固定顺序修复。顺序有讲究：热词纠正必须在加空格之前，
否则 "k8s" 这类词被空格切开后就匹配不上了。
"""

from __future__ import annotations

import re

# ---------------------------------------------------------------- 字符类

# CJK 统一表意文字 + 中文标点。不含日文假名，避免误伤。
CJK = r"一-鿿㐀-䶿"
CJK_PUNCT = r"　-〿＀-￯"

_CJK_RE = re.compile(f"[{CJK}]")


def _is_cjk(ch: str) -> bool:
    return bool(_CJK_RE.match(ch))


def _is_ascii_alnum(ch: str) -> bool:
    # 注意不能直接用 str.isalnum()：中文字符它也返回 True
    return ch.isascii() and ch.isalnum()


# ---------------------------------------------------------------- 1. 填充词

# 只删除"独立成句"或"句首"的填充词。像"嗯嗯我知道"里的"嗯嗯"要删，
# 但"这个方案"里的"这个"必须留着 —— 所以 FILLERS 里不放"这个""那个"。
_FILLERS = ["嗯", "呃", "额", "唔", "诶", "欸"]

# 句首填充词：后面跟着实质内容
# 尾部把紧跟的标点也吃掉：口语里"嗯，"整体就是一个语气停顿，
# 只删"嗯"会留下一个孤零零的逗号。
_LEADING_FILLER_RE = re.compile(
    r"(?:^|(?<=[。！？；，、\n]))\s*(?:" + "|".join(_FILLERS) + r")+[，,、。.！!？?\s]*"
)

# 卡壳重复："就是就是" -> "就是"，"我我我" -> "我"
_STUTTER_RE = re.compile(f"([{CJK}]{{1,2}}?)\\1{{1,}}")

_STUTTER_WHITELIST = {
    # 这些叠词是正常中文，不能压缩
    "谢谢", "看看", "试试", "说说", "想想", "刚刚", "常常", "渐渐",
    "偷偷", "悄悄", "轻轻", "慢慢", "快快", "好好", "多多", "早早",
    "白白", "红红", "仅仅", "统统", "通通", "各个", "个个", "天天",
    "年年", "月月", "日日", "次次", "件件", "人人", "处处", "时时",
}


def strip_fillers(text: str) -> str:
    text = _LEADING_FILLER_RE.sub("", text)

    def _dedupe(m: re.Match) -> str:
        whole, unit = m.group(0), m.group(1)
        if whole in _STUTTER_WHITELIST:
            return whole
        return unit

    return _STUTTER_RE.sub(_dedupe, text)


# ---------------------------------------------------------------- 2. 空格

# 中文字符之间的空格是 ASR 的产物，删掉
_CJK_SPACE_RE = re.compile(f"(?<=[{CJK}{CJK_PUNCT}])\\s+(?=[{CJK}{CJK_PUNCT}])")

# 盘古之白：中文与拉丁字母/数字之间加一个空格
_PANGU_LEFT_RE = re.compile(f"(?<=[{CJK}])(?=[A-Za-z0-9@#$%^&*])")
_PANGU_RIGHT_RE = re.compile(f"(?<=[A-Za-z0-9%\\)\\]}}])(?=[{CJK}])")


def fix_spacing(text: str) -> str:
    text = _CJK_SPACE_RE.sub("", text)
    text = _PANGU_LEFT_RE.sub(" ", text)
    text = _PANGU_RIGHT_RE.sub(" ", text)
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text.strip()


# ---------------------------------------------------------------- 3. 标点

# 只在"前一个字符是中文"时才转全角。这样 "3.14"、"e.g."、
# "config.json" 里的半角标点不会被误伤。
_HALF_TO_FULL = {
    ",": "，",
    "?": "？",
    "!": "！",
    ":": "：",
    ";": "；",
}


def to_fullwidth_punct(text: str) -> str:
    """半角标点转全角。

    判定依据是**当前小句**里有没有中文，而不是标点紧邻的那个字符 ——
    中英混说时句子经常以英文词结尾（"换个 schema?"），按紧邻字符判定
    会漏掉这些，而它们恰恰是最需要转的。

    两个例外保护：
      · 标点两侧都是字母/数字且无空格时不动（保住 "3:30"、"a,b"）
      · 句点只在小句含中文、且后面是空格或结尾、前面不是数字时才转
        （保住 "3.14"、"config.json"）

    已知边界：中文句子里内联的英文代码片段 "foo(a, b)" 里那个逗号
    仍会被转成全角。口述场景下极少出现，暂不处理。
    """
    out: list[str] = []
    segment_has_cjk = False

    for i, ch in enumerate(text):
        prev = text[i - 1] if i > 0 else ""
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if _is_cjk(ch):
            segment_has_cjk = True

        glued = _is_ascii_alnum(prev) and _is_ascii_alnum(nxt)

        if ch in _HALF_TO_FULL and segment_has_cjk and not glued:
            out.append(_HALF_TO_FULL[ch])
        elif (
            ch == "."
            and segment_has_cjk
            and nxt in ("", " ", "\n")
            and not prev.isdigit()
        ):
            out.append("。")
        else:
            out.append(ch)

        # 句末标点之后开启新的小句，重新判定语言
        if ch in "。！？.!?\n":
            segment_has_cjk = False

    result = "".join(out)
    # 全角标点后面不需要再补空格
    result = re.sub(f"([{CJK_PUNCT}]) +", r"\1", result)
    return result


# ---------------------------------------------------------------- 组装

def postprocess(
    text: str,
    *,
    strip_filler_words: bool = True,
    fullwidth_punctuation: bool = True,
) -> str:
    """完整后处理链。热词纠正在 hotwords.py 里，由调用方插在中间。

    两个开关都由客户端传进来 —— 写代码的人爱写中文全角，写代码时又想要
    半角，这个偏好没法替用户决定。
    """
    if not text or not text.strip():
        return ""
    if strip_filler_words:
        text = strip_fillers(text)
    text = fix_spacing(text)
    if fullwidth_punctuation:
        text = to_fullwidth_punct(text)
    return text.strip()
