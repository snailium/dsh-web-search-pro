#!/usr/bin/env python3
"""Scripted OpenAI-compatible mock for dsh compatibility runs.

Serves just enough for a dsh instance to boot and run one tool call:

    python3 test/compat/mock-llm.py <port> [tool] [args-json]

Turn 1 asks the agent to call `tool` with `args-json`; once the tool result comes
back it echoes that result as the final assistant message. That makes the whole
trajectory observable in `dsh --json` output, so a compat script can assert both
that the plugin loaded AND that its tool actually ran.

Two shapes are supported because clients differ: a single JSON body, and the SSE
stream the provider protocol expects (`data:` chunks ending in `finish_reason`
and `[DONE]`). Without the streaming shape a real run dies with
"TRANSPORT: Stream ended without finish_reason".

With no tool argument the mock replies with plain text and calls nothing, which
is enough to prove an instance boots.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "mock-model"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):  # keep the compat log readable
        pass

    def _send(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self, events):
        body = "".join(f"data: {json.dumps(event)}\n\n" for event in events) + "data: [DONE]\n\n"
        payload = body.encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path.endswith("/models"):
            self._send({"object": "list", "data": [{"id": MODEL, "object": "model"}]})
        else:
            self._send({"error": {"message": f"no route {self.path}"}}, 404)

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("content-length") or 0)
        try:
            request = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            request = {}
        stream = request.get("stream") is True

        # A tool result already came back: echo it so the run terminates.
        results = [m for m in request.get("messages", []) if m.get("role") == "tool"]
        if results:
            return self._text(str(results[-1].get("content") or ""), stream)

        if TOOL is None:
            return self._text("compat run complete", stream)
        return self._tool_call(stream)

    def _text(self, text, stream):
        if not stream:
            return self._send({
                "id": "mock-completion", "object": "chat.completion", "model": MODEL,
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": text}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })
        self._sse([
            {"id": "mock-chunk", "object": "chat.completion.chunk", "model": MODEL,
             "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}}]},
            {"id": "mock-chunk", "object": "chat.completion.chunk", "model": MODEL,
             "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
             "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}},
        ])

    def _tool_call(self, stream):
        call = {"id": "call_1", "type": "function",
                "function": {"name": TOOL, "arguments": ARGS}}
        if not stream:
            return self._send({
                "id": "mock-completion", "object": "chat.completion", "model": MODEL,
                "choices": [{"index": 0, "finish_reason": "tool_calls",
                             "message": {"role": "assistant", "content": None, "tool_calls": [call]}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })
        self._sse([
            {"id": "mock-chunk", "object": "chat.completion.chunk", "model": MODEL,
             "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]}}]},
            {"id": "mock-chunk", "object": "chat.completion.chunk", "model": MODEL,
             "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
             "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}},
        ])


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18997
    TOOL = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
    ARGS = sys.argv[3] if len(sys.argv) > 3 else "{}"
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
