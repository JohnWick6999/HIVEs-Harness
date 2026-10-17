#!/usr/bin/env python3
"""HiveHarnessCore 测试用假 MCP 服务器:JSON-RPC 2.0 over stdio。"""
import json
import sys


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    mid = msg.get("id")
    method = msg.get("method", "")

    if method == "initialize":
        send({
            "jsonrpc": "2.0", "id": mid,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "fake-server", "version": "1.0"},
            },
        })
    elif method == "tools/list":
        send({
            "jsonrpc": "2.0", "id": mid,
            "result": {
                "tools": [
                    {"name": "echo", "description": "Echo text back",
                     "inputSchema": {"type": "object",
                                     "properties": {"text": {"type": "string"}}}},
                    {"name": "add", "description": "Add two numbers",
                     "inputSchema": {"type": "object",
                                     "properties": {"a": {"type": "number"},
                                                    "b": {"type": "number"}}}},
                ]
            },
        })
    elif method == "tools/call":
        params = msg.get("params", {})
        name = params.get("name", "")
        args = params.get("arguments", {})
        if name == "echo":
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"content": [{"type": "text", "text": "echo:" + str(args.get("text", ""))}],
                             "isError": False}})
        elif name == "add":
            a = args.get("a", 0)
            b = args.get("b", 0)
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"content": [{"type": "text", "text": str(a + b)}],
                             "isError": False}})
        else:
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"content": [{"type": "text", "text": "unknown tool"}],
                             "isError": True}})
    elif method == "notifications/initialized":
        pass  # 通知无响应
