"""Provisioning must not report success for missing or truncated assets."""

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_engine import ROOT, STTConfig

spec = importlib.util.spec_from_file_location("setup_models", ROOT / "scripts/setup_models.py")
setup_models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup_models)


class TestModelSetup(unittest.TestCase):
    def test_multilingual_setup_and_auto_language_are_selectable(self):
        with patch.object(setup_models, "setup") as setup, \
             patch("sys.argv", ["setup_models.py", "--model", "base", "--language", "auto"]), \
             patch("builtins.print"):
            self.assertEqual(setup_models.main(), 0)
        setup.assert_called_once_with("base", language="auto")

    def test_all_preserves_the_two_english_variants(self):
        with patch.object(setup_models, "setup") as setup, \
             patch("sys.argv", ["setup_models.py", "--model", "all"]), patch("builtins.print"):
            self.assertEqual(setup_models.main(), 0)
        self.assertEqual([call.args[0] for call in setup.call_args_list], ["tiny.en", "base.en"])

    def test_truncated_download_preserves_existing_file(self):
        response = io.BytesIO(b"partial")
        response.headers = {"Content-Length": "1000"}
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "model.bin"
            destination.write_bytes(b"original")
            with patch.object(setup_models, "urlopen", return_value=response):
                with self.assertRaisesRegex(RuntimeError, "Incomplete download"):
                    setup_models.download("https://example.invalid/model", destination)
            self.assertEqual(destination.read_bytes(), b"original")
            self.assertFalse(destination.with_name("model.bin.part").exists())

    def test_fresh_setup_downloads_models_and_tokenizer_before_smoke_test(self):
        with tempfile.TemporaryDirectory() as folder:
            config = STTConfig(models_dir=Path(folder), cli_binary="/usr/bin/true")
            prefix = config.model_name + "/"
            names = [prefix + model + ".mlmodelc/" + asset
                     for model in ("AudioEncoder", "TextDecoder", "MelSpectrogram")
                     for asset in ("model.mil", "coremldata.bin", "weights/weight.bin")]
            manifest = {"sha": "fixed-model-revision", "siblings": [{"rfilename": name} for name in names]}
            responses = [io.BytesIO(json.dumps(manifest).encode()),
                         io.BytesIO(b'{"sha": "fixed-tokenizer-revision"}')]
            urls = []
            def download(url, destination):
                urls.append(url)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(b"{}" if destination.suffix == ".json" else b"model")
            def smoke(config):
                self.assertTrue(config.is_model_available())
                self.assertTrue(config.is_tokenizer_available())
                from types import SimpleNamespace
                return SimpleNamespace(transcribe=lambda _: SimpleNamespace(text="Select this item."))
            with patch.object(setup_models, "STTConfig", return_value=config), \
                 patch.object(setup_models, "urlopen", side_effect=responses), \
                 patch.object(setup_models, "download", side_effect=download), \
                 patch.object(setup_models, "WhisperKitEngine", side_effect=smoke), \
                 patch("builtins.print"):
                setup_models.setup("tiny.en")
            self.assertEqual(len(urls), 12)
            self.assertIn("/resolve/fixed-model-revision/", urls[0])
            self.assertIn("/resolve/fixed-tokenizer-revision/", urls[-1])

    def test_download_failure_returns_nonzero(self):
        with patch.object(setup_models, "setup", side_effect=OSError("offline")), \
             patch("sys.argv", ["setup_models.py"]), patch("builtins.print") as output:
            self.assertEqual(setup_models.main(), 1)
        self.assertFalse(any("Setup complete" in str(call) for call in output.call_args_list))
