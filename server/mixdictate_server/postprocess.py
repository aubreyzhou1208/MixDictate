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


def collapse_repeats(text: str) -> str:
    """消掉紧邻的重复。**默认不启用。**

    最初以为这是稳赚的：口述卡壳时会把前半句重说一遍。但实际用下来
    误伤太多 ——「超级超级好」是刻意的口语强调，「谢谢谢谢」到底该收成
    「谢谢」还是保留，也没有可靠的判据。

    删错的代价比留着重复大得多：用户能一眼看出多余的重复并删掉，
    但被删掉的内容他根本不知道曾经存在过。所以这个功能改成要显式打开。
    """
    text = _STUTTER_RE.sub(_dedupe_match, text)
    return _collapse_phrases(text)


def _collapse_phrases(text: str) -> str:
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

    return text


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


# ------------------------------------------------- 停顿造成的句号

# 「这句说完了」和「我在想下一句怎么说」在音频里是同一件事：一段安静。
# 模型判断句子结束主要就看停顿长短，所以口述时经常在思考停顿处断句。
# 这是声学方案在口述场景下公认的弱点 —— 靠韵律判断标点，对朗读有效，
# 对口述会误判，因为说话人的停顿本来就不对应标点。
#
# 声音里分不开，**文字里常常分得开**：句号后面跟着什么，就是最好的线索。
# 用右侧上下文回头修正已经打出来的标点，也正是流式标点恢复的思路 ——
# 边界处做的判断缺右文，等右文到了再改。
#
# 这一步只把句号降级成逗号，**绝不删字**。删掉的内容用户根本不知道它
# 曾经存在过，而多余的标点他一眼就能看见并改掉。

# 这些词后面接着说的多半还是同一段话。就算原本真是新句子，
# 换成逗号也只是行文风格的差别，读起来不会错。
_CONTINUATIONS = (
    "然后", "但是", "不过", "可是", "而且", "并且", "所以", "因为", "由于",
    "就是", "还有", "另外", "以及", "或者", "至于", "于是", "接着", "后来",
    "然而", "反正", "其实", "比如", "例如", "要不", "不然", "否则", "而是",
)

# 这几个字根本不能起头，跟在句号后面一定是断错了。
# 只放绝对安全的语气词 —— 「的」「了」「过」看着也像，但「的确」
# 「了不起」「过去」都能正常开句，宁可漏掉也不误伤。
_CANNOT_START = "吗呢吧嘛们儿"

# 半角句点要防着小数点（"3.14"），全角句号不用 —— "3.14。然后" 里那个
# 句号该降级，前面是数字纯属巧合。所以两个分支的守卫不一样。
_PAUSE_PERIOD_RE = re.compile(
    r"(。|(?<!\d)\.)(\s*)(" + "|".join(_CONTINUATIONS) + r"|[" + _CANNOT_START + r"])"
)


def merge_pause_sentences(text: str) -> str:
    """把思考停顿处误加的句号降级成逗号。判据是句号后面那个词。"""

    def replace(match: re.Match) -> str:
        period, gap, following = match.groups()
        # 全角逗号后面不留空格；半角的把原来的空格照原样还回去
        if period == "。":
            return "，" + following
        return "," + gap + following

    return _PAUSE_PERIOD_RE.sub(replace, text)


# ------------------------------------------------- 长句缺逗号

# 跟上面那条正好相反的毛病：一句话说了很长却一个逗号都没有。
#
# 成因是同一件事的另一面。模型下标点主要靠停顿长短，而说得顺的时候
# 分句处根本不停 —— 没有停顿，就没有逗号。我们又主动把长静音压短了
# （maxPauseSeconds），等于把这条线索削得更薄。
#
# 同样从文字侧补：接续词就是分句的位置，这一点不用听也知道。
# **只加逗号，不动任何字。**

# 这些词起头，几乎一定是新的一个分句
_CLAUSE_STARTERS = (
    "然后", "但是", "不过", "可是", "而且", "并且", "所以", "因为", "由于",
    "还有", "另外", "或者", "于是", "接着", "后来", "然而", "要不", "不然",
    "否则", "如果", "虽然", "尽管", "至于", "以及", "那么", "结果", "反正",
)

# 前面攒够这么多字才断。太短的话「然后」出现在句首也会被塞个逗号，
# 反而更碎。
_MIN_CLAUSE_CHARS = 8

def split_long_clauses(text: str) -> str:
    """长句里的接续词前面补逗号。"""
    out: list[str] = []
    since_punct = 0

    index = 0
    length = len(text)
    while index < length:
        char = text[index]

        if char in "，。！？；：,.!?;:\n":
            since_punct = 0
            out.append(char)
            index += 1
            continue

        matched = ""
        if since_punct >= _MIN_CLAUSE_CHARS:
            for word in _CLAUSE_STARTERS:
                if text.startswith(word, index):
                    matched = word
                    break

        if matched:
            # 前面已经是标点或空白就不重复加
            if out and out[-1] not in "，。！？；：,.!?;: \n":
                out.append("，")
            out.append(matched)
            index += len(matched)
            since_punct = len(matched)
            continue

        out.append(char)
        since_punct += 1
        index += 1

    return "".join(out)


# ---------------------------------------------------------------- 组装

def postprocess(
    text: str,
    *,
    strip_filler_words: bool = True,
    collapse_repeated: bool = False,
    fullwidth_punctuation: bool = True,
    spoken_numbers: bool = True,
    spoken_symbols: bool = True,
    merge_pause_periods: bool = True,
    split_clauses: bool = True,
) -> str:
    """完整后处理链。热词纠正在 hotwords.py 里，由调用方插在中间。

    两个开关都由客户端传进来 —— 写代码的人爱写中文全角，写代码时又想要
    半角，这个偏好没法替用户决定。
    """
    if not text or not text.strip():
        return ""
    if strip_filler_words:
        text = strip_fillers(text)
    if collapse_repeated:
        text = collapse_repeats(text)

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
    # 放在最后：前面几步可能改动标点形态（半角转全角），
    # 这里要看的正是最终那个字符
    if merge_pause_periods:
        text = merge_pause_sentences(text)
    # 放在降级之后：降级会把句号变成逗号，那本身就是一个分句边界，
    # 先做完再来判断"这一段有多长没断过"才准
    if split_clauses:
        text = split_long_clauses(text)
    return text.strip()
