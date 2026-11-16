# /**
#  * Copyright Jerily LTD. All Rights Reserved.
#  * SPDX-FileCopyrightText: 2026 Neofytos Dimitriou (neo@jerily.cy)
#  * SPDX-License-Identifier: MIT.
#  */

"""Offline HTTP fixtures. A release endpoint gates streams without timing sleeps."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

release = threading.Event()


def sse(value, name=None):
    prefix = f"event: {name}\r\n" if name else ""
    payload = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return (prefix + "data: " + payload + "\r\n\r\n").encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, body, content_type="application/json", status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/release":
            release.set()
            self.send(b"{}")
            return
        if self.path == "/gate":
            release.clear()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"3\r\none\r\n")
            self.wfile.flush()
            if release.wait(10):
                self.wfile.write(b"3\r\ntwo\r\n0\r\n\r\n")
                self.wfile.flush()
            self.close_connection = True
            return
        request = json.loads(body)
        mode = request.get("input", request.get("test_case", "ok"))
        if mode == "http_error":
            self.send(b'{"error":{"message":"rate limited"}}', status=429)
            return
        if mode == "echo":
            if "metadata" in request and "a" in request["metadata"]:
                request["null_preserved"] = request["metadata"]["a"] is None
            self.send(json.dumps(request).encode())
            return
        if self.path.endswith("/chat/completions"):
            message = {"role": "assistant", "content": "Hello 🌍"}
            usage = {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5}
            if not request.get("stream"):
                self.send(json.dumps({"choices": [{"index": 0, "message": message,
                    "finish_reason": "stop"}], "usage": usage}).encode())
                return
            def chunk(choices):
                return {"id": "chat_test", "model": "test-model", "choices": choices}
            frames = [chunk([{"index": 0, "delta": {"role": "assistant", "content": "Hello "}}]),
                      chunk([{"index": 0, "delta": {"content": "🌍"}},
                             {"index": 1, "delta": {"content": "Second"}}])]
            if mode == "tools":
                frames += [chunk([{"index": 0, "delta": {"tool_calls": [
                    {"index": 0, "id": "call_a", "type": "function", "function": {"name": "first", "arguments": '{"x":'}},
                    {"index": 1, "id": "call_b", "type": "function", "function": {"name": "second", "arguments": '{"y":'}}]}}]),
                    chunk([{"index": 0, "delta": {"tool_calls": [
                    {"index": 1, "function": {"arguments": "2}"}},
                    {"index": 0, "function": {"arguments": "1}"}}]}}])]
            frames.append(chunk([{"index": 0, "delta": {}, "finish_reason": "stop"},
                                 {"index": 1, "delta": {}, "finish_reason": "length"}]))
            frames.append(dict(chunk([]), usage=usage))
            payload = b"".join(sse(x) for x in frames)
            if mode != "truncated":
                payload += sse("[DONE]")
            self.send(payload, "text/event-stream")
            return
        response = {"id": "resp_test", "status": "completed", "output": [
            {"type": "message", "content": [{"type": "output_text", "text": "Hello 🌍"}]}],
            "usage": {"input_tokens": 2, "output_tokens": 3, "total_tokens": 5}}
        if not request.get("stream") or mode == "wrong_type":
            self.send(json.dumps(response).encode())
            return
        if mode == "invalid_json":
            self.send(sse("{oops"), "text/event-stream")
            return
        if mode == "failed":
            self.send(sse({"type": "response.failed", "response": {"error": {"message": "failed fixture"}}}), "text/event-stream")
            return
        if mode == "incomplete":
            self.send(sse({"type": "response.incomplete", "response": {"incomplete_details": {"reason": "max_output_tokens"}}}), "text/event-stream")
            return
        frames = [sse({"type": "response.output_text.delta", "delta": "Hello "}),
                  sse({"type": "response.output_text.delta", "delta": "🌍"})]
        if mode != "truncated":
            frames.append(sse({"type": "response.completed", "response": response}))
        self.send(b"".join(frames), "text/event-stream; charset=utf-8")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
sys.stdin.read()
release.set()
server.shutdown()
server.server_close()
