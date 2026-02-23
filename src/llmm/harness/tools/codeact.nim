## CodeAct Tool - Execute Python code in a persistent interpreter
## Allows the LLM to write Python code that can call other tools
## Inspired by: https://arxiv.org/abs/2402.01030

import std/[
  asyncdispatch,
  json,
  monotimes,
  os,
  strformat,
  strutils,
  times,
]

import ./base

# Use nim-subprocess for non-blocking I/O
import subprocess

# Embedded Python bridge script - written to workspace at runtime
const CodeActBridgePy* = """# codeact_bridge.py
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
"""

type
  CodeActDispatch* = proc(name: string, args: JsonNode): Future[JsonNode] {.gcsafe.}

  CodeActRuntime* = ref object
    pythonExe: string
    bridgePath: string
    process: Subprocess  # Changed from osproc.Process to subprocess.Subprocess
    dispatch: CodeActDispatch
    allowedTools: seq[string]  # Tools that Python code is allowed to call

proc writeBridgeFile*(workspaceDir: string): string =
  ## Writes the Python bridge script to the workspace directory
  ## Returns the path to the bridge file
  result = workspaceDir / "codeact_bridge.py"
  if not fileExists(result):
    # Ensure directory exists
    createDir(workspaceDir)
    writeFile(result, CodeActBridgePy)

proc isRunning(rt: CodeActRuntime): bool =
  rt.process != nil and rt.process.isRunning()

proc writeJsonLine(p: Subprocess, j: JsonNode) =
  ## Write a JSON line to the subprocess stdin
  let data = $j & "\n"
  let written = p.write(data)
  if written != data.len:
    raise newException(IOError, "Failed to write complete JSON line to subprocess")

proc ensureStarted(rt: CodeActRuntime) {.raises: [IOError, OSError, Exception].} =
  ## Starts the Python subprocess if not already running
  if rt.isRunning:
    return

  if not fileExists(rt.bridgePath):
    raise newException(IOError, "CodeAct bridge not found: " & rt.bridgePath)

  # Check if Python executable exists
  let whichCmd = when defined(windows): "where" else: "which"
  var checkOpts = SubprocessOptions(useStdout: true)
  let checkProc = startSubprocess(whichCmd, @[rt.pythonExe], checkOpts)
  let checkExit = checkProc.wait()
  checkProc.close()
  
  if checkExit != 0:
    raise newException(IOError, "Python executable not found: " & rt.pythonExe & 
      ". On Windows use 'python', on Unix use 'python3'")

  # Start Python with nim-subprocess
  var opts = SubprocessOptions(useStdin: true, useStdout: true, useStderr: true)
  rt.process = startSubprocess(rt.pythonExe, @["-u", rt.bridgePath], opts)
  
  # Give Python a moment to start and check if it crashed immediately
  sleep(100)
  
  if not rt.process.isRunning():
    var errMsg = "Python process exited immediately after starting"
    let stderrOutput = rt.process.readAllStderr(500)
    if stderrOutput.len > 0:
      errMsg &= ". Stderr: " & stderrOutput
    rt.process.close()
    rt.process = nil
    raise newException(IOError, errMsg)
  
  # Send init message with allowed tools to create wrapper functions
  rt.process.writeJsonLine(%*{"type": "init", "tools": rt.allowedTools})

proc readLineAsync(p: Subprocess): Future[string] {.async.} =
  ## Asynchronously read a line from the subprocess stdout
  ## Uses polling with hasDataStdout() to avoid blocking
  var buffer = ""
  
  while true:
    # Check if data is available without blocking
    if p.hasDataStdout():
      # Read available data (non-blocking with timeout=0)
      let chunk = p.readStdout(numBytesToRead = 1, timeoutMs = 0)
      if chunk.len == 0:
        # EOF reached
        if p.isStdoutEof():
          return buffer
        # No data yet, continue
      else:
        buffer.add(chunk)
        # Check if we have a complete line
        let newlinePos = buffer.find('\n')
        if newlinePos >= 0:
          let line = buffer[0..<newlinePos]
          # Keep remaining data in buffer for next read
          if newlinePos + 1 < buffer.len:
            buffer = buffer[newlinePos + 1..^1]
          else:
            buffer = ""
          return line
    else:
      # No data available, yield to async event loop
      # Check if process is still running
      if not p.isRunning() and not p.hasDataStdout():
        # Process exited, return what we have
        return buffer
      # Small sleep to avoid busy-waiting
      await sleepAsync(10)

proc readJsonLineAsync(p: Subprocess): Future[JsonNode] {.async.} =
  ## Read a JSON line from the process output stream asynchronously
  ## Returns EOF marker if stream is closed or process dies
  try:
    let line = await p.readLineAsync()
    if line.len == 0:
      # Empty line - check if process is still alive
      if not p.isRunning():
        return %*{"type": "eof"}
      # Could be a blank line, return EOF to be safe
      return %*{"type": "eof"}
    result = parseJson(line)
  except IOError:
    # Stream closed - process likely crashed
    return %*{"type": "eof"}
  except ValueError as e:
    # JSON parse error
    return %*{"type": "error", "message": "JSON parse error: " & e.msg}

proc isAllowed(rt: CodeActRuntime, toolName: string): bool =
  ## Check if a tool is allowed to be called from Python
  if rt.allowedTools.len == 0:
    return true
  result = toolName in rt.allowedTools

proc stop*(rt: CodeActRuntime) {.gcsafe, raises: [].}
  ## Forward declaration - stops the Python interpreter process

proc runCode*(rt: CodeActRuntime, code: string, timeoutSecs: int = 30): Future[JsonNode] {.gcsafe, async.} =
  ## Execute Python code in the persistent interpreter
  ## Handles nested tool calls from Python
  ## 
  ## Parameters:
  ##   code: Python code to execute
  ##   timeoutSecs: Maximum time to wait for completion (default: 30 seconds)
  
  # If process died from a previous call, clean it up
  if rt.process != nil and not rt.process.isRunning():
    rt.process.close()
    rt.process = nil
  
  # Ensure process is running
  try:
    rt.ensureStarted()
  except IOError as e:
    return toolError("Failed to start CodeAct interpreter: " & e.msg)
  except OSError as e:
    return toolError("Failed to start CodeAct interpreter: " & e.msg)
  except ValueError as e:
    return toolError("Failed to start CodeAct interpreter: " & e.msg)

  # Verify process is actually running before writing
  if not rt.process.isRunning():
    return toolError("CodeAct interpreter process failed to start or crashed immediately")

  # Send exec request to Python
  try:
    rt.process.writeJsonLine(%*{"type": "exec", "code": code})
  except IOError as e:
    return toolError("Failed to send code to CodeAct interpreter: " & e.msg)

  var toolTrace: seq[JsonNode] = @[]
  let deadline = getMonoTime() + initDuration(seconds = timeoutSecs)

  while true:
    # Check for timeout before each read
    if getMonoTime() > deadline:
      # Hard reset interpreter so next turn works
      rt.stop()
      return toolError(fmt"CodeAct timed out waiting for Python bridge ({timeoutSecs}s). Interpreter was restarted.")
    
    let msg = await rt.process.readJsonLineAsync()
    let msgType = if msg.hasKey("type"): msg["type"].getStr else: ""

    case msgType
    of "tool_call":
      let callId = msg["call_id"].getStr
      let toolName = msg["name"].getStr
      let toolArgs = msg["args"]

      if not rt.isAllowed(toolName):
        # Tool not allowed - return error but don't crash
        let errorPayload = toolError(fmt"Tool '{toolName}' is not available from CodeAct context")
        rt.process.writeJsonLine(%*{
          "type": "tool_result",
          "call_id": callId,
          "payload": errorPayload
        })
        toolTrace.add(%*{
          "name": toolName,
          "args": toolArgs,
          "ok": false,
          "error": "Tool not available from CodeAct"
        })
        continue

      # Debug: log the tool call
      stderr.writeLine(fmt"[CodeAct] Dispatching tool: {toolName} with args: {toolArgs}")
      stderr.flushFile()

      # Dispatch to the actual tool handler - this await now works properly!
      let payload = await rt.dispatch(toolName, toolArgs)
      let success = payload.hasKey("success") and payload["success"].getBool

      # Debug: log the result
      stderr.writeLine(fmt"[CodeAct] Tool {toolName} result: success={success}")
      stderr.flushFile()

      toolTrace.add(%*{
        "name": toolName,
        "args": toolArgs,
        "ok": success,
        "error": if not success and payload.hasKey("error"): payload["error"].getStr else: ""
      })

      rt.process.writeJsonLine(%*{
        "type": "tool_result",
        "call_id": callId,
        "payload": payload
      })

    of "exec_result":
      # Execution complete - check if Python reported an error
      let ok = msg.hasKey("ok") and msg["ok"].getBool
      var result = msg
      result["tool_trace"] = %toolTrace
      
      if ok:
        return toolSuccess(result)
      else:
        # Python execution failed - return error with traceback
        let tb = if msg.hasKey("traceback"): msg["traceback"].getStr else: "Unknown error"
        # Also include stdout/stderr for context (truncated)
        let stdoutStr = if msg.hasKey("stdout"): msg["stdout"].getStr else: ""
        let stderrStr = if msg.hasKey("stderr"): msg["stderr"].getStr else: ""
        var errorMsg = "CodeAct Python error:\n" & tb
        if stdoutStr.len > 0:
          errorMsg &= "\n\n[stdout]:\n" & stdoutStr
        if stderrStr.len > 0:
          errorMsg &= "\n\n[stderr]:\n" & stderrStr
        return toolError(errorMsg)

    of "eof":
      # Python process exited unexpectedly - try to capture any error output
      var errorMsg = "CodeAct interpreter closed unexpectedly"
      try:
        if rt.process != nil:
          # Get any remaining stderr from the process
          let remainingStderr = rt.process.readAllStderr(500)
          if remainingStderr.len > 0:
            errorMsg &= ". Stderr: " & remainingStderr
          # Get exit code if available
          let exitCode = rt.process.wait()
          if exitCode != -1:
            errorMsg &= ". Exit code: " & $exitCode
      except:
        discard
      return toolError(errorMsg)
    
    of "error":
      # Internal error from readJsonLine
      return toolError("CodeAct bridge error: " & msg.getOrDefault("message").getStr)

    else:
      return toolError("Unexpected message from CodeAct bridge: " & $msg)

proc stop*(rt: CodeActRuntime) {.gcsafe.} =
  ## Stop the Python interpreter process
  if rt.process != nil:
    rt.process.terminate(graceful = false)
    rt.process.close()
    rt.process = nil

proc newCodeActRuntime*(
  workspaceDir: string,
  dispatch: CodeActDispatch,
  availableTools: seq[string],
  pythonExe: string = ""
): CodeActRuntime =
  ## Create a new CodeAct runtime with per-agent Python process
  ## 
  ## Parameters:
  ##   workspaceDir: Directory where bridge file will be written
  ##   dispatch: Callback to execute tool calls from Python
  ##   availableTools: List of tool names that can be called from Python
  ##   pythonExe: Path to Python executable (auto-detected if empty - uses 'python' on Windows, 'python3' on Unix)
  
  # Auto-detect Python executable if not specified
  let actualPythonExe = if pythonExe.len > 0:
    pythonExe
  else:
    when defined(windows):
      "python"
    else:
      "python3"
  
  # Write bridge file if needed
  let bridgePath = writeBridgeFile(workspaceDir)
  
  # Build allowlist - exclude codeact_tool itself to prevent recursion
  var allowed: seq[string] = @[]
  for toolName in availableTools:
    if toolName != "codeact_tool":
      allowed.add(toolName)
  
  new(result)
  result.pythonExe = actualPythonExe
  result.bridgePath = bridgePath
  result.dispatch = dispatch
  result.allowedTools = allowed
  result.process = nil

proc truncate*(s: string, maxLen: int, suffix: string = "... [truncated]"): string =
  ## Truncate a string to maxLen characters, adding suffix if truncated
  if s.len <= maxLen:
    return s
  let truncLen = maxLen - suffix.len
  if truncLen <= 0:
    return suffix
  return s[0..<truncLen] & suffix

proc CodeActTool*(
  rt: CodeActRuntime
): Tool =
  ## Factory for the CodeAct tool
  const maxOutputLen = 8000  # Truncate stdout/stderr to ~8KB
  const maxTraceLen = 4000   # Truncate tool trace entries
  
  Tool(
    name: "codeact_tool",
    description: "Execute Python code in a persistent interpreter with access to other tools. " &
                 "CALL TOOLS using: tools('tool_name', arg1=value1, arg2=value2) OR just tool_name(arg1=value1, ...). " &
                 "Available tools: " & rt.allowedTools.join(", ") & ". " &
                 "Variables and imports persist across calls. " &
                 "AVOID printing full tool results - print small summaries only to save tokens.",
    parameters: %*{
      "type": "object",
      "properties": {
        "code": {
          "type": "string",
          "description": "Python code to execute. Use tools() or direct tool_name() calls to invoke other tools."
        }
      },
      "required": ["code"],
      "additionalProperties": false
    },
    strict: true,
    handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
      let code = args["code"].getStr
      let result = await rt.runCode(code)
      
      # Truncate outputs to reduce token usage
      if result.hasKey("stdout"):
        result["stdout"] = %truncate(result["stdout"].getStr, maxOutputLen)
      if result.hasKey("stderr"):
        result["stderr"] = %truncate(result["stderr"].getStr, maxOutputLen)
      if result.hasKey("traceback"):
        result["traceback"] = %truncate(result["traceback"].getStr, maxOutputLen)
      if result.hasKey("tool_trace"):
        # Truncate args in tool_trace to avoid huge payloads
        var truncatedTrace: seq[JsonNode] = @[]
        for entry in result["tool_trace"].getElems:
          var newEntry = entry
          if entry.hasKey("args"):
            let argsStr = $entry["args"]
            if argsStr.len > maxTraceLen:
              newEntry["args"] = %truncate(argsStr, maxTraceLen)
          truncatedTrace.add(newEntry)
        result["tool_trace"] = %truncatedTrace
      
      return result
  )
