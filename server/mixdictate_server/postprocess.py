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

from .numbers import convert_numbers, convert_symbols

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

# 更长的自我重复："我觉得我觉得这个方案" -> "我觉得这个方案"。
# 说话时想改口或者一时卡住，很容易把前半句重说一遍。
# 从长到短匹配：先把长短语的重复消掉，避免长短语被拆成几个短重复分别处理。
_PHRASE_REPEAT_RES = [
    re.compile(f"([{CJK}]{{{n}}})\\1")
    for n in range(6, 1, -1)
]

_STUTTER_WHITELIST = {
    # 这些叠词是正常中文，不能压缩
    "谢谢", "看看", "试试", "说说", "想想", "刚刚", "常常", "渐渐",
    "偷偷", "悄悄", "轻轻", "慢慢", "快快", "好好", "多多", "早早",
    "白白", "红红", "仅仅", "统统", "通通", "各个", "个个", "天天",
    "年年", "月月", "日日", "次次", "件件", "人人", "处处", "时时",
}


def collapse_phrase_repeats(text: str) -> str:
    """消掉紧邻的短语重复。

    口述时改口或卡壳会把前半句重说一遍："我觉得我觉得这个方案不错"。
    只处理**紧邻**的完全重复，中间隔了字就不算 —— "这个方案好，这个方案
    确实好"是正常表达，不该动。

    白名单挡住正常的叠词，比如"谢谢""看看"。
    """
    for pattern in _PHRASE_REPEAT_RES:
        text = pattern.sub(_dedupe_match, text)
    return text


def _dedupe_match(match: re.Match) -> str:
    whole, unit = match.group(0), match.group(1)

    if whole in _STUTTER_WHITELIST or unit in _STUTTER_WHITELIST:
        return whole

    # 「谢谢谢谢」会以单字「谢」重复四次的形式匹配到，压成「谢」就错了 ——
    # 白名单里存的是「谢谢」这个双字词。单元自身叠一次如果是正常叠词，
    # 就保留两份而不是一份。
    doubled = unit + unit
    if doubled in _STUTTER_WHITELIST:
        return doubled

    return unit


def strip_fillers(text: str) -> str:
    text = _LEADING_FILLER_RE.sub("", text)

    text = _STUTTER_RE.sub(_dedupe_match, text)
    return collapse_phrase_repeats(text)


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
    spoken_numbers: bool = True,
    spoken_symbols: bool = True,
) -> str:
    """完整后处理链。热词纠正在 hotwords.py 里，由调用方插在中间。

    两个开关都由客户端传进来 —— 写代码的人爱写中文全角，写代码时又想要
    半角，这个偏好没法替用户决定。
    """
    if not text or not text.strip():
        return ""
    if strip_filler_words:
        text = strip_fillers(text)

    # 数字要在符号之前：「三点一四」里的「点」是小数点，
    # 「gmail 点 com」里的才是符号。两条规则的判定条件不冲突，
    # 但先转数字能让后面少一层歧义。
    if spoken_numbers:
        text = convert_numbers(text)
    if spoken_symbols:
        text = convert_symbols(text)

    text = fix_spacing(text)
    if fullwidth_punctuation:
        text = to_fullwidth_punct(text)
    return text.strip()
