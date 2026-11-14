#!/usr/bin/env python3
"""Serve installed Bonsai MLX weights over a loopback-only OpenAI-style API.

Launch through start_bonsai.sh to deny outbound networking at the OS boundary.
The model loads once; requests execute serially on the MLX-owning thread.
"""

import argparse
import json
import os
from pathlib import Path
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from uuid import uuid4

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

MODEL_ID = "bonsai-local"
MAX_BODY_BYTES = 65536


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--port", type=int, default=1234)
    args = parser.parse_args()
    model_path = args.model_path.expanduser().resolve()
    for name in ("config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors", "hadamard.json"):
        if not (model_path / name).is_file():
            parser.error(f"Missing local Bonsai asset: {model_path / name}")
    if not 1024 <= args.port <= 65535:
        parser.error("port must be between 1024 and 65535")

    # Import only after offline environment variables are installed.
    from mlx_vlm import generate, load
    from mlx_vlm.prompt_utils import apply_chat_template
    print(f"Loading Bonsai from {model_path}", file=sys.stderr, flush=True)
    model, processor = load(str(model_path))

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(30)

        def send_json(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/v1/models":
                self.send_json(200, {"object": "list", "data": [
                    {"id": MODEL_ID, "object": "model", "owned_by": "local"}
                ]})
            elif self.path == "/health":
                self.send_json(200, {"status": "ready", "model": MODEL_ID, "offline": True})
            else:
                self.send_json(404, {"error": "Unknown endpoint"})

        def do_POST(self):
            if self.path != "/v1/chat/completions":
                self.send_json(404, {"error": "Unknown endpoint"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY_BYTES:
                    raise ValueError("Request body must be 1–65536 bytes")
                request = json.loads(self.rfile.read(length))
                if request.get("model") != MODEL_ID:
                    raise ValueError(f"Only installed model {MODEL_ID!r} is available")
                if request.get("stream", False):
                    raise ValueError("Streaming is not supported; use stream=false")
                messages = request.get("messages")
                if not isinstance(messages, list) or not 1 <= len(messages) <= 20:
                    raise ValueError("messages must contain 1–20 text messages")
                for message in messages:
                    if (not isinstance(message, dict)
                            or message.get("role") not in ("system", "user", "assistant")
                            or not isinstance(message.get("content"), str)):
                        raise ValueError("Only text messages with valid roles are accepted")
                max_tokens = request.get("max_tokens", 128)
                if type(max_tokens) is not int or not 1 <= max_tokens <= 512:
                    raise ValueError("max_tokens must be an integer between 1 and 512")
                # This service does not execute tools, shell code, or model output.
                prompt = apply_chat_template(processor, model.config, messages,
                                             num_images=0, enable_thinking=False)
                result = generate(model, processor, prompt, max_tokens=max_tokens,
                                  temperature=0.0, verbose=False)
                self.send_json(200, {
                    "id": "chatcmpl-" + uuid4().hex,
                    "object": "chat.completion", "created": int(time.time()),
                    "model": MODEL_ID,
                    "choices": [{"index": 0, "message": {
                        "role": "assistant", "content": result.text,
                    }, "finish_reason": "stop"}],
                })
            except (ValueError, TypeError, json.JSONDecodeError) as error:
                self.send_json(400, {"error": str(error)})
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                print(f"Bonsai inference failed: {error}", file=sys.stderr, flush=True)
                self.send_json(500, {"error": "Local model inference failed; see server log"})

        def log_message(self, format, *args):
            print("Bonsai: " + (format % args), file=sys.stderr, flush=True)

    # Only loopback is accepted; no argument exposes the server to a LAN.
    with HTTPServer(("127.0.0.1", args.port), Handler) as server:
        print(f"Bonsai ready: http://127.0.0.1:{args.port}/v1 (model: {MODEL_ID})",
              file=sys.stderr, flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
