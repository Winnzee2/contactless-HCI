"""Local-only model transport and strict OCR target-selection boundary tests."""

import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
from control.bonsai import BonsaiClient, BonsaiError, SelectedTarget, _NoRedirect, parse_target


class Response(io.BytesIO):
    def __init__(self, value, url):
        super().__init__(value if isinstance(value, bytes) else json.dumps(value).encode())
        self.url = url

    def geturl(self):
        return self.url


class TestBonsaiClient(unittest.TestCase):
    def test_only_literal_loopback_endpoints_are_allowed(self):
        for url in ("https://example.com", "http://192.168.1.2:1234", "http://127.0.0.2:8000",
                    "http://localhost.example.com", "http://2130706433", "file:///tmp/model",
                    "http://user:secret@localhost:1234", "http://localhost/?cloud=1",
                    "http://localhost/#remote", "http://localhost/remote", "http://localhost:0",
                    "http://localhost:99999", "http:// localhost:1234"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                BonsaiClient(url, "bonsai-local")
        client = BonsaiClient("http://localhost:1234/v1/", "bonsai-local")
        self.assertEqual(client.base_url, "http://127.0.0.1:1234/v1")
        self.assertEqual(BonsaiClient("http://[::1]:1234", "local").base_url, "http://[::1]:1234/v1")

    def test_proxy_environment_is_not_used_and_redirects_are_blocked(self):
        with patch("control.bonsai.ProxyHandler") as proxy, patch("control.bonsai.build_opener"):
            BonsaiClient("http://localhost:1234", "local")
        proxy.assert_called_once_with({})
        with self.assertRaises(BonsaiError):
            _NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://remote.invalid")

    def test_valid_openai_completion_and_model_check(self):
        client = BonsaiClient("http://127.0.0.1:1234", "bonsai-local")
        captured = []
        def request(req, timeout):
            captured.append(req)
            if req.method == "GET":
                return Response({"data": [{"id": "bonsai-local"}]}, req.full_url)
            return Response({"choices": [{"finish_reason": "stop", "message": {
                "content": '{"target_id":"0","reason":"matching label"}'}}]}, req.full_url)
        with patch.object(client._opener, "open", side_effect=request):
            self.assertTrue(client.check_model())
            self.assertEqual(client.select_target("打开Codex", [{"id":"codex","label":"Codex","x":45}]), SelectedTarget("codex", "matching label"))
        payload = json.loads(captured[1].data)
        self.assertEqual(captured[0].full_url, "http://127.0.0.1:1234/v1/models")
        user_data = json.loads(payload["messages"][1]["content"])
        self.assertEqual(user_data["transcript"], "打开Codex")
        self.assertEqual(user_data["candidates"], [{"id":"0","label":"Codex"}])
        self.assertFalse(payload["stream"])
        self.assertNotIn("tools", payload)
        self.assertNotIn("x", payload)

    def test_ollama_schema_and_spoken_text_preserved(self):
        client = BonsaiClient("http://localhost:11434/api", "bonsai:8b", api="ollama")
        requests = []
        def request(req, timeout):
            requests.append(req)
            if req.method == "GET":
                return Response({"models": [{"name": "bonsai:8b"}]}, req.full_url)
            return Response({"done": True, "message": {"content": '{"target_id":null}'}}, req.full_url)
        with patch.object(client._opener, "open", side_effect=request):
            client.check_model()
            self.assertEqual(client.select_target("打开Codex", [{"id":"codex","label":"Codex"}]), SelectedTarget(None))
        payload = json.loads(requests[1].data)
        self.assertEqual(requests[0].full_url, "http://127.0.0.1:11434/api/tags")
        self.assertEqual(json.loads(payload["messages"][1]["content"])["transcript"], "打开Codex")
        self.assertIn("negated request", payload["messages"][0]["content"])
        self.assertFalse(payload["format"]["additionalProperties"])

    def test_invalid_model_output_never_supplies_coordinates_or_actions(self):
        candidates = [{"id":"codex", "label":"Codex"}]
        invalid = ["", "codex", "[]", "null", '{"target_id":"codex","x":0.5}',
                   '{"target_id":"unknown"}', '{"target_id":["codex"]}',
                   '{"target_id":"codex","reason":9}', '{"action":"click"}',
                   '{"target_id":null,"target_id":"codex"}', '{"reason":"click"}',
                   '{"target_id":"codex","reason":"' + "x" * 241 + '"}', " " * 1025]
        for value in invalid:
            with self.subTest(value=value[:80]), self.assertRaises(BonsaiError):
                parse_target(value, candidates)
        self.assertEqual(parse_target('{"target_id":"codex"}', candidates).target_id, "codex")
        self.assertIsNone(parse_target('{"target_id":null}', candidates).target_id)

    def test_failed_missing_or_malformed_server_never_falls_back(self):
        client = BonsaiClient("http://localhost:1234", "local")
        cases = [URLError("offline"), TimeoutError("timeout"),
                 HTTPError(client.base_url, 404, "Missing", None, None)]
        for error in cases:
            with patch.object(client._opener, "open", side_effect=error), self.assertRaises(BonsaiError):
                client.select_target("Codex", [{"id":"codex","label":"Codex"}])
        for value in (b"not JSON", b"x" * 65537, {"choices": []},
                      {"choices": [{"finish_reason": "length", "message": {"content": '{"action":"click"}'}}]}):
            response = Response(value, client.base_url + "/chat/completions")
            with patch.object(client._opener, "open", return_value=response), self.assertRaises(BonsaiError):
                client.select_target("Codex", [{"id":"codex","label":"Codex"}])
        with patch.object(client._opener, "open", return_value=Response({"data": []}, client.base_url + "/models")):
            with self.assertRaisesRegex(BonsaiError, "not available"):
                client.check_model()

    def test_empty_and_oversized_transcripts_do_not_contact_model(self):
        client = BonsaiClient("http://localhost:1234", "local")
        with patch.object(client._opener, "open") as open_request:
            self.assertEqual(client.select_target("   ", [{"id":"codex","label":"Codex"}]).target_id, None)
            with self.assertRaises(BonsaiError):
                client.select_target("x" * 4001, [{"id":"codex","label":"Codex"}])
            open_request.assert_not_called()

    def test_changed_response_url_rejected(self):
        client = BonsaiClient("http://localhost:1234", "local")
        with patch.object(client._opener, "open", return_value=Response({}, "https://remote.invalid")):
            with self.assertRaises(BonsaiError):
                client.select_target("Codex", [{"id":"codex","label":"Codex"}])


if __name__ == "__main__":
    unittest.main()
