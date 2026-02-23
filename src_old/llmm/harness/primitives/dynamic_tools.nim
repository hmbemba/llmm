## llmm/harness/primitives/dynamic_tools.nim
##
## Dynamic tool loading system for the REPL.
## Uses the Subprocess/IPC model: tools are compiled as standalone executables
## and invoked via STDIO with JSON-RPC style communication.
##
## This avoids all DLL/shared-library segfaults caused by separate GC heaps.
##
## Architecture (inspired by MCP / Language Server Protocol):
##   1. Tool source files define factory procs ending with 'Tool' (e.g., MyTool)
##   2. Factory procs are auto-detected at compile time - no metadata blocks needed
##   3. Tools are compiled to standalone .exe (not .dll)
##   4. When a tool is called, we spawn the exe, pipe JSON args to stdin,
##      and read JSON result from stdout
##   5. The exe is a simple dispatcher: reads JSON from stdin, calls the
##      appropriate factory proc, runs the handler, writes JSON to stdout
##

import std/[
  os, strutils, tables, json, asyncdispatch, times,
  hashes, strformat, options, osproc, streams, re
]

import ../tools/base
import ./agent
import ic

export base

type
  ToolSourceKind* = enum
    tskNimSource      ## .nim file to compile to exe
    tskCompiledExe    ## Pre-compiled executable
    tskJsonWrapper    ## JSON definition (command wrapper, HTTP, etc.)

  LoadedTool* = object
    name*: string
    sourcePath*: string           ## Original source file
    compiledPath*: string         ## Compiled .exe path
    loadTime*: DateTime
    kind*: ToolSourceKind
    factoryHash*: Hash            ## For detecting changes
    isBuiltIn*: bool              ## True for tools loaded at startup
    factoryName*: string          ## Factory proc name in the source

  LoadedToolInfo* = object
    name*: string
    source*: string
    loadTime*: DateTime
    kind*: ToolSourceKind
    isBuiltIn*: bool

  ToolLoadError* = object of CatchableError
  ToolCompileError* = object of ToolLoadError
  ToolNotFoundError* = object of ToolLoadError

  DynamicToolRegistry* = ref object
    agent*: Agent
    workspaceDir*: string
    toolsDir*: string             ## workspace/tools/
    cacheDir*: string             ## workspace/tools/.cache/
    loaded*: OrderedTable[string, LoadedTool]  ## toolName -> info
    compiledExes*: Table[string, string]  ## sourcePath -> compiled exe path
    hotReload*: bool
    extraPaths*: seq[string]      ## FIX: Additional paths for compilation
    forceRecompile*: bool         ## FIX: Force recompilation on next call

const
  TOOLS_SUBDIR* = "tools"
  CACHE_SUBDIR* = ".cache"
  SUPPORTED_EXTENSIONS* = [".nim"]

# ----------------------------------------------------------------------------
# Initialization
# ----------------------------------------------------------------------------

proc initDynamicTools*(agent: Agent, workspaceDir: string, hotReload: bool = false, 
                          extraPaths: seq[string] = @[]): DynamicToolRegistry =
  icb "initDynamicTools called", workspaceDir, hotReload
  result = DynamicToolRegistry(
    agent: agent,
    workspaceDir: workspaceDir,
    toolsDir: workspaceDir / TOOLS_SUBDIR,
    cacheDir: workspaceDir / TOOLS_SUBDIR / CACHE_SUBDIR,
    hotReload: hotReload,
    extraPaths: extraPaths,
    forceRecompile: false,
    loaded: initOrderedTable[string, LoadedTool](),
    compiledExes: initTable[string, string]()
  )
  createDir(result.toolsDir)
  createDir(result.cacheDir)
  ic "Directories created", result.toolsDir, result.cacheDir

# ----------------------------------------------------------------------------
# Utility
# ----------------------------------------------------------------------------

proc fileHash(path: string): Hash =
  if not fileExists(path): return hash("")
  return hash(readFile(path))

# ----------------------------------------------------------------------------
# Factory Detection (Primary method - no ##@tool blocks needed)
# ----------------------------------------------------------------------------

proc detectFactoryProcs(nimPath: string): seq[tuple[factory: string, params: seq[tuple[name, typeStr: string]]]] =
  ## Detect factory procs by scanning for patterns like:
  ##   proc NameTool*(...): Tool =
  ## Factory procs ending with 'Tool' are auto-detected and used to generate tool metadata.
  
  let content = readFile(nimPath)
  let lines = content.splitLines()
  
  # Regex to match: proc NameTool*(...): Tool =
  # Captures: 1 = factory name, 2 = params
  let factoryRe = re"^proc\s+(\w+Tool)\*\s*\(([^)]*)\)\s*:\s*Tool\s*="
  
  for i, line in lines:
    let trimmed = line.strip()
    
    var matches: array[2, string]
    if match(trimmed, factoryRe, matches):
      let factoryName = matches[0]
      let paramsStr = matches[1]
      
      # Parse parameters (simple version)
      var params: seq[tuple[name, typeStr: string]] = @[]
      if paramsStr.len > 0:
        for param in paramsStr.split(","):
          let parts = param.strip().split(":")
          if parts.len >= 2:
            let paramNames = parts[0].strip()
            let paramType = parts[1].strip()
            # Handle multiple names: "basePath, nimFlags: string"
            for name in paramNames.split(" "):
              let cleanName = name.strip()
              if cleanName.len > 0 and cleanName != "":
                params.add((name: cleanName, typeStr: paramType))
      
      result.add((factory: factoryName, params: params))

# ----------------------------------------------------------------------------
# Compilation — builds a standalone .exe with a JSON-RPC dispatcher main()
# ----------------------------------------------------------------------------

proc generateDispatcherSource(nimPath: string, tools: seq[tuple[name, factory: string]], outputPath: string) =
  ## Generate a standalone Nim program that:
  ##   1. Reads a JSON object from stdin: {"tool": "<name>", "args": {...}}
  ##   2. Calls the corresponding factory proc to get a Tool
  ##   3. Runs tool.handler(args)
  ##   4. Writes the JSON result to stdout
  ##
  ## This is the "main" for the subprocess — the bridge between IPC and tool code.

  let (toolDir, moduleName, _) = nimPath.splitFile()

  var dispatchCases = ""
  for t in tools:
    dispatchCases.add &"""
    of "{t.name}":
      let tool = {t.factory}(basePath)
      result = waitFor tool.handler(args)
"""

  let source = &"""
## Auto-generated subprocess dispatcher for {moduleName}
## DO NOT EDIT — regenerated on each compilation

import std/[json, asyncdispatch, os, strutils]
import base
import {moduleName}

proc dispatch(toolName: string, args: JsonNode, basePath: string): JsonNode =
  case toolName
{dispatchCases}
    else:
      result = toolError("Unknown tool in subprocess: " & toolName)

proc main() =
  # Read JSON request from stdin
  var inputStr = ""
  var line: string
  while stdin.readLine(line):
    inputStr.add(line)
    inputStr.add("\n")

  if inputStr.strip().len == 0:
    let err = %*{{"success": false, "error": "No input received on stdin"}}
    stdout.write($err)
    return

  let request = parseJson(inputStr.strip())

  let toolName = request["tool"].getStr()
  let args = request.getOrDefault("args")
  let basePath = request.getOrDefault("basePath").getStr(".")

  let response = dispatch(toolName, if args.isNil: newJObject() else: args, basePath)
  stdout.write($response)

main()
"""

  writeFile(outputPath, source)
  ic "Generated dispatcher source", outputPath

proc compileToolExe(nimPath: string, cacheDir: string, extraPaths: seq[string] = @[], force: bool = false): string =
  ## Compile a tool source file to a standalone executable.
  ## Returns the path to the compiled .exe.

  let
    (toolDir, name, _) = nimPath.splitFile()
    dispatcherPath = cacheDir / &"{name}_dispatch.nim"
    exeName = when defined(windows): name & ".exe" else: name
    exePath = cacheDir / exeName
    nimcacheDir = cacheDir / "nimcache_" & name

  createDir(nimcacheDir)
  
  # FIX: Delete existing exe if force recompile requested
  if force and fileExists(exePath):
    try:
      removeFile(exePath)
      ic "Force recompile: removed existing exe", exePath
    except:
      discard

  # Detect factory procs to find tool names and factories
  let factories = detectFactoryProcs(nimPath)
  var tools: seq[tuple[name, factory: string]] = @[]
  
  for f in factories:
    # Extract tool name from factory name: "NimCompileTool" -> "nim_compile"
    var toolName = f.factory
    # Remove "Tool" suffix
    if toolName.endsWith("Tool"):
      toolName = toolName[0..^5]
    # Convert CamelCase to snake_case
    var snakeName = ""
    for i, c in toolName:
      if c in {'A'..'Z'} and i > 0:
        snakeName.add('_')
      snakeName.add(c.toLowerAscii())
    
    tools.add((name: snakeName, factory: f.factory))

  if tools.len == 0:
    raise newException(ToolCompileError, &"No factory procs (ending with 'Tool') found in {nimPath}")

  # Generate the dispatcher source
  generateDispatcherSource(nimPath, tools, dispatcherPath)

  # Compile as a standalone executable (NOT --app:lib)
  # Add --path for the tool source directory so the import can find the module
  var pathFlags = &"--path:{toolDir}"
  
  # FIX: Add extra paths for compilation
  for extraPath in extraPaths:
    pathFlags.add(&" --path:{extraPath}")
  
  let cmd = &"nim c -d:release --gc:orc --threads:on {pathFlags} --out:{exePath} --nimcache:{nimcacheDir} {dispatcherPath}"

  icb "compileToolExe: compiling", cmd
  let (output, exitCode) = execCmdEx(cmd)

  if exitCode != 0:
    icr "compileToolExe: compilation failed", exitCode
    raise newException(ToolCompileError, &"Compilation failed:\n{output}")

  if not fileExists(exePath):
    raise newException(ToolCompileError, &"Compilation succeeded but exe not found: {exePath}")

  ic "compileToolExe: success", exePath
  return exePath

# ----------------------------------------------------------------------------
# Subprocess IPC — call a tool by spawning its exe
# ----------------------------------------------------------------------------

proc callToolSubprocess(exePath: string, toolName: string, args: JsonNode, basePath: string): Future[JsonNode] {.async.} =
  ## Invoke a tool by spawning its compiled exe and communicating via STDIO.
  ##
  ## Protocol:
  ##   stdin  -> {"tool": "nim_list_types", "args": {"filename": "foo.nim"}, "basePath": "."}
  ##   stdout <- {"success": true, "types": [...], ...}

  let request = %*{
    "tool": toolName,
    "args": args,
    "basePath": basePath
  }

  let requestStr = $request

  icb "callToolSubprocess", toolName, exePath
  
  # FIX: Debug logging for troubleshooting
  when defined(debugDynamicTools):
    echo &"[DEBUG] Spawning: {exePath}"
    echo &"[DEBUG] Working dir: {basePath}"
    echo &"[DEBUG] Request: {requestStr}"

  try:
    let process = startProcess(
      exePath,
      workingDir = basePath,  # FIX: Set working directory for proper path resolution
      options = {poUsePath}
    )

    # Write request to stdin
    let inStream = process.inputStream
    inStream.write(requestStr)
    inStream.close()  # Signal EOF

    # Read response from stdout
    let outStream = process.outputStream
    var responseStr = ""
    var line: string
    while outStream.readLine(line):
      responseStr.add(line)
      responseStr.add("\n")

    # Also capture any remaining data
    try:
      responseStr.add(outStream.readAll())
    except:
      discard

    # FIX: Capture stderr for debugging crashes
    let errStream = process.errorStream
    var stderrStr = ""
    try:
      stderrStr = errStream.readAll()
    except:
      discard
    errStream.close()

    let exitCode = process.waitForExit()
    process.close()

    if responseStr.strip().len == 0:
      # FIX: Include stderr in error message for debugging
      var errorMsg = &"Tool subprocess returned no output (exit code: {exitCode})"
      if stderrStr.len > 0:
        errorMsg.add(&", stderr: {stderrStr[0..min(stderrStr.len-1, 500)]}")
      return toolError(errorMsg)

    try:
      return parseJson(responseStr.strip())
    except JsonParsingError as e:
      return toolError(&"Tool subprocess returned invalid JSON: {e.msg}\nRaw output: {responseStr[0..min(responseStr.len-1, 500)]}")

  except OSError as e:
    return toolError(&"Failed to spawn tool subprocess: {e.msg}")
  except CatchableError as e:
    return toolError(&"Tool subprocess error: {e.msg}")

# ----------------------------------------------------------------------------
# Tool creation — wraps subprocess call in a Tool handler
# ----------------------------------------------------------------------------

proc createSubprocessTool(reg: DynamicToolRegistry, nimPath: string, name, description: string,
                          params: JsonNode, strictVal: bool, factoryName: string): Tool =
  ## Create a Tool whose handler invokes the compiled exe via subprocess IPC.
  ## The exe is compiled lazily on first call (or eagerly if already compiled).

  let regRef = reg
  let nimPathRef = nimPath
  let basePath = reg.workspaceDir

  Tool(
    name: name,
    description: description,
    parameters: params,
    strict: strictVal,
    handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
      # Ensure the exe is compiled
      var exePath: string
      var wasRecompiled = false

      if regRef.compiledExes.hasKey(nimPathRef):
        exePath = regRef.compiledExes[nimPathRef]
      else:
        # Compile on first use
        try:
          echo &"  ⚙ Compiling tool subprocess: {nimPathRef.extractFilename}..."
          exePath = compileToolExe(nimPathRef, regRef.cacheDir, regRef.extraPaths, regRef.forceRecompile)
          regRef.compiledExes[nimPathRef] = exePath
          wasRecompiled = true
          regRef.forceRecompile = false  # Reset after use
          echo &"  ✓ Compiled: {exePath.extractFilename}"
        except ToolCompileError as e:
          return toolError(&"Failed to compile tool: {e.msg}")

      # Verify exe still exists (could have been cleaned)
      if not fileExists(exePath):
        try:
          exePath = compileToolExe(nimPathRef, regRef.cacheDir, regRef.extraPaths, regRef.forceRecompile)
          regRef.compiledExes[nimPathRef] = exePath
          wasRecompiled = true
          regRef.forceRecompile = false  # Reset after use
        except ToolCompileError as e:
          return toolError(&"Failed to recompile tool: {e.msg}")

      # Call via subprocess
      var result = await callToolSubprocess(exePath, name, args, basePath)
      
      # FIX: If the call failed with no output, try recompiling once (stale exe detection)
      if not result["success"].getBool(false) and not wasRecompiled:
        let errorMsg = result.getOrDefault("error").getStr("")
        if "no output" in errorMsg.toLowerAscii() or "exit code" in errorMsg.toLowerAscii():
          echo &"  ⚙ Tool failed, attempting recompile: {nimPathRef.extractFilename}..."
          try:
            exePath = compileToolExe(nimPathRef, regRef.cacheDir, regRef.extraPaths, force=true)
            regRef.compiledExes[nimPathRef] = exePath
            echo &"  ✓ Recompiled: {exePath.extractFilename}"
            # Retry the call
            result = await callToolSubprocess(exePath, name, args, basePath)
          except ToolCompileError as e:
            # Return original error, but note recompile failed
            result["recompile_attempted"] = %true
            result["recompile_error"] = %e.msg
      
      return result
  )

# ----------------------------------------------------------------------------
# Metadata parsing (Phase 3 - factory detection only)
# ----------------------------------------------------------------------------

proc parseToolMetadata(nimPath: string): seq[tuple[name, description, factory: string, params: JsonNode, strict: bool]] =
  ## Parse tool metadata by detecting factory procs in the source file.
  ## No ##@tool blocks needed - just define factory procs ending with 'Tool'.
  
  let factories = detectFactoryProcs(nimPath)
  
  for f in factories:
      # Extract tool name from factory name: "NimCompileTool" -> "nim_compile"
      var toolName = f.factory
      # Remove "Tool" suffix
      if toolName.endsWith("Tool"):
        toolName = toolName[0..^5]
      # Convert CamelCase to snake_case
      var snakeName = ""
      for i, c in toolName:
        if c in {'A'..'Z'} and i > 0:
          snakeName.add('_')
        snakeName.add(c.toLowerAscii())
      
      # Build default parameters schema from factory params
      var paramsObj = newJObject()
      paramsObj["type"] = %"object"
      var propsObj = newJObject()
      var requiredArr = newJArray()
      
      for p in f.params:
        var propObj = newJObject()
        propObj["type"] = %"string"  # Default to string
        if p.typeStr.contains("seq"):
          propObj["type"] = %"array"
          propObj["items"] = %*{"type": "string"}
        
        # Check if has default value (contains "=")
        let hasDefault = p.typeStr.contains("=")
        
        if not hasDefault:
          requiredArr.add(%p.name)
        
        propsObj[p.name] = propObj
      
      paramsObj["properties"] = propsObj
      if requiredArr.len > 0:
        paramsObj["required"] = requiredArr
      paramsObj["additionalProperties"] = %false
      
      result.add((
        name: snakeName,
        description: &"Tool generated from {f.factory}",
        factory: f.factory,
        params: paramsObj,
        strict: requiredArr.len > 0  # Strict only if all params required
      ))

# ----------------------------------------------------------------------------
# Command/HTTP wrapper tools (no subprocess needed)
# ----------------------------------------------------------------------------

proc createCommandWrapperTool(name, description: string, params: JsonNode, cmd: string): Tool =
  Tool(
    name: name,
    description: description,
    parameters: params,
    handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
      var fullCmd = cmd
      for key, val in args:
        fullCmd = fullCmd.replace(&"{{{{{key}}}}}", val.getStr())
      let (output, exitCode) = execCmdEx(fullCmd)
      if exitCode != 0:
        return toolError(&"Command failed (exit {exitCode}): {output}")
      return toolSuccess(%*{"output": output.strip()})
  )

proc createHttpTool(name, description: string, params: JsonNode, url: string): Tool =
  Tool(
    name: name,
    description: description,
    parameters: params,
    handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
      return toolSuccess(%*{
        "note": "HTTP tool - full implementation requires httpclient import",
        "url": url,
        "args": args
      })
  )

# ----------------------------------------------------------------------------
# Core Loading Operations
# ----------------------------------------------------------------------------

proc registerBuiltInTools*(reg: DynamicToolRegistry) =
  if reg.agent.isNil: return
  for name, tool in reg.agent.cfg.tools:
    if not reg.loaded.hasKey(name):
      reg.loaded[name] = LoadedTool(
        name: name,
        sourcePath: "(built-in)",
        loadTime: now(),
        kind: tskCompiledExe,
        isBuiltIn: true
      )

proc loadFromNimSource*(reg: DynamicToolRegistry, nimPath: string): seq[string] =
  ## Load tools from a Nim source file.
  ## Parses metadata, then creates subprocess-backed Tool handlers.
  ## The actual compilation happens lazily on first tool call.

  icb "=== loadFromNimSource START ===", nimPath

  if not fileExists(nimPath):
    raise newException(ToolNotFoundError, &"File not found: {nimPath}")

  let sourceHash = fileHash(nimPath)

  # Check if already loaded and unchanged
  for toolName, info in reg.loaded:
    if info.sourcePath == nimPath and info.factoryHash == sourceHash:
      return @[toolName]

  # Parse metadata
  let toolDefs = parseToolMetadata(nimPath)

  if toolDefs.len == 0:
    icy "loadFromNimSource: no factory procs (ending with 'Tool') found in", nimPath
    return @[]

  # Invalidate cached exe if source changed
  if reg.compiledExes.hasKey(nimPath):
    reg.compiledExes.del(nimPath)
    ic "Invalidated cached exe for changed source", nimPath

  for def in toolDefs:
    let 
      defName = def.name
      defDesc = def.description
      defFactory = def.factory
      defParams = def.params
      defStrict = def.strict

    let tool = if defFactory.len > 0:
      reg.createSubprocessTool(nimPath, defName, defDesc, defParams, defStrict, defFactory)
    else:
      Tool(
        name: defName,
        description: defDesc,
        parameters: defParams,
        strict: defStrict,
        handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
          return toolError(&"Tool '{defName}' is metadata-only. Add a factory proc.")
      )

    if not reg.agent.isNil:
      reg.agent.addTools(tool)

    reg.loaded[defName] = LoadedTool(
      name: defName,
      sourcePath: nimPath,
      compiledPath: "",
      loadTime: now(),
      kind: tskNimSource,
      factoryHash: sourceHash,
      isBuiltIn: false,
      factoryName: defFactory
    )

    result.add(defName)
    ic "Loaded tool (subprocess-backed)", defName
# ----------------------------------------------------------------------------
# Eager compilation (optional — call after loading to avoid first-call latency)
# ----------------------------------------------------------------------------

proc precompileTools*(reg: DynamicToolRegistry, nimPath: string) =
  ## Eagerly compile the tool exe so the first call doesn't have compilation latency.
  ## Call this after loadFromNimSource if you want immediate readiness.
  if reg.compiledExes.hasKey(nimPath):
    return  # Already compiled
  try:
    let exePath = compileToolExe(nimPath, reg.cacheDir, reg.extraPaths, reg.forceRecompile)
    reg.compiledExes[nimPath] = exePath
    reg.forceRecompile = false  # Reset after use
    ic "Precompiled tool exe", exePath
  except ToolCompileError as e:
    icr "Precompilation failed (will retry on first call)", e.msg

# ----------------------------------------------------------------------------
# Tool Management Operations
# ----------------------------------------------------------------------------

proc unloadTool*(reg: DynamicToolRegistry, toolName: string): bool =
  if not reg.loaded.hasKey(toolName): return false
  let info = reg.loaded[toolName]
  if info.isBuiltIn:
    raise newException(ToolLoadError, &"Cannot unload built-in tool '{toolName}'")
  if not reg.agent.isNil:
    reg.agent.cfg.tools.del(toolName)
  reg.loaded.del(toolName)
  return true

proc reloadTool*(reg: DynamicToolRegistry, toolName: string): bool =
  if not reg.loaded.hasKey(toolName): return false
  let info = reg.loaded[toolName]
  if info.isBuiltIn:
    raise newException(ToolLoadError, &"Cannot reload built-in tool '{toolName}'")
  if info.kind != tskNimSource or not fileExists(info.sourcePath):
    raise newException(ToolLoadError, &"Cannot reload '{toolName}': source not available")

  # Invalidate cached exe
  if reg.compiledExes.hasKey(info.sourcePath):
    reg.compiledExes.del(info.sourcePath)

  discard reg.unloadTool(toolName)
  let loaded = reg.loadFromNimSource(info.sourcePath)
  return toolName in loaded

proc reloadAll*(reg: DynamicToolRegistry): tuple[success: int, failed: int] =
  var success, failed = 0
  var toReload: seq[string] = @[]
  for name, info in reg.loaded:
    if not info.isBuiltIn and info.kind == tskNimSource:
      toReload.add(name)
  for toolName in toReload:
    try:
      if reg.reloadTool(toolName): inc success
      else: inc failed
    except CatchableError: inc failed
  return (success, failed)

# ----------------------------------------------------------------------------
# Query Operations
# ----------------------------------------------------------------------------

proc listLoaded*(reg: DynamicToolRegistry): seq[LoadedToolInfo] =
  for name, info in reg.loaded:
    result.add(LoadedToolInfo(
      name: name, source: info.sourcePath, loadTime: info.loadTime,
      kind: info.kind, isBuiltIn: info.isBuiltIn
    ))

proc getToolInfo*(reg: DynamicToolRegistry, toolName: string): Option[LoadedToolInfo] =
  if reg.loaded.hasKey(toolName):
    let info = reg.loaded[toolName]
    return some(LoadedToolInfo(
      name: info.name, source: info.sourcePath, loadTime: info.loadTime,
      kind: info.kind, isBuiltIn: info.isBuiltIn
    ))
  return none(LoadedToolInfo)

proc isLoaded*(reg: DynamicToolRegistry, toolName: string): bool =
  reg.loaded.hasKey(toolName)

proc scanToolDirectory*(reg: DynamicToolRegistry): seq[string] =
  if not dirExists(reg.toolsDir): return
  for file in walkFiles(reg.toolsDir / "*.nim"):
    # Skip dispatcher files
    if not file.extractFilename.endsWith("_dispatch.nim"):
      result.add(file)

# ----------------------------------------------------------------------------
# Tool File Creation
# ----------------------------------------------------------------------------

proc createToolSkeleton*(reg: DynamicToolRegistry, toolName: string): string =
  let
    safeName = toolName.replace(" ", "_").toLowerAscii()
    filePath = reg.toolsDir / &"{safeName}.nim"

  if fileExists(filePath):
    raise newException(ToolLoadError, &"Tool file already exists: {filePath}")

  let skeleton = &"""## {safeName}.nim
## Dynamic tool for LLMM (subprocess model)
## Generated: {now()}
##
## This tool is compiled to a standalone exe and invoked via STDIO.
## The auto-generated dispatcher handles JSON serialization.
##
## Define factory procs ending with 'Tool' - they will be auto-detected.

import std/[json, asyncdispatch, strutils, os]
import base  ## Adjust import path as needed

proc {safeName}Tool*(basePath: string = "."): Tool =
  Tool(
    name: "{toolName}",
    description: "Tool description",
    parameters: %*{{
      "type": "object",
      "properties": {{
        "arg1": {{
          "type": "string",
          "description": "First argument"
        }}
      }},
      "required": ["arg1"]
    }},
    handler: proc(args: JsonNode): Future[JsonNode] {{.async, gcsafe.}} =
      let arg1 = args["arg1"].getStr()
      ## TODO: implement
      return toolSuccess(%*{{"result": "done", "arg1": arg1}})
  )
"""

  writeFile(filePath, skeleton)
  return filePath

# ----------------------------------------------------------------------------
# Auto-load at Startup
# ----------------------------------------------------------------------------

proc autoLoadTools*(reg: DynamicToolRegistry): tuple[loaded: int, errors: seq[string]] =
  var loaded = 0
  var errors: seq[string] = @[]

  icb "=== autoLoadTools START ==="

  reg.registerBuiltInTools()

  let toolFiles = reg.scanToolDirectory()
  for filePath in toolFiles:
    try:
      let toolNames = reg.loadFromNimSource(filePath)
      loaded += toolNames.len
    except CatchableError as ex:
      errors.add(&"{filePath}: {ex.msg}")

  icb "=== autoLoadTools END ===", loaded, errors.len
  return (loaded, errors)