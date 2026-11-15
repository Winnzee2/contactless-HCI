"""Numbered followups cannot turn conversation into a screen selection."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from control.number_choice import NumberChoice, parse_number_choice


class TestNumberChoice(unittest.TestCase):
    def test_digits_and_spoken_english_and_chinese(self):
        cases = (("One.", 1), ("two!", 2), ("eleven", 11), ("nineteen", 19),
                 ("twenty-one", 21), ("forty two", 42), ("ninety nine", 99), ("one hundred", 100),
                 ("一", 1), ("两", 2), ("兩", 2), ("十", 10), ("十一", 11),
                 ("二十", 20), ("九十九", 99), ("一百", 100), ("２", 2))
        for text, expected in cases:
            with self.subTest(text=text):
                self.assertEqual(parse_number_choice(text, 100), NumberChoice(expected))
        for number in range(1, 101):
            self.assertEqual(parse_number_choice(str(number), 100).number, number)

    def test_whole_request_wrappers(self):
        cases = (("number two", 2), ("Select number two please.", 2), ("please choose option 3", 3),
                 ("pick four", 4), ("go to 5", 5), ("move to number six", 6),
                 ("第二个", 2), ("请选第二个", 2), ("选择三号", 3), ("第 4 个", 4),
                 ("請選擇第兩個", 2), ("选一百号", 100))
        for text, expected in cases:
            with self.subTest(text=text):
                self.assertEqual(parse_number_choice(text, 100).number, expected)

    def test_cancellation_is_an_exact_utterance(self):
        for text in ("Cancel.", "never mind", "please stop", "cancel please", "取消", "请取消", "算了"):
            self.assertEqual(parse_number_choice(text, 3), NumberChoice(cancelled=True))

    def test_out_of_range_ambiguous_negated_and_embedded_numbers_are_rejected(self):
        invalid = ("", "zero", "0", "-1", "101", "one hundred and one", "one or two", "1 2",
                   "1,2", "1.2", "one two", "first or second", "don't choose two", "do not select 2",
                   "不要选第二个", "不是二", "If I say two", "there are two options", "go to two and click",
                   "click 2", "double click two", "two clicks", "cancel two", "stop then choose 2")
        for text in invalid:
            with self.subTest(text=text):
                self.assertEqual(parse_number_choice(text, 100), NumberChoice())
        self.assertEqual(parse_number_choice("four", 3), NumberChoice())
        self.assertEqual(parse_number_choice("两", 1), NumberChoice())

    def test_homophones_only_work_as_bare_answers(self):
        for text, number in (("to", 2), ("too", 2), ("for", 4)):
            self.assertEqual(parse_number_choice(text, 4).number, number)
        for text in ("move to", "go to", "for me", "select too", "number for"):
            self.assertEqual(parse_number_choice(text, 4), NumberChoice())
        self.assertEqual(parse_number_choice("for", 3), NumberChoice())

    def test_invalid_input_contracts(self):
        for count in (True, 0, 101, 1.5, "2"):
            with self.assertRaises(ValueError):
                parse_number_choice("one", count)
        with self.assertRaises(ValueError):
            parse_number_choice(None, 2)


if __name__ == "__main__":
    unittest.main()
