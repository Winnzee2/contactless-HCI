"""The local model may select known text IDs, never invent input actions."""

from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from control.bonsai import BonsaiClient, BonsaiError, SelectedTarget, normalize_candidates, parse_target


class TestTargetSelection(unittest.TestCase):
    def test_duplicate_matching_labels_are_ambiguous_even_if_model_picks_one(self):
        options = [{"id":"a","label":"Codex"}, {"id":"b","label":"CODEX"}]
        self.assertIsNone(parse_target('{"target_id":"a"}', options).target_id)

    def test_only_id_and_label_cross_model_boundary(self):
        options = [{"id":"a","label":" Codex ","x":100,"y":200,"screenshot":"private"}]
        self.assertEqual(normalize_candidates(options), [{"id":"a","label":"Codex"}])

    def test_invalid_candidates_fail_before_network(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        invalid = [None, [{"id":"a","label":""}], [{"id":"a","label":"A"},{"id":"a","label":"B"}],
                   [{"id":1,"label":"A"}], [{"id":"a","label":5}]]
        with patch.object(client, '_request') as request:
            for options in invalid:
                with self.subTest(options=options), self.assertRaises(ValueError):
                    client.select_target('Codex', options)
            request.assert_not_called()

    def test_explicit_hypothetical_speech_is_not_sent_for_selection(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        options = [{"id":"a","label":"Codex"}]
        with patch.object(client, '_request') as request:
            for text in ("If I say open Codex, what happens?", "如果我说打开Codex会怎么样"):
                self.assertIsNone(client.select_target(text, options).target_id)
            request.assert_not_called()

    def test_no_candidates_does_not_call_model(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        with patch.object(client, '_request') as request:
            self.assertIsNone(client.select_target('Codex', []).target_id)
            request.assert_not_called()


if __name__ == '__main__':
    unittest.main()
