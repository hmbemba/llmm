## llmm/harness/primitives/dynamic_tools.nim
##
## Dynamic tool loading system for the REPL.
## Uses the Subprocess/IPC model: tools are compiled as standalone executables
## and invoked via STDIO with JSON-RPC style communication.
##
## v2: No more ##@tool comment blocks. Tool metadata is extracted from:
##   1. The {.tool.} pragma macro (compile-time, via listTools())
##   2. Direct factory proc calls (runtime introspection)
##
## Architecture:
##   1. Tool source files use {.tool.} pragma on factory procs
##   2. A `generateToolList()` call at module bottom produces listTools()
##   3. For subprocess mode: we compile a discovery binary first (fast),
##      call listTools() to get metadata, then generate the real dispatcher
##   4. For compiled-together mode: just import and call the factories
##

import std/[
  os, strutils, tables, json, asyncdispatch, times,
  hashes, strformat, options, osproc, streams
]

import ../tools/base
import ../tools/tool_pragma
import ./agent
import ic

export base
export tool_pragma

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

const
  TOOLS_SUBDIR* = "tools"
  CACHE_SUBDIR* = ".cache"
  SUPPORTED_EXTENSIONS* = [".nim"]

# ----------------------------------------------------------------------------
# Initialization
# ----------------------------------------------------------------------------

proc initDynamicTools*(agent: Agent, workspaceDir: string, hotReload: bool = false): DynamicToolRegistry =
  icb "initDynamicTools called", workspaceDir, hotReload
  result = DynamicToolRegistry(
    agent: agent,
    workspaceDir: workspaceDir,
    toolsDir: workspaceDir / TOOLS_SUBDIR,
    cacheDir: workspaceDir / TOOLS_SUBDIR / CACHE_SUBDIR,
    hotReload: hotReload,
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
# Tool Discovery — extract factory proc names from source
# ----------------------------------------------------------------------------
# Instead of parsing ##@tool blocks, we look for `{.tool.}` annotated procs.
# This is a lightweight source scan — NOT a full Nim parser. It finds lines like:
#   proc FooTool*(basePath: string = "."): Tool {.tool.} =
# and extracts the proc name.
#
# For full metadata (name, description, parameters), we either:
#   a) Compile a discovery binary that calls listTools(), or
#   b) Call the factory at runtime (compiled-together mode)

type
  DiscoveredFactory* = object
    procName*: string    ## e.g. "NimCompileTool"
    lineNumber*: int

proc discoverFactories*(nimPath: string): seq[DiscoveredFactory] =
  ## Scan a Nim source file for {.tool.} annotated procs.
  ## Returns the proc names — lightweight, no compilation needed.
  let content = readFile(nimPath)
  var lineNum = 0

  for line in content.splitLines():
    lineNum.inc
    let stripped = line.strip()

    # Look for: proc Something*(...): Tool {.tool.} =
    # We need: starts with "proc", contains "{.tool.}" or "{. tool .}" etc,
    # and returns Tool
    if not stripped.startsWith("proc ") and not stripped.startsWith("func "):
      continue

    # Check for {.tool.} pragma (handles spacing variations)
    var hasPragma = false
    if "{.tool.}" in stripped or "{.tool .}" in stripped or "{. tool.}" in stripped or "{. tool .}" in stripped:
      hasPragma = true
    # Also handle multi-pragma: {.tool, async.} etc
    if not hasPragma and "{." in stripped and "tool" in stripped:
      # More careful check: find pragma section and look for "tool" as a word
      let pragmaStart = stripped.find("{.")
      let pragmaEnd = stripped.find(".}", pragmaStart)
      if pragmaStart >= 0 and pragmaEnd >= 0:
        let pragmaContent = stripped[pragmaStart+2 ..< pragmaEnd]
        for part in pragmaContent.split(","):
          if part.strip() == "tool":
            hasPragma = true
            break

    if not hasPragma:
      continue

    # Extract proc name: "proc FooTool*(" -> "FooTool"
    var rest = stripped
    if rest.startsWith("proc "): rest = rest[5..^1]
    elif rest.startsWith("func "): rest = rest[5..^1]
    rest = rest.strip()

    # Find the name (up to * or ( or : or space)
    var name = ""
    for ch in rest:
      if ch in {'*', '(', ':', ' ', '['}:
        break
      name.add ch

    if name.len > 0:
      result.add DiscoveredFactory(procName: name, lineNumber: lineNum)

# ----------------------------------------------------------------------------
# Discovery binary — compile and run to get full ToolMeta via listTools()
# ----------------------------------------------------------------------------

proc generateDiscoverySource(nimPath: string, factories: seq[DiscoveredFactory], outputPath: string) =
  ## Generate a small Nim program that imports the tool module,
  ## calls listTools(), and prints JSON metadata to stdout.
  let (_, moduleName, _) = nimPath.splitFile()

  let source = &"""
## Auto-generated tool discovery for {moduleName}
## Prints tool metadata as JSON to stdout, then exits.
import std/json
import {moduleName}

let tools = listTools()
var arr = newJArray()
for t in tools:
  arr.add(%*{{
    "name": t.name,
    "factory": t.factory,
    "strict": t.strict
  }})
stdout.write($arr)
"""
  writeFile(outputPath, source)

proc discoverViaCompilation(nimPath: string, cacheDir: string): seq[ToolMeta] =
  ## Compile and run a discovery binary to get full tool metadata.
  ## This is a fast compile (tiny program) and runs once per source file.
  let
    (toolDir, name, _) = nimPath.splitFile()
    discoveryPath = cacheDir / &"{name}_discover.nim"
    exeName = when defined(windows): name & "_discover.exe" else: name & "_discover"
    exePath = cacheDir / exeName
    nimcacheDir = cacheDir / "nimcache_discover_" & name

  createDir(nimcacheDir)

  let factories = discoverFactories(nimPath)
  if factories.len == 0:
    return @[]

  generateDiscoverySource(nimPath, factories, discoveryPath)

  let pathFlag = &"--path:{toolDir}"
  let cmd = &"nim c -d:release --gc:orc {pathFlag} --out:{exePath} --nimcache:{nimcacheDir} {discoveryPath}"

  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    icr "Discovery compilation failed", exitCode
    # Fallback: use factory proc names directly
    for f in factories:
      result.add ToolMeta(name: f.procName, factory: f.procName, strict: true)
    return

  # Run the discovery binary
  let (jsonOutput, runExit) = execCmdEx(exePath)
  if runExit != 0 or jsonOutput.strip().len == 0:
    icr "Discovery binary failed", runExit
    for f in factories:
      result.add ToolMeta(name: f.procName, factory: f.procName, strict: true)
    return

  try:
    let arr = parseJson(jsonOutput.strip())
    for item in arr:
      result.add ToolMeta(
        name: item["name"].getStr(),
        factory: item["factory"].getStr(),
        strict: item["strict"].getBool(true),
        description: item.getOrDefault("description").getStr(""),
        parameters: item.getOrDefault("parameters")
      )
  except CatchableError:
    icr "Failed to parse discovery JSON"
    for f in factories:
      result.add ToolMeta(name: f.procName, factory: f.procName, strict: true)

# ----------------------------------------------------------------------------
# Lightweight discovery (no compilation, source-scan only)
# ----------------------------------------------------------------------------

proc discoverToolsLightweight*(nimPath: string): seq[ToolMeta] =
  ## Fast path: scan source for {.tool.} procs without compiling.
  ## Gets factory names but not full metadata (name, description, params).
  ## Full metadata is available after compilation via listTools().
  let factories = discoverFactories(nimPath)
  for f in factories:
    # Derive a tool name from the factory proc name:
    # NimCompileTool -> nim_compile (strip "Tool" suffix, snake_case)
    var toolName = f.procName
    if toolName.endsWith("Tool"):
      toolName = toolName[0 ..< toolName.len - 4]

    # CamelCase to snake_case
    var snaked = ""
    for i, ch in toolName:
      if ch in {'A'..'Z'}:
        if i > 0: snaked.add '_'
        snaked.add ch.toLowerAscii()
      else:
        snaked.add ch

    result.add ToolMeta(
      name: snaked,
      factory: f.procName,
      strict: true,
      description: "",
      parameters: nil
    )

# ----------------------------------------------------------------------------
# Compilation — builds a standalone .exe dispatcher
# ----------------------------------------------------------------------------

proc generateDispatcherSource(nimPath: string, tools: seq[ToolMeta], outputPath: string) =
  ## Generate a standalone Nim program that:
  ##   1. Reads JSON from stdin: {"tool": "<name>", "args": {...}}
  ##   2. Calls the corresponding factory proc to get a Tool
  ##   3. Runs tool.handler(args)
  ##   4. Writes JSON result to stdout

  let (_, moduleName, _) = nimPath.splitFile()

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
import llmm/tools
import {moduleName}

proc dispatch(toolName: string, args: JsonNode, basePath: string): JsonNode =
  case toolName
{dispatchCases}
    else:
      result = toolError("Unknown tool in subprocess: " & toolName)

proc main() =
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

proc compileToolExe(nimPath: string, cacheDir: string, tools: seq[ToolMeta]): string =
  ## Compile a tool source file to a standalone executable.
  ## Tools metadata is passed in (no comment parsing needed).

  let
    (toolDir, name, _) = nimPath.splitFile()
    dispatcherPath = cacheDir / &"{name}_dispatch.nim"
    exeName = when defined(windows): name & ".exe" else: name
    exePath = cacheDir / exeName
    nimcacheDir = cacheDir / "nimcache_" & name

  createDir(nimcacheDir)

  if tools.len == 0:
    raise newException(ToolCompileError, &"No {{.tool.}} factories found in {nimPath}")

  generateDispatcherSource(nimPath, tools, dispatcherPath)

  let pathFlag = &"--path:{toolDir}"
  let cmd = &"nim c -d:release --gc:orc --threads:on {pathFlag} --out:{exePath} --nimcache:{nimcacheDir} {dispatcherPath}"

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
  let request = %*{
    "tool": toolName,
    "args": args,
    "basePath": basePath
  }

  let requestStr = $request

  icb "callToolSubprocess", toolName, exePath

  try:
    let process = startProcess(
      exePath,
      options = {poUsePath, poStdErrToStdOut}
    )

    let inStream = process.inputStream
    inStream.write(requestStr)
    inStream.close()

    let outStream = process.outputStream
    var responseStr = ""
    var line: string
    while outStream.readLine(line):
      responseStr.add(line)
      responseStr.add("\n")

    try:
      responseStr.add(outStream.readAll())
    except:
      discard

    let exitCode = process.waitForExit()
    process.close()

    if responseStr.strip().len == 0:
      return toolError(&"Tool subprocess returned no output (exit code: {exitCode})")

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

proc createSubprocessTool(reg: DynamicToolRegistry, nimPath: string,
                          meta: ToolMeta, allMetas: seq[ToolMeta]): Tool =
  ## Create a Tool whose handler invokes the compiled exe via subprocess IPC.

  let regRef = reg
  let nimPathRef = nimPath
  let basePath = reg.workspaceDir
  let metasRef = allMetas

  Tool(
    name: meta.name,
    description: meta.description,
    parameters: meta.parameters,
    strict: meta.strict,
    handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
      var exePath: string

      if regRef.compiledExes.hasKey(nimPathRef):
        exePath = regRef.compiledExes[nimPathRef]
      else:
        try:
          echo &"  ⚙ Compiling tool subprocess: {nimPathRef.extractFilename}..."
          exePath = compileToolExe(nimPathRef, regRef.cacheDir, metasRef)
          regRef.compiledExes[nimPathRef] = exePath
          echo &"  ✓ Compiled: {exePath.extractFilename}"
        except ToolCompileError as e:
          return toolError(&"Failed to compile tool: {e.msg}")

      if not fileExists(exePath):
        try:
          exePath = compileToolExe(nimPathRef, regRef.cacheDir, metasRef)
          regRef.compiledExes[nimPathRef] = exePath
        except ToolCompileError as e:
          return toolError(&"Failed to recompile tool: {e.msg}")

      return await callToolSubprocess(exePath, meta.name, args, basePath)
  )

# ----------------------------------------------------------------------------
# Command/HTTP wrapper tools (unchanged)
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

proc loadFromNimSource*(reg: DynamicToolRegistry, nimPath: string, 
                        fullDiscovery: bool = false): seq[string] =
  ## Load tools from a Nim source file.
  ##
  ## By default uses lightweight discovery (source scan for {.tool.} procs).
  ## Set fullDiscovery=true to compile a discovery binary for complete metadata.
  ##
  ## Either way, the actual tool handler compilation is lazy (on first call).

  icb "=== loadFromNimSource START ===", nimPath

  if not fileExists(nimPath):
    raise newException(ToolNotFoundError, &"File not found: {nimPath}")

  let sourceHash = fileHash(nimPath)

  # Check if already loaded and unchanged
  for toolName, info in reg.loaded:
    if info.sourcePath == nimPath and info.factoryHash == sourceHash:
      return @[toolName]

  # Discover tools
  let toolMetas = if fullDiscovery:
    discoverViaCompilation(nimPath, reg.cacheDir)
  else:
    discoverToolsLightweight(nimPath)

  if toolMetas.len == 0:
    icy "loadFromNimSource: no {.tool.} procs found in", nimPath
    return @[]

  # Invalidate cached exe if source changed
  if reg.compiledExes.hasKey(nimPath):
    reg.compiledExes.del(nimPath)
    ic "Invalidated cached exe for changed source", nimPath

  for meta in toolMetas:
    let metaName = meta.name
    let metaDesc = meta.description
    let metaParams = meta.parameters
    let metaStrict = meta.strict
    let metaFactory = meta.factory

    let tool = if metaFactory.len > 0:
      reg.createSubprocessTool(nimPath, meta, toolMetas)
    else:
      Tool(
        name: metaName,
        description: metaDesc,
        parameters: metaParams,
        strict: metaStrict,
        handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
          return toolError(&"Tool '{metaName}' has no factory proc.")
      )

    if not reg.agent.isNil:
      reg.agent.addTools(tool)

    reg.loaded[metaName] = LoadedTool(
      name: metaName,
      sourcePath: nimPath,
      compiledPath: "",
      loadTime: now(),
      kind: tskNimSource,
      factoryHash: sourceHash,
      isBuiltIn: false,
      factoryName: metaFactory
    )

    result.add(metaName)
    ic "Loaded tool (subprocess-backed)", metaName
# ----------------------------------------------------------------------------
# Eager compilation
# ----------------------------------------------------------------------------

proc precompileTools*(reg: DynamicToolRegistry, nimPath: string) =
  if reg.compiledExes.hasKey(nimPath):
    return
  try:
    let metas = discoverToolsLightweight(nimPath)
    let exePath = compileToolExe(nimPath, reg.cacheDir, metas)
    reg.compiledExes[nimPath] = exePath
    ic "Precompiled tool exe", exePath
  except ToolCompileError as e:
    icr "Precompilation failed (will retry on first call)", e.msg

# ----------------------------------------------------------------------------
# Tool Management Operations (unchanged)
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
# Query Operations (unchanged)
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
    if not file.extractFilename.endsWith("_dispatch.nim") and
       not file.extractFilename.endsWith("_discover.nim"):
      result.add(file)

# ----------------------------------------------------------------------------
# Tool File Creation — updated skeleton uses {.tool.} pragma
# ----------------------------------------------------------------------------

proc createToolSkeleton*(reg: DynamicToolRegistry, toolName: string): string =
  let
    safeName = toolName.replace(" ", "_").toLowerAscii()
    filePath = reg.toolsDir / &"{safeName}.nim"

  if fileExists(filePath):
    raise newException(ToolLoadError, &"Tool file already exists: {filePath}")

  let skeleton = &"""## {safeName}.nim
## Dynamic tool for LLMM
## Generated: {now()}

import std/[json, asyncdispatch, strutils, os]
import llmm/harness/tools/base
import llmm/harness/tools/tool_pragma

proc {safeName}Tool*(basePath: string = "."): Tool {{.tool.}} =
  Tool(
    name: "{toolName}",
    description: "Describe what this tool does",
    parameters: %*{{
      "type": "object",
      "properties": {{
        "arg1": {{
          "type": "string",
          "description": "First argument description"
        }}
      }},
      "required": ["arg1"]
    }},
    strict: true,
    handler: proc(args: JsonNode): Future[JsonNode] {{.async, gcsafe.}} =
      let arg1 = args["arg1"].getStr()
      ## TODO: implement
      return toolSuccess(%*{{"result": "done", "arg1": arg1}})
  )

generateToolList()
"""

  writeFile(filePath, skeleton)
  return filePath

# ----------------------------------------------------------------------------
# Auto-load at Startup (unchanged)
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