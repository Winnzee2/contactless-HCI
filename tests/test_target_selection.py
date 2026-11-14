"""The local model may select known text IDs, never invent input actions."""

from pathlib import Path
import json
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

    def test_request_local_aliases_map_only_the_model_choice_back_to_native_id(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        options = [{"id":"target-41","label":"A long instruction near the buttons"},
                   {"id":"target-12","label":"Finder"}, {"id":"target-6","label":"Codex"}]
        def reply(route, payload):
            data = json.loads(payload['messages'][1]['content'])
            self.assertEqual(data['transcript'], 'Finder')
            self.assertEqual([o['label'] for o in data['candidates']], ['Codex','Finder','A long instruction near the buttons'])
            self.assertEqual([o['id'] for o in data['candidates']], ['0','1','2'])
            return {"choices":[{"finish_reason":"stop","message":{"content":'{"target_id":"1"}'}}]}
        with patch.object(client, '_request', side_effect=reply):
            self.assertEqual(client.select_target('finder.', options).target_id, 'target-12')

    def test_unknown_or_non_string_alias_and_extra_actions_remain_rejected(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        for content in ('{"target_id":"target-6"}', '{"target_id":0}', '{"target_id":"9"}',
                        '{"target_id":"0","action":"click"}', '{"target_id":"0","x":1}',
                        '{"target_id":"0"}\n</think>\n{"target_id":"0"}'):
            response = {"choices":[{"message":{"content":content}}]}
            with self.subTest(content=content), patch.object(client, '_request', return_value=response) as request:
                with self.assertRaises(BonsaiError):
                    client.select_target('Codex', [{"id":"target-6","label":"Codex"}])
                request.assert_called_once()

    def test_negation_is_vetoed_before_model_inference(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        with patch.object(client, '_request') as request:
            for text in ("Don't open Codex", "Do not go to Codex", "不要打开Codex", "别点击Codex"):
                self.assertIsNone(client.select_target(text, [{"id":"a","label":"Codex"}]).target_id)
            request.assert_not_called()

    def test_unrelated_conversation_and_wrong_exact_label_are_vetoed(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        response = {"choices":[{"message":{"content":'{"target_id":"0"}'}}]}
        with patch.object(client, '_request', return_value=response):
            self.assertIsNone(client.select_target('My hand', [{"id":"title","label":"Local Control · Hand + Voice"}]).target_id)
            self.assertIsNone(client.select_target('finder', [{"id":"a","label":"Codex"},{"id":"b","label":"Finder"}]).target_id)
            self.assertEqual(client.select_target('打开Codex那个标签', [{"id":"a","label":"Codex"}]).target_id, 'a')
            self.assertEqual(client.select_target('open the Safari tab', [{"id":"b","label":"Safari"}]).target_id, 'b')
            self.assertIsNone(client.select_target('cat', [{"id":"b","label":"category"}]).target_id)


if __name__ == '__main__':
    unittest.main()
