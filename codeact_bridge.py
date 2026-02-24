# codeact_bridge.py
import sys, json, traceback, contextlib, io, os

# Protocol streams (never redirected by contextlib.redirect_stdout)
# These are the ORIGINAL stdin/stdout before any redirection
PROTO_OUT = sys.__stdout__
PROTO_IN = sys.__stdin__

def _send(msg):
    PROTO_OUT.write(json.dumps(msg) + "\n")
    PROTO_OUT.flush()

def _recv():
    line = PROTO_IN.readline()
    if not line:
        raise EOFError("stdin closed")
    return json.loads(line)

def tool(name, args=None, **kwargs):
    # Call a tool by name. Returns the tool's JSON payload.
    # Allow tool("apply_diff", filename="x", ...) or tool("apply_diff", {...})
    payload = args if args is not None else kwargs
    
    # Use a counter for unique call_ids instead of id(payload)
    tool._ctr = getattr(tool, "_ctr", 0) + 1
    call_id = f"tc_{tool._ctr}"
    
    _send({"type": "tool_call", "call_id": call_id, "name": name, "args": payload})
    resp = _recv()
    if resp.get("type") != "tool_result" or resp.get("call_id") != call_id:
        raise RuntimeError(f"Bad tool_result: {resp}")
    result = resp.get("payload")
    # Pretty print for debugging (goes to captured stdout during redirect)
    if isinstance(result, dict) and result.get("success"):
        if "message" in result:
            print(f"[tool {name}] {result['message']}")
        else:
            print(f"[tool {name}] OK")
    elif isinstance(result, dict) and not result.get("success"):
        print(f"[tool {name}] ERROR: {result.get('error', 'Unknown error')}")
    return result

# Nice ergonomic alias
tools = tool

# Persistent state across turns
# Include tool functions so they're available to exec()
G = {"__name__": "__codeact__", "tool": tool, "tools": tools}

# Wait for init message with allowed tools
init_line = PROTO_IN.readline()
if init_line:
    init_req = json.loads(init_line)
    if init_req.get("type") == "init":
        ALLOWED_TOOLS = init_req.get("tools", [])
        # Create wrapper functions for each allowed tool
        # This allows: file_create(...) instead of tools("file_create", ...)
        for _tool_name in ALLOWED_TOOLS:
            def _make_wrapper(name):
                def wrapper(**kwargs):
                    return tools(name, **kwargs)
                wrapper.__name__ = name
                wrapper.__doc__ = f"Call the {name} tool with keyword arguments"
                return wrapper
            G[_tool_name] = _make_wrapper(_tool_name)

while True:
    line = PROTO_IN.readline()
    if not line:
        break

    req = json.loads(line)
    if req.get("type") != "exec":
        _send({"type": "exec_result", "ok": False, "stdout": "", "stderr": "", "traceback": "Unknown request"})
        continue

    code = req.get("code", "")
    out = io.StringIO()
    err = io.StringIO()
    ok = True
    tb = ""

    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            exec(code, G, G)
        except Exception:
            ok = False
            tb = traceback.format_exc()

    _send({
        "type": "exec_result",
        "ok": ok,
        "stdout": out.getvalue(),
        "stderr": err.getvalue(),
        "traceback": tb
    })
