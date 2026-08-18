"""口语数字和符号还原的测试。

这块的风险全在**误伤**：中文里数字词大量出现在非数字语境里。
把「一起」变成「1起」比不转换糟糕得多，所以否定用例比肯定用例更重要。
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mixdictate_server.numbers import chinese_to_int, convert_numbers, convert_symbols


# ------------------------------------------------------------ 复合数

def test_compound_numbers():
    assert chinese_to_int("三十五") == 35
    assert chinese_to_int("一百二十") == 120
    assert chinese_to_int("十五") == 15
    assert chinese_to_int("两千零五") == 2005
    assert chinese_to_int("一万三千") == 13000


def test_not_a_number():
    assert chinese_to_int("苹果") is None
    assert chinese_to_int("") is None


# ------------------------------------------------------------ 小数

def test_decimal():
    assert convert_numbers("三点一四一五九二六") == "3.1415926"
    assert convert_numbers("大概是二点五倍") == "大概是2.5倍"


def test_decimal_with_compound_whole_part():
    assert convert_numbers("三十六点五度") == "36.5度"


# ------------------------------------------------------------ 长数串

def test_digit_run():
    assert convert_numbers("验证码是三九二七") == "验证码是3927"


def test_short_run_left_alone():
    # 两个字的数字串多半是量词搭配，不是在报数
    assert convert_numbers("一二") == "一二"


# ------------------------------------------------------------ 百分比

def test_percent():
    assert convert_numbers("百分之三十") == "30%"
    assert convert_numbers("提升了百分之十五") == "提升了15%"


# ------------------------------------------------------------ 不能误伤

def test_idioms_are_preserved():
    assert convert_numbers("十分感谢") == "十分感谢"
    assert convert_numbers("万一出问题") == "万一出问题"
    assert convert_numbers("千万别忘了") == "千万别忘了"


def test_single_characters_left_alone():
    # 单个数字字符几乎总是量词或代词，不是在报数
    assert convert_numbers("一个人") == "一个人"
    assert convert_numbers("我们一起走") == "我们一起走"
    assert convert_numbers("等一下") == "等一下"


def test_plain_text_untouched():
    assert convert_numbers("这个方案挺好的") == "这个方案挺好的"


# ------------------------------------------------------------ 符号

def test_symbols_between_ascii():
    assert convert_symbols("zhou 艾特 gmail 点 com") == "zhou@gmail.com"
    assert convert_symbols("A 杠 B") == "A-B"
    assert convert_symbols("v1 斜杠 v2") == "v1/v2"


def test_symbol_words_in_chinese_context_are_preserved():
    # 这些才是真正会毁掉输出的情况
    assert convert_symbols("杠杆原理") == "杠杆原理"
    assert convert_symbols("一点也不难") == "一点也不难"
    assert convert_symbols("这个星号很大") == "这个星号很大"


def test_at_before_latin():
    assert convert_symbols("艾特 claude") == "@claude"


def test_longest_spoken_form_wins():
    # 「横杠」不能被「杠」抢先匹配掉一半
    assert convert_symbols("A 横杠 B") == "A-B"


# ------------------------------------------------------------ 单词内部不能误伤

def test_latin_symbol_words_must_stand_alone():
    """英文单词内部的 at 不能被当成符号。

    这条是被存量测试逮到的真 bug：latency 被改成了 l@ency。
    中文词没有这个问题（中文不用空格分词，「杠」不会出现在英文单词中间），
    但拉丁词必须要求两侧都是空白。
    """
    assert convert_symbols("latency 有点高") == "latency 有点高"
    assert convert_symbols("what is that") == "what is that"
    assert convert_symbols("category") == "category"


def test_standalone_latin_at_still_works():
    assert convert_symbols("zhou at gmail.com") == "zhou@gmail.com"


# ------------------------------------------------------------ 儿化音

def test_erhua_symbol_variants():
    """「GitHub 点儿 com」里的「点儿」用「点」是匹配不上的 ——
    「点」后面跟着「儿」，右侧不是 ASCII，先行断言直接失败。"""
    assert convert_symbols("GitHub 点儿 com") == "GitHub.com"
    assert convert_symbols("A 杠儿 B") == "A-B"


def test_alternative_at_spelling():
    assert convert_symbols("zhou 爱特 gmail 点 com") == "zhou@gmail.com"


def test_erhua_does_not_break_plain_text():
    assert convert_symbols("这一点儿也不难") == "这一点儿也不难"


# ------------------------------------------------------------ 时间不是小数

def test_clock_time_is_not_a_decimal():
    """「点」在中文里既是小数点也是钟点。

    这两条是复查时发现的真 bug：
      三点一刻 → 3.1刻   （「一刻」被当成小数部分）
      三点十五 → 三点15  （时间被切成一半，比原样更难读）
    """
    assert convert_numbers("三点一刻") == "三点一刻"
    assert convert_numbers("两点一刻开会") == "两点一刻开会"
    assert convert_numbers("三点十五") == "三点十五"
    assert convert_numbers("三点半") == "三点半"
    assert convert_numbers("五点钟") == "五点钟"


def test_real_decimals_still_convert():
    # 加了时间保护之后，正常的小数不能受影响
    assert convert_numbers("三点一四一五九") == "3.14159"
    assert convert_numbers("大概是二点五倍") == "大概是2.5倍"
    assert convert_numbers("三十六点五度") == "36.5度"
