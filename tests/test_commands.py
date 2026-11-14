"""
Unit tests for ContactlessCommandParser.
"""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from stt.commands import ContactlessAction, ContactlessCommandParser


class TestContactlessCommandParser(unittest.TestCase):
    def setUp(self):
        self.parser = ContactlessCommandParser()

    def test_navigation_commands(self):
        cases = [
            ("scroll down", ContactlessAction.SCROLL_DOWN),
            ("scroll up", ContactlessAction.SCROLL_UP),
            ("please scroll down", ContactlessAction.SCROLL_DOWN),
            ("could you scroll up please", ContactlessAction.SCROLL_UP),
            ("go back", ContactlessAction.GO_BACK),
            ("previous page", ContactlessAction.GO_BACK),
            ("go home", ContactlessAction.GO_HOME),
        ]
        for phrase, expected in cases:
            res = self.parser.parse(phrase)
            self.assertEqual(res.action, expected, f"Failed for phrase: '{phrase}'")

    def test_interaction_commands(self):
        cases = [
            ("select this item", ContactlessAction.SELECT),
            ("select", ContactlessAction.SELECT),
            ("click here", ContactlessAction.CLICK),
            ("double click", ContactlessAction.DOUBLE_CLICK),
            ("zoom in", ContactlessAction.ZOOM_IN),
            ("zoom out", ContactlessAction.ZOOM_OUT),
            ("confirm and proceed", ContactlessAction.CONFIRM),
            ("cancel", ContactlessAction.CANCEL),
        ]
        for phrase, expected in cases:
            res = self.parser.parse(phrase)
            self.assertEqual(res.action, expected, f"Failed for phrase: '{phrase}'")

    def test_parameterized_dictation(self):
        res = self.parser.parse("type hello world")
        self.assertEqual(res.action, ContactlessAction.INPUT_TEXT)
        self.assertEqual(res.parameter, "hello world")

        res2 = self.parser.parse("dictate turn off lights")
        self.assertEqual(res2.action, ContactlessAction.INPUT_TEXT)
        self.assertEqual(res2.parameter, "turn off lights")

    def test_parameterized_search(self):
        res = self.parser.parse("search local AI hackathon")
        self.assertEqual(res.action, ContactlessAction.SEARCH)
        self.assertEqual(res.parameter, "local AI hackathon")

        res2 = self.parser.parse("find argmax whisperkit")
        self.assertEqual(res2.action, ContactlessAction.SEARCH)
        self.assertEqual(res2.parameter, "argmax whisperkit")

    def test_fuzzy_matching(self):
        # Small variations or missing endings
        res = self.parser.parse("scroll downward please")
        self.assertEqual(res.action, ContactlessAction.SCROLL_DOWN)

        res2 = self.parser.parse("confirm it")
        self.assertEqual(res2.action, ContactlessAction.CONFIRM)


if __name__ == "__main__":
    unittest.main()
