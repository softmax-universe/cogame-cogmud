#!/usr/bin/env python3
"""Deterministic local Anthropic /v1/messages fixture for Cogmud CI and local cert."""

import argparse
import json
import re
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def choose_sentence(user_prompt: str) -> str:
    match = re.search(r"Exits lead to ([^.\n]+)\.", user_prompt)
    if match:
        first_exit = match.group(1).split(" and ")[0].strip()
        if first_exit:
            return f"I walk to {first_exit}."
    return "I wait by the well and listen."


class FixtureServer(ThreadingHTTPServer):
    def __init__(self, address, handler, *, log_file: Path | None):
        super().__init__(address, handler)
        self.log_file = log_file
        self.lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/healthz":
            body = b'{"ok": true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw)
        user = body["messages"][0]["content"]
        turn_match = re.match(r"Turn (\d+) of", user)
        turn = int(turn_match.group(1)) if turn_match else 0
        slot_header = self.headers.get("X-Coworld-Player-Slot", "")
        sentence = choose_sentence(user)
        action = {"action": sentence, "say": "", "notes": ""}
        response = json.dumps(
            {
                "model": body.get("model", "cogmud-local-fixture"),
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": json.dumps(action)}],
                "usage": {"input_tokens": 50, "output_tokens": 15},
            }
        ).encode("utf-8")
        if self.server.log_file is not None:
            record = {
                "path": self.path,
                "turn": turn,
                "slot": int(slot_header) if slot_header.isdigit() else slot_header,
                "sentence": sentence,
            }
            with self.server.lock:
                with self.server.log_file.open("a", encoding="utf-8") as fh:
                    fh.write(json.dumps(record) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header(
            "X-Softmax-Llm-Call-Id",
            str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode("utf-8"))),
        )
        self.end_headers()
        self.wfile.write(response)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", type=Path, default=None)
    parser.add_argument("--log-file", type=Path, default=None)
    args = parser.parse_args()

    server = FixtureServer((args.host, args.port), Handler, log_file=args.log_file)
    if args.port_file is not None:
        args.port_file.write_text(str(server.server_port), encoding="utf-8")
    print(f"cogmud llm_fixture listening on {args.host}:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
