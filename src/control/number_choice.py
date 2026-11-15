"""Strict spoken numbers for an already-visible, numbered target overlay."""

from dataclasses import dataclass
import re
import unicodedata
from typing import Optional


@dataclass(frozen=True)
class NumberChoice:
    number: Optional[int] = None
    cancelled: bool = False


_SMALL = ("zero one two three four five six seven eight nine ten eleven twelve "
          "thirteen fourteen fifteen sixteen seventeen eighteen nineteen").split()
_TENS = "twenty thirty forty fifty sixty seventy eighty ninety".split()
_EN_NUMBERS = {name: number for number, name in enumerate(_SMALL)}
for _index, _name in enumerate(_TENS, 2):
    _EN_NUMBERS[_name] = _index * 10
    for _unit in range(1, 10):
        _EN_NUMBERS[_name + " " + _SMALL[_unit]] = _index * 10 + _unit
_EN_NUMBERS["one hundred"] = 100

_ZH_DIGITS = "零一二三四五六七八九"
_ZH_NUMBERS = {name: number for number, name in enumerate(_ZH_DIGITS)}
_ZH_NUMBERS.update({"两": 2, "兩": 2, "一百": 100})
for _number in range(10, 100):
    _tens, _unit = divmod(_number, 10)
    _name = ("" if _tens == 1 else _ZH_DIGITS[_tens]) + "十"
    _ZH_NUMBERS[_name + (_ZH_DIGITS[_unit] if _unit else "")] = _number

_EN_WRAPPER = re.compile(
    r"^(?:please )?(?:(?:select|choose|pick|go to|move to) )?"
    r"(?:(?:number|option) )?(.+?)(?: please)?$")
_ZH_WRAPPER = re.compile(
    r"^(?:请|請)?(?:(?:选择|選擇|选中|選中|选|選))?"
    r"(?:第)?(.+?)(?:号|號|个|個|项|項)?$")
_CANCEL = {"cancel", "never mind", "nevermind", "stop", "取消", "算了", "不要了", "停止"}


def parse_number_choice(transcript: str, count: int) -> NumberChoice:
    """Read one whole utterance; no numbers embedded in conversation/actions.

    Number labels are meaningful only while the coordinator has a live overlay.
    Range checking binds an answer to that exact list; a number never supplies
    coordinates, a mouse action, or an arbitrary native target ID.
    """
    if type(count) is not int or not 1 <= count <= 100:
        raise ValueError("Numbered choices must contain between 1 and 100 targets")
    if not isinstance(transcript, str):
        raise ValueError("Numbered choice transcript must be text")
    if len(transcript) > 4000:
        return NumberChoice()
    text = " ".join(unicodedata.normalize("NFKC", transcript).casefold().split())
    text = text.strip(" .!?。，？！")
    cancel = re.sub(r"^(?:please |请|請)", "", text)
    cancel = re.sub(r"(?: please|谢谢|謝謝)$", "", cancel)
    if cancel in _CANCEL:
        return NumberChoice(cancelled=True)
    # Whisper may transcribe a bare spoken two/four as these homophones.
    # Restrict aliases to the entire utterance, avoiding e.g. 'move to'.
    if text in {"to", "too", "for"}:
        number = {"to": 2, "too": 2, "for": 4}[text]
        return NumberChoice(number if number <= count else None)
    english = _EN_WRAPPER.fullmatch(text)
    chinese_text = re.sub(r"(?<=[\u3400-\u9fff])\s+|\s+(?=[\u3400-\u9fff])", "", text)
    chinese = _ZH_WRAPPER.fullmatch(chinese_text)
    names = [text]
    if english:
        names.append(english.group(1))
    if chinese:
        names.append(chinese.group(1))
    for name in names:
        number = None
        if re.fullmatch(r"[1-9][0-9]{0,2}", name):
            number = int(name)
        elif name in _ZH_NUMBERS:
            number = _ZH_NUMBERS[name]
        else:
            # Spoken 'twenty-one' and 'twenty one' are the same number.
            number = _EN_NUMBERS.get(name.replace("-", " "))
        if number is not None and 1 <= number <= count:
            return NumberChoice(number)
    return NumberChoice()
