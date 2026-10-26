#!/usr/bin/env python3
"""codeMUTATOR MCP server (stdio JSON-RPC).

Exposes the mutation-testing service to MCP clients:
  submit_run(source_path, scope_filter?, mutant_limit?, run_budget_ms?)
  get_run(run_id)
  list_outcomes(run_id, status?)
  cancel_run(run_id)

Config example (client-dependent):
  { "command": "/abs/path/bin/codemutator_mcp.py",
    "env": { "CODEMUTATOR_URL": "http://localhost:4300" } }
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("CODEMUTATOR_URL", "http://localhost:4300").rstrip("/")

TOOLS = [
    {
        "name": "submit_run",
        "description": "Submit a local codebase for mutation testing. Returns the run envelope "
                       "(id, state, outcomes_url). Poll get_run until terminal=true. The submitted "
                       "directory is never written; work happens on service-side copies.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "source_path": {"type": "string", "description": "absolute path to the project"},
                "scope_filter": {"type": "string", "description": "path prefix to mutate, e.g. 'src/'"},
                "mutant_limit": {"type": "integer", "description": "bounded sample size"},
                "run_budget_ms": {"type": "integer", "description": "dispatch deadline (default 60min)"},
            },
            "required": ["source_path"],
        },
    },
    {
        "name": "get_run",
        "description": "Run status: state, killed/survived/invalid counts, score, terminal flag.",
        "inputSchema": {
            "type": "object",
            "properties": {"run_id": {"type": "integer"}},
            "required": ["run_id"],
        },
    },
    {
        "name": "list_outcomes",
        "description": "Every mutant outcome (file, line, function, mutation, status, reason, log path). "
                       "Optionally filter by status: killed|survived|invalid|error.",
        "inputSchema": {
            "type": "object",
            "properties": {"run_id": {"type": "integer"}, "status": {"type": "string"}},
            "required": ["run_id"],
        },
    },
    {
        "name": "cancel_run",
        "description": "Request cancellation; in-flight mutants drain to terminal outcomes.",
        "inputSchema": {
            "type": "object",
            "properties": {"run_id": {"type": "integer"}},
            "required": ["run_id"],
        },
    },
]


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}", "detail": e.read().decode()[:500]}
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def handle_tool(name, args):
    if name == "submit_run":
        body = {"source_path": args["source_path"]}
        for k in ("scope_filter", "mutant_limit", "run_budget_ms"):
            if args.get(k) is not None:
                body[k] = args[k]
        return api("POST", "/api/runs", body)
    if name == "get_run":
        return api("GET", f"/api/runs/{args['run_id']}")
    if name == "list_outcomes":
        data = api("GET", f"/api/runs/{args['run_id']}/outcomes")
        if args.get("status") and "outcomes" in data:
            data["outcomes"] = [o for o in data["outcomes"] if o["status"] == args["status"]]
        return data
    if name == "cancel_run":
        return api("POST", f"/api/runs/{args['run_id']}/cancel")
    return {"error": f"unknown tool {name}"}


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = req.get("method", "")
        rid = req.get("id")

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": req.get("params", {}).get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "codemutator", "version": "1.0.0"},
            }})
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = req.get("params", {})
            result = handle_tool(params.get("name", ""), params.get("arguments", {}))
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": json.dumps(result, indent=2)}]
            }})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": rid, "result": {}})
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"unknown method {method}"}})


if __name__ == "__main__":
    main()
