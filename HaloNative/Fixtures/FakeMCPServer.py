#!/usr/bin/env python3
"""A tiny MCP server for offline checks. Standard library only.

stdio (default): newline-delimited JSON-RPC on stdin/stdout.
--http PORT:      Streamable HTTP on 127.0.0.1; tools/list answers as SSE,
                  requires `Authorization: Bearer good` (401 otherwise), and
                  forgets the session once after the first tools/call (404).
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOOLS = [
    {"name": "echo", "description": "Echo text back.", "annotations": {"readOnlyHint": True},
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "send_note", "description": "Pretend to send a note.",
     "inputSchema": {"type": "object", "properties": {"to": {"type": "string"}, "body": {"type": "string"}}, "required": ["to", "body"]}},
]
SENT = []


def handle(message):
    method, mid = message.get("method"), message.get("id")
    if mid is None:
        return None
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
    elif method == "tools/list":
        if message.get("params", {}).get("cursor") == "2":
            result = {"tools": TOOLS[1:]}
        else:
            result = {"tools": TOOLS[:1], "nextCursor": "2"}
    elif method == "tools/call":
        name = message["params"]["name"]
        args = message["params"].get("arguments", {})
        if name == "echo":
            result = {"content": [{"type": "text", "text": args.get("text", "")}, {"type": "image", "data": "", "mimeType": "image/png"}]}
        elif name == "send_note":
            SENT.append(args)
            result = {"content": [{"type": "text", "text": "sent to " + args.get("to", "") + " (" + str(len(SENT)) + ")"}]}
        else:
            result = {"content": [{"type": "text", "text": "no such tool"}], "isError": True}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown method"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def stdio():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        reply = handle(json.loads(line))
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


class Handler(BaseHTTPRequestHandler):
    session = "s1"
    expired_once = False

    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.headers.get("Authorization") != "Bearer good":
            self.send_response(401); self.end_headers(); return
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        sent_session = self.headers.get("Mcp-Session-Id")
        if message.get("method") != "initialize" and sent_session != Handler.session:
            self.send_response(404); self.end_headers(); return
        reply = handle(message)
        if reply is None:
            self.send_response(202); self.end_headers(); return
        if message.get("method") == "initialize":
            if Handler.expired_once:
                Handler.session = "s2"
            self.send_response(200)
            self.send_header("Mcp-Session-Id", Handler.session)
            self.send_header("Content-Type", "application/json")
            body = json.dumps(reply).encode()
        elif message.get("method") == "tools/list":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            note = json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "x"}})
            body = (": keepalive\n\ndata: " + note + "\n\nevent: message\ndata: " + json.dumps(reply) + "\n\n").encode()
        else:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            body = json.dumps(reply).encode()
            if message.get("method") == "tools/call" and not Handler.expired_once:
                Handler.expired_once = True
                Handler.session = "gone"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        self.send_response(200); self.end_headers()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--http":
        HTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
    else:
        stdio()
