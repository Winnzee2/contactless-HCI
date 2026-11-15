"""The local model may select known text IDs, never invent input actions."""

from pathlib import Path
import json
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from control.bonsai import BonsaiClient, BonsaiError, SelectedTarget, normalize_candidates, parse_target


class TestTargetSelection(unittest.TestCase):
    def choose_label(self, text, labels, chosen_label):
        """Simulate a model choice; exercise the real transport/ID validation path."""
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        options = [{"id": f"native-{index}", "label": label}
                   for index, label in enumerate(labels)]
        def reply(route, payload):
            data = json.loads(payload['messages'][1]['content'])
            self.assertTrue(all(item['label'] in labels for item in data['candidates']))
            chosen = next(item['id'] for item in data['candidates'] if item['label'] == chosen_label)
            return {"choices": [{"message": {"content": json.dumps({"target_id": chosen})}}]}
        with patch.object(client, '_request', side_effect=reply):
            return client.select_target(text, options).target_id

    def test_minor_errors_and_natural_requests(self):
        for phrase in ("Could you take me to the Codex tab please", "open Codxe", "find Codx", "帮我找一下Codex"):
            with self.subTest(phrase=phrase):
                self.assertEqual(self.choose_label(phrase, ["Codex", "Safari"], "Codex"), "native-0")

    def test_fuzzy_competing_names_are_numbered(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        with patch.object(client, '_request', return_value={"choices": [{"message": {"content": '{"target_id":"0"}'}}]}):
            result = client.select_target("open Codex", [{"id":"a","label":"Coder"}, {"id":"b","label":"Codec"}])
        self.assertIsNone(result.target_id)
        self.assertEqual(set(result.candidate_ids), {"a", "b"})

    def test_duplicate_matching_labels_are_ambiguous_even_if_model_picks_one(self):
        options = [{"id":"a","label":"Codex"}, {"id":"b","label":"CODEX"}]
        self.assertIsNone(parse_target('{"target_id":"a"}', options).target_id)

    def test_duplicate_labels_ignore_punctuation_width_and_conjunction_spelling(self):
        for labels in (("Save As…", "SAVE AS"), ("Ｄｏｗｎｌｏａｄｓ", "Downloads"),
                       ("Privacy & Security", "Privacy and Security"), ("下载 Downloads", "下载Downloads")):
            with self.subTest(labels=labels):
                options = [{"id": str(index), "label": label} for index, label in enumerate(labels)]
                self.assertIsNone(parse_target('{"target_id":"0"}', options).target_id)

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
            self.assertEqual(data['candidates'], [{'id':'0', 'label':'Finder'}])
            return {"choices":[{"finish_reason":"stop","message":{"content":'{"target_id":"0"}'}}]}
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

    def test_unrelated_conversation_is_vetoed_and_request_wrappers_are_supported(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        response = {"choices":[{"message":{"content":'{"target_id":"0"}'}}]}
        with patch.object(client, '_request', return_value=response):
            self.assertIsNone(client.select_target('My hand', [{"id":"title","label":"Jarvis · Hand + Voice"}]).target_id)
            self.assertEqual(client.select_target('打开Codex那个标签', [{"id":"a","label":"Codex"}]).target_id, 'a')
            self.assertEqual(client.select_target('open the Safari tab', [{"id":"b","label":"Safari"}]).target_id, 'b')
            self.assertIsNone(client.select_target('cat', [{"id":"b","label":"category"}]).target_id)

    def test_real_interface_names_allow_request_wrappers_and_label_metadata(self):
        cases = (
            ("Could you please click the Save As… button?", "Save As…"),
            ("open Downloads", "Downloads — 12 items"),
            ("click Privacy", "Privacy & Security"),
            ("click Privacy and Security", "Privacy & Security"),
            ("open Extensions", "Extensions (4 installed)"),
            ("open the New Tab", "New Tab"),
            ("New Tab", "New Tab — Start browsing"),
            ("go back", "Back"),
            ("click the Search button", "Search (⌘F)"),
            ("please click Close", "Close current tab"),
            ("move the pointer to Search", "Search"),
            ("Save As", "Save As… ⇧⌘S"),
            ("go to Résumé", "Résumé — Updated yesterday"),
            ("帮我打开Downloads那个标签", "Downloads — 12 items"),
            ("请点击隐私与安全", "隐私与安全"),
            ("点击下载 Downloads 文件夹", "下载 Downloads — 12 项"),
            ("click 隐私与安全 button", "隐私与安全"),
            ("open 下载", "下载 — 12 项"),
        )
        for text, label in cases:
            with self.subTest(text=text, label=label):
                self.assertEqual(self.choose_label(text, [label, "Unrelated help documentation"], label), 'native-0')

    def test_conversation_questions_compound_actions_and_substrings_are_vetoed(self):
        cases = (
            ("I talked about Privacy yesterday", "Privacy & Security"),
            ("I like Save As", "Save As…"),
            ("How do I open Downloads?", "Downloads — 12 items"),
            ("Can you tell me whether Extensions are safe?", "Extensions"),
            ("open Downloads then click Help", "Downloads — 12 items"),
            ("open Downloads and Extensions", "Downloads — 12 items"),
            ("click Privacy and then close the window", "Privacy & Security"),
            ("我们刚刚聊到Downloads", "Downloads — 12 items"),
            ("如果打开Downloads会怎样", "Downloads — 12 items"),
            ("click cat", "catégorie"),
            ("click Search", "Research"),
            ("Save", "Don't Save"),
            ("go back", "Forward"),
        )
        for text, label in cases:
            with self.subTest(text=text, label=label):
                self.assertIsNone(self.choose_label(text, [label], label))

    def test_short_names_shared_by_multiple_controls_are_ambiguous(self):
        for text, labels in (
            ("open Downloads", ["Downloads — 12 items", "Downloads — 3 items"]),
            ("click Privacy", ["Privacy & Security", "Privacy settings"]),
            ("click Close", ["Close current tab", "Close window"]),
            ("打开下载", ["下载文件", "下载记录"]),
        ):
            with self.subTest(text=text):
                self.assertIsNone(self.choose_label(text, labels, labels[0]))

    def test_full_requested_names_take_priority_over_partial_names(self):
        cases = (
            ("click Save As", ["Save", "Save As…", "Save As Template"], "Save As…"),
            ("open Downloads", ["Downloads — 12 items", "Downloads"], "Downloads"),
            ("click Privacy", ["Privacy & Security", "Privacy"], "Privacy"),
            ("open the New Tab", ["New Window", "New Tab — Start browsing"], "New Tab — Start browsing"),
            ("open the New Tab", ["New", "New Tab — Start browsing"], "New Tab — Start browsing"),
            ("click Search button", ["Search", "Search button — Find in this page"], "Search button — Find in this page"),
            ("打开下载标签", ["下载", "下载标签 — 12 项"], "下载标签 — 12 项"),
            ("Open File", ["File", "Open File"], "Open File"),
        )
        for text, labels, intended in cases:
            with self.subTest(text=text):
                self.assertEqual(self.choose_label(text, labels, intended), f'native-{labels.index(intended)}')

    def test_a_model_cannot_choose_a_removed_unrelated_label(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        options = [{"id": "native-0", "label": "Codex"}, {"id": "native-1", "label": "Finder"}]
        def reply(route, payload):
            data = json.loads(payload['messages'][1]['content'])
            self.assertEqual(data['candidates'], [{"id": "0", "label": "Finder"}])
            return {"choices": [{"message": {"content": '{"target_id":"1"}'}}]}
        with patch.object(client, '_request', side_effect=reply), self.assertRaises(BonsaiError):
            client.select_target('finder', options)

    def test_model_null_is_never_replaced_with_a_local_matching_target(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        response = {"choices": [{"message": {"content": '{"target_id":null}'}}]}
        with patch.object(client, '_request', return_value=response) as request:
            self.assertIsNone(client.select_target('open Downloads', [
                {"id": "downloads", "label": "Downloads — 12 items"}]).target_id)
            request.assert_called_once()

    def test_ambiguity_requires_valid_model_output_and_returns_all_original_ids(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        options = [{"id": "left", "label": "Save"}, {"id": "right", "label": "SAVE"},
                   {"id": "other", "label": "Some unrelated prose"}]
        for content in ('{"target_id":"0"}', '{"target_id":"1"}', '{"target_id":null}'):
            response = {"choices": [{"message": {"content": content}}]}
            with self.subTest(content=content), patch.object(client, '_request', return_value=response):
                selected = client.select_target('Save', options)
                self.assertIsNone(selected.target_id)
                self.assertEqual(selected.candidate_ids, ("left", "right"))
        for content in ('{"target_id":"9"}', '{"target_id":0}', '{"target_id":null,"candidate_ids":["left"]}',
                        '{"target_id":"0","action":"click"}', 'not JSON'):
            response = {"choices": [{"message": {"content": content}}]}
            with self.subTest(content=content), patch.object(client, '_request', return_value=response), self.assertRaises(BonsaiError):
                client.select_target('Save', options)

    def test_ambiguity_cannot_include_a_selected_target_or_invalid_ids(self):
        for target, candidate_ids in (("left", ("left", "right")), (None, ("left",)),
                                      (None, ("left", "left")), (None, ("left", 2)),
                                      (None, ["left", "right"])):
            with self.subTest(target=target, candidate_ids=candidate_ids), self.assertRaises(ValueError):
                SelectedTarget(target, candidate_ids=candidate_ids)

    def test_only_supported_names_are_presented_without_rewriting_labels(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        cases = (("格式", "格式"), ("open Downloads", "Downloads — 12 items"),
                 ("Codex", "1 Codex"), ("go to Safari", "2 Safari"),
                 ("move to Finder", "3 Finder"))
        for transcript, label in cases:
            options = [{"id": f"word-{index}", "label": word}
                       for index, word in enumerate(["a", "is", "the", "or", "Some document prose"])]
            options.append({"id": "actual-control", "label": label})
            def reply(route, payload):
                data = json.loads(payload['messages'][1]['content'])
                self.assertEqual(data['candidates'], [{"id": "0", "label": label}])
                self.assertEqual(data['transcript'], transcript)
                return {"choices": [{"message": {"content": '{"target_id":null}'}}]}
            with self.subTest(transcript=transcript), patch.object(client, '_request', side_effect=reply) as request:
                self.assertIsNone(client.select_target(transcript, options).target_id)
                request.assert_called_once()

    def test_all_ambiguous_matches_are_preserved_for_the_model(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        for labels in (("Save", "SAVE"), ("1 Reports", "2 Reports"),
                       ("Downloads — 12 items", "Downloads — 3 items")):
            name = "Save" if labels[0] == "Save" else "Reports" if "Reports" in labels[0] else "Downloads"
            options = [{"id": f"target-{index}", "label": label} for index, label in enumerate(labels)]
            options.append({"id": "unrelated", "label": "Some unrelated prose"})
            def reply(route, payload):
                data = json.loads(payload['messages'][1]['content'])
                self.assertCountEqual([item['label'] for item in data['candidates']], labels)
                self.assertEqual(len({item['id'] for item in data['candidates']}), len(labels))
                return {"choices": [{"message": {"content": '{"target_id":"0"}'}}]}
            with self.subTest(labels=labels), patch.object(client, '_request', side_effect=reply) as request:
                self.assertIsNone(client.select_target(name, options).target_id)
                request.assert_called_once()

    def test_no_named_candidate_abstains_without_model_inference(self):
        client = BonsaiClient('http://127.0.0.1:1234', 'bonsai-local')
        options = [{"id": "a", "label": "Jarvis · Hand + Voice"},
                   {"id": "b", "label": "1 Codex"}]
        with patch.object(client, '_request') as request:
            for transcript in ("My hand", "go to Missing", "I talked about Codex yesterday"):
                self.assertIsNone(client.select_target(transcript, options).target_id)
            request.assert_not_called()


if __name__ == '__main__':
    unittest.main()
