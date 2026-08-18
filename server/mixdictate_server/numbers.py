"""把口语里的数字和符号还原成书面形式。

「三点一四一五九二六」→「3.1415926」，「艾特 gmail 点 com」→「@gmail.com」。

难点全在**克制**上。中文里数字词大量出现在非数字语境里：
「一起」「一定」「十分感谢」「万一」「第一」——全都不该动。所以这里
不做通用的中文数字转换，只处理几种能明确判定为数字的形态：

  · 小数：X 点 YYY（点后面跟着连续数字）
  · 长数串：三个以上连续的个位数（电话号、验证码、编号）
  · 带单位的复合数：三十五、一百二十（至少两个字，含十/百/千/万）
  · 百分之 X

符号更保守：只在紧邻 ASCII 字母数字时才转，否则「杠杆」会变成「-杆」。
"""

from __future__ import annotations

import re

DIGITS = {
    "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
}
UNITS = {"十": 10, "百": 100, "千": 1000}
BIG_UNITS = {"万": 10**4, "亿": 10**8}

DIGIT_CHARS = "".join(DIGITS)
UNIT_CHARS = "".join(UNITS) + "".join(BIG_UNITS)

# 这些词里的数字字符属于固定搭配，不是在报数
IDIOMS = {
    "十分", "万一", "一定", "一起", "一样", "一直", "一般", "一些", "一点",
    "一下", "一切", "一路", "一边", "一面", "一心", "一致", "十足", "百般",
    "千万", "万万", "三三两两", "五花八门", "七上八下", "十全十美",
}


def chinese_to_int(text: str) -> int | None:
    """把「三十五」「一百二十」这类复合数转成整数。看不懂就返回 None。"""
    if not text:
        return None

    total = 0      # 已经结算掉的部分（万、亿之前的）
    section = 0    # 当前小节
    number = 0     # 当前数字
    seen = False

    for char in text:
        if char in DIGITS:
            number = DIGITS[char]
            seen = True
        elif char in UNITS:
            # 「十五」这种省略了前面的一
            section += (number or 1) * UNITS[char]
            number = 0
            seen = True
        elif char in BIG_UNITS:
            section = (section + number) or 1
            total += section * BIG_UNITS[char]
            section = 0
            number = 0
            seen = True
        else:
            return None

    return total + section + number if seen else None


# ---------------------------------------------------------------- 各条规则

# 「点」在中文里既是小数点也是钟点。跟在后面的这些字说明它是时间，
# 不是小数：「三点一刻」不是 3.1 刻。
_TIME_SUFFIX = "刻钟半"

_PERCENT_RE = re.compile(f"百分之([{DIGIT_CHARS}{UNIT_CHARS}]+)")
_DECIMAL_RE = re.compile(
    f"([{DIGIT_CHARS}{UNIT_CHARS}]+)点([{DIGIT_CHARS}]+)(?![{_TIME_SUFFIX}])"
)
_RUN_RE = re.compile(f"[{DIGIT_CHARS}]{{3,}}")

# 前面是「点」的复合数不转：「三点十五」是时间，转成「三点15」只会更难读。
# 真正的小数已经被上面的 _DECIMAL_RE 整体处理掉了。
_COMPOUND_RE = re.compile(
    f"(?<!点)[{DIGIT_CHARS}]*[{UNIT_CHARS}][{DIGIT_CHARS}{UNIT_CHARS}]*"
)


def _digits_only(text: str) -> str:
    return "".join(str(DIGITS[c]) for c in text)


def convert_numbers(text: str) -> str:
    """按从具体到宽泛的顺序套用规则。顺序很重要 ——
    小数要先于长数串处理，否则「三点一四」的「一四」会被单独转掉。"""
    if not text:
        return text

    def percent(match: re.Match) -> str:
        value = chinese_to_int(match.group(1))
        return f"{value}%" if value is not None else match.group(0)

    def decimal(match: re.Match) -> str:
        whole = chinese_to_int(match.group(1))
        if whole is None:
            return match.group(0)
        return f"{whole}.{_digits_only(match.group(2))}"

    def run(match: re.Match) -> str:
        return _digits_only(match.group(0))

    def compound(match: re.Match) -> str:
        token = match.group(0)
        if token in IDIOMS or len(token) < 2:
            return token
        value = chinese_to_int(token)
        return str(value) if value is not None else token

    text = _PERCENT_RE.sub(percent, text)
    text = _DECIMAL_RE.sub(decimal, text)
    text = _RUN_RE.sub(run, text)
    text = _COMPOUND_RE.sub(compound, text)
    return text


# ---------------------------------------------------------------- 符号

# 只在紧邻 ASCII 字母数字时才替换。否则「杠杆」会变成「-杆」，
# 「一点也不」会变成「一.也不」—— 这类误伤比不转换糟糕得多。
SPOKEN_SYMBOLS = {
    "艾特": "@",
    "爱特": "@",
    "杠": "-",
    "杠儿": "-",
    "横杠": "-",
    "横杠儿": "-",
    "减号": "-",
    "斜杠": "/",
    "斜杠儿": "/",
    "反斜杠": "\\",
    "下划线": "_",
    "井号": "#",
    "星号": "*",
    "加号": "+",
    "等号": "=",
    # 儿化音要单独列。"GitHub 点儿 com" 里的"点儿"用"点"是匹配不上的 ——
    # "点"后面跟着"儿"，右侧不是 ASCII，先行断言直接失败。
    "点儿": ".",
    "点": ".",
}

# 拉丁字母的口语符号必须两侧都有空白才算数。
# 用跟中文词一样的"紧邻字母数字"规则会匹配到单词内部 ——
# latency 里的 at 会被替换成 @，变成 l@ency。中文词没有这个问题，
# 因为中文不用空格分词，「杠」不会出现在英文单词中间。
LATIN_SPOKEN_SYMBOLS = {
    "at": "@",
    "dot": ".",
    "dash": "-",
    "slash": "/",
    "underscore": "_",
}

_ASCII_WORD = "A-Za-z0-9"


def convert_symbols(text: str) -> str:
    """把夹在字母数字之间的口语符号还原成符号本身。"""
    if not text:
        return text

    # 长的先替换，否则「横杠」会被「杠」抢先匹配掉一半
    for spoken in sorted(SPOKEN_SYMBOLS, key=len, reverse=True):
        symbol = SPOKEN_SYMBOLS[spoken]
        pattern = (
            f"(?<=[{_ASCII_WORD}])\\s*{re.escape(spoken)}\\s*(?=[{_ASCII_WORD}])"
        )
        text = re.sub(pattern, symbol.replace("\\", "\\\\"), text)

    # 拉丁词要求两侧都是空白，不能只看紧邻字符
    for spoken in sorted(LATIN_SPOKEN_SYMBOLS, key=len, reverse=True):
        symbol = LATIN_SPOKEN_SYMBOLS[spoken]
        pattern = (
            f"(?<=[{_ASCII_WORD}])\\s+{re.escape(spoken)}\\s+(?=[{_ASCII_WORD}])"
        )
        text = re.sub(pattern, symbol, text, flags=re.IGNORECASE)

    # 「艾特 gmail」这种开头就是符号的形态，右邻是字母也算
    text = re.sub(f"艾特\\s*(?=[{_ASCII_WORD}])", "@", text)
    return text
