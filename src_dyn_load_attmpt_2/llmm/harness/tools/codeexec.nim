## Code execution tools for compiling and running Nim code.
## Uses absolute paths and avoids working directory issues.
##
## Tools:
##   - NimCompileTool: Compile a Nim file
##   - NimRunTool: Compile and run a Nim file
##   - NimCheckTool: Check syntax without compiling
##   - NimTestTool: Discover and run tests
##   - NimListTypesTool: List type definitions
##   - NimListImportsTool: List imports/exports
##   - NimListProcsTool: List proc signatures
##   - ShellExecTool: Run arbitrary shell commands
##   - ReadErrorsTool: Parse Nim compilation errors
##
## Toolkits:
##   - NimDevToolkit: Full Nim development tools
##   - NimRunOnlyToolkit: Just run capability (safer)
##   - CodeExecToolkit: Everything including shell
##
## Note on strict mode:
##   OpenAI's strict mode requires ALL properties to be in "required" array.
##   Tools with optional parameters must use strict=false.

import
    std/os
    ,std/json
    ,std/asyncdispatch
    ,std/strformat
    ,std/strutils
    ,std/osproc
    ,std/times
    ,std/sequtils
    ,std/streams

import
    base
    ,tool_pragma


# -----------------------------------------------------------------------------
# Path Resolution (sandboxed to basePath)
# -----------------------------------------------------------------------------

proc resolvePath(basePath, path: string): string =
    let absBasePath = absolutePath(basePath).normalizedPath

    var cleanPath = path.replace("\\", "/")
    var normalizedBase = absBasePath.replace("\\", "/")

    normalizedBase = normalizedBase.strip(chars = {'/'})

    if cleanPath.startsWith("./"):
        cleanPath = cleanPath[2..^1]

    when defined(windows):
        let isAbsolute = cleanPath.len >= 2 and cleanPath[1] == ':'
    else:
        let isAbsolute = cleanPath.len > 0 and cleanPath[0] == '/'

    if isAbsolute:
        result = cleanPath.normalizedPath
    else:
        let relBase = basePath.replace("\\", "/").strip(chars = {'/'})
        if cleanPath.startsWith(relBase & "/"):
            cleanPath = cleanPath[(relBase.len + 1)..^1]
        elif cleanPath.startsWith(normalizedBase & "/"):
            cleanPath = cleanPath[(normalizedBase.len + 1)..^1]

        while cleanPath.len > 0 and cleanPath[0] in {'/', '\\'}:
            cleanPath = cleanPath[1..^1]
        cleanPath = cleanPath.replace("..", "")

        result = (absBasePath / cleanPath).normalizedPath


# -----------------------------------------------------------------------------
# Execution Helpers
# -----------------------------------------------------------------------------

type
    ExecResult* = object
        exitCode*   : int
        stdout*     : string
        stderr*     : string
        duration*   : float  # seconds
        command*    : string

proc max_len(str: string, max_len: int): string =
    if str.len >= max_len:
        return str[0..max_len-1]
    return str


proc runCommand(cmd: string, workDir: string = "", timeout: int = 60): ExecResult =
    let startTime = epochTime()
    result.command = cmd

    let effectiveWorkDir =
        if workDir.len > 0:
            absolutePath(workDir).normalizedPath
        else:
            getCurrentDir()

    try:
        let process = startProcess(
            cmd,
            workingDir = effectiveWorkDir,
            options = {poUsePath, poStdErrToStdOut, poEvalCommand}
        )
        result.stdout = process.outputStream.readAll()
        result.exitCode = process.waitForExit()
        process.close()
    except OSError as e:
        result.exitCode = -1
        result.stderr = &"Failed to execute: {e.msg}"
    except Exception as e:
        result.exitCode = -1
        result.stderr = &"Error: {e.msg}"

    result.duration = epochTime() - startTime


proc runCommandInDir(cmd: string, workDir: string): ExecResult =
    let startTime = epochTime()
    let absWorkDir = absolutePath(workDir).normalizedPath

    when defined(windows):
        let fullCmd = &"cmd /c \"cd /d \"{absWorkDir}\" && {cmd}\""
    else:
        let fullCmd = &"cd \"{absWorkDir}\" && {cmd}"

    result.command = fullCmd

    try:
        let (output, exitCode) = execCmdEx(fullCmd)
        result.stdout = output
        result.exitCode = exitCode
    except OSError as e:
        result.exitCode = -1
        result.stderr = &"Failed to execute: {e.msg}"
    except Exception as e:
        result.exitCode = -1
        result.stderr = &"Error: {e.msg}"

    result.duration = epochTime() - startTime


proc toJson(r: ExecResult): JsonNode =
    %*{
        "exitCode": r.exitCode
        ,"stdout": r.stdout
        ,"stderr": r.stderr
        ,"duration_seconds": r.duration
        ,"command": r.command
        ,"success": r.exitCode == 0
    }


# =============================================================================
# Nim Tools
# =============================================================================

proc NimCompileTool*(basePath: string = ".", nimFlags: seq[string] = @[]): Tool {.tool.} =
    ## Compile a Nim file without running it.
    let defaultFlags = nimFlags
    let absBasePath = absolutePath(basePath).normalizedPath

    Tool(
        name        : "nim_compile"
        ,description: "Compile a Nim source file. Returns compilation output and any errors."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to compile (e.g., 'poc01.nim')"
                }
                ,"flags": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Additional compiler flags (e.g., ['-d:release', '--threads:on'])"
                }
                ,"backend": {
                    "type": "string"
                    ,"enum": ["c", "cpp", "js"]
                    ,"description": "Compilation backend (default: c)"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : false
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(absBasePath, filename)
                backend  = if args.hasKey("backend"): args["backend"].getStr else: "c"

            if not fileExists(realPath):
                return toolError(&"Source file not found: {filename} (resolved to: {realPath})")

            var flags = defaultFlags
            if args.hasKey("flags"):
                for f in args["flags"]:
                    flags.add(f.getStr)

            let flagStr = flags.join(" ")
            let cmd = &"nim {backend} {flagStr} \"{realPath}\""

            let result = runCommandInDir(cmd, absBasePath)

            var output = result.toJson
            output["filename"] = %filename
            output["path"] = %realPath
            return output
    )


proc NimRunTool*(basePath: string = ".", nimFlags: seq[string] = @[]): Tool {.tool.} =
    ## Compile and run a Nim file.
    let defaultFlags = nimFlags
    let absBasePath = absolutePath(basePath).normalizedPath

    Tool(
        name        : "nim_run"
        ,description: "Compile and run a Nim source file. Provide just the filename, NOT the full path."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to run (e.g., 'poc01.nim')"
                }
                ,"flags": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Additional compiler flags (e.g., ['-d:release', '--threads:on'])"
                }
                ,"args": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Arguments to pass to the program"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : false
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(absBasePath, filename)

            if not fileExists(realPath):
                return toolError(&"Source file not found: {filename} (resolved to: {realPath})")

            var flags = defaultFlags
            if args.hasKey("flags"):
                for f in args["flags"]:
                    flags.add(f.getStr)

            var programArgs = ""
            if args.hasKey("args"):
                let argList = args["args"].mapIt(it.getStr)
                programArgs = " -- " & argList.join(" ")

            let flagStr = flags.join(" ")
            let cmd = &"nim r {flagStr} \"{realPath}\"{programArgs}"

            let result = runCommandInDir(cmd, absBasePath)

            var output = result.toJson
            output["filename"] = %filename
            output["path"] = %realPath
            return output
    )


proc NimCheckTool*(basePath: string = "."): Tool {.tool.} =
    ## Check Nim file syntax without compiling.
    let absBasePath = absolutePath(basePath).normalizedPath

    Tool(
        name        : "nim_check"
        ,description: "Check a Nim source file for syntax errors without compiling."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to check"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(absBasePath, filename)

            if not fileExists(realPath):
                return toolError(&"Source file not found: {filename} (resolved to: {realPath})")

            let cmd = &"nim check \"{realPath}\""
            let result = runCommandInDir(cmd, absBasePath)

            var output = result.toJson
            output["filename"] = %filename
            return output
    )


proc NimTestTool*(basePath: string = ".", nimFlags: seq[string] = @[]): Tool {.tool.} =
    ## Run Nim tests (files matching test_*.nim or *_test.nim).
    let defaultFlags = nimFlags
    let absBasePath = absolutePath(basePath).normalizedPath

    Tool(
        name        : "nim_test"
        ,description: "Run a Nim test file or discover and run all tests. If no filename given, finds and runs all test_*.nim and *_test.nim files."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Specific test file to run (optional - runs all if omitted)"
                }
                ,"flags": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Additional compiler flags"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : false
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            var flags = defaultFlags
            if args.hasKey("flags"):
                for f in args["flags"]:
                    flags.add(f.getStr)

            let flagStr = flags.join(" ")

            if args.hasKey("filename") and args["filename"].getStr.len > 0:
                let filename = args["filename"].getStr
                let realPath = resolvePath(absBasePath, filename)

                if not fileExists(realPath):
                    return toolError(&"Test file not found: {filename} (resolved to: {realPath})")

                let cmd = &"nim r {flagStr} \"{realPath}\""
                let result = runCommandInDir(cmd, absBasePath)
                var output = result.toJson
                output["filename"] = %filename
                return output
            else:
                var testFiles: seq[string] = @[]
                if dirExists(absBasePath):
                    for path in walkDirRec(absBasePath):
                        let name = extractFilename(path)
                        if name.endsWith(".nim") and (name.startsWith("test_") or name.endsWith("_test.nim")):
                            testFiles.add(path)

                if testFiles.len == 0:
                    return toolSuccess(%*{"tests_found": 0}, "No test files found")

                var results: seq[JsonNode] = @[]
                var passed = 0
                var failed = 0

                for testFile in testFiles:
                    let cmd = &"nim r {flagStr} \"{testFile}\""
                    let result = runCommandInDir(cmd, absBasePath)

                    if result.exitCode == 0: passed += 1
                    else: failed += 1

                    results.add(%*{
                        "file": testFile
                        ,"passed": result.exitCode == 0
                        ,"output": result.stdout
                    })

                return toolSuccess(%*{
                    "tests_found": testFiles.len
                    ,"passed": passed
                    ,"failed": failed
                    ,"results": results
                })
    )


# =============================================================================
# Nim Source Analysis Tools
# =============================================================================

proc NimListTypesTool*(basePath: string = "."): Tool {.tool.} =
    ## List type definitions in a Nim source file.
    let absBasePath = absolutePath(basePath).normalizedPath

    Tool(
        name        : "nim_list_types"
        ,description: "List all type definitions in a Nim source file. Returns type names with line numbers."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to analyze (e.g., 'agent.nim')"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(absBasePath, filename)

            if not fileExists(realPath):
                return toolError(&"Source file not found: {filename} (resolved to: {realPath})")

            var types: seq[JsonNode] = @[]
            var lineNum = 0

            try:
                let content = readFile(realPath)
                var inTypeSection = false
                var currentType = ""
                var startLine = 0
                var braceDepth = 0

                for line in content.splitLines():
                    lineNum += 1
                    let stripped = line.strip()

                    if stripped == "type":
                        inTypeSection = true
                        continue

                    if inTypeSection and stripped.len > 0 and not stripped.startsWith("#"):
                        let indent = line.len - line.strip(leading=true).len
                        if indent == 0 and not (stripped.startsWith("type ") or stripped == "type"):
                            if not (stripped.contains("=") and not stripped.startsWith("import") and
                                   not stripped.startsWith("export") and not stripped.startsWith("from")):
                                inTypeSection = false
                                continue

                    if inTypeSection:
                        let isTypeDef = stripped.len > 0 and
                                       not stripped.startsWith("#") and
                                       (stripped.contains("=") or stripped.contains("{.") or
                                        (stripped[0] in {'A'..'Z', 'a'..'z', '_'} and
                                         not stripped.startsWith("proc ") and
                                         not stripped.startsWith("func ") and
                                         not stripped.startsWith("method ") and
                                         not stripped.startsWith("iterator ") and
                                         not stripped.startsWith("converter ") and
                                         not stripped.startsWith("template ") and
                                         not stripped.startsWith("macro ")))

                        if isTypeDef:
                            if currentType.len > 0:
                                types.add(%*{"line": startLine, "definition": currentType.strip()})

                            currentType = line
                            startLine = lineNum

                            braceDepth = 0
                            for c in stripped:
                                if c == '{': braceDepth += 1
                                elif c == '}': braceDepth -= 1

                            if stripped.endsWith("object") or stripped.endsWith("enum") or
                               stripped.endsWith("tuple") or stripped.endsWith("ref object") or
                               stripped.endsWith("ptr object") or stripped.endsWith("distinct") or
                               (not stripped.contains("{") and not stripped.contains("(")) or
                               (braceDepth == 0 and (stripped.endsWith("}") or stripped.endsWith(")"))):
                                types.add(%*{"line": startLine, "definition": currentType.strip()})
                                currentType = ""

                        elif currentType.len > 0:
                            currentType.add("\n" & line)
                            for c in stripped:
                                if c == '{': braceDepth += 1
                                elif c == '}': braceDepth -= 1

                            if stripped == "" or (braceDepth <= 0 and stripped.endsWith("}")) or
                               (not stripped.startsWith(" ") and not stripped.startsWith("\t") and not stripped.startsWith("#")):
                                types.add(%*{"line": startLine, "definition": currentType.strip()})
                                currentType = ""
                                braceDepth = 0

                if currentType.len > 0:
                    types.add(%*{"line": startLine, "definition": currentType.strip()})

                return toolSuccess(%*{
                    "filename": filename, "path": realPath,
                    "types": types, "count": types.len
                })
            except IOError as e:
                return toolError(&"Failed to read file: {e.msg}")
    )


proc NimListImportsTool*(basePath: string = "."): Tool {.tool.} =
    ## List imports and exports in a Nim source file.
    let absBasePath = absolutePath(basePath).normalizedPath

    Tool(
        name        : "nim_list_imports"
        ,description: "List all import, export, and from/import statements in a Nim source file with line numbers."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to analyze (e.g., 'types.nim')"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(absBasePath, filename)

            if not fileExists(realPath):
                return toolError(&"Source file not found: {filename} (resolved to: {realPath})")

            var imports: seq[JsonNode] = @[]
            var exports: seq[JsonNode] = @[]
            var fromImports: seq[JsonNode] = @[]
            var lineNum = 0

            try:
                let content = readFile(realPath)
                var inImportBlock = false
                var inExportBlock = false
                var blockStartLine = 0
                var blockKind = ""
                var bracketPrefix = ""

                for line in content.splitLines():
                    lineNum += 1
                    let stripped = line.strip()

                    if stripped.len == 0 or stripped.startsWith("#"):
                        if not inImportBlock and not inExportBlock:
                            continue

                    if stripped == "import":
                        inImportBlock = true
                        blockStartLine = lineNum
                        blockKind = "import"
                        continue
                    elif stripped == "export":
                        inExportBlock = true
                        blockStartLine = lineNum
                        blockKind = "export"
                        continue

                    if stripped.startsWith("from "):
                        let parts = stripped.split(" import ")
                        if parts.len >= 2:
                            fromImports.add(%*{
                                "line": lineNum,
                                "module": parts[0][5..^1].strip(),
                                "symbols": parts[1..^1].join(" import ").split(",").mapIt(it.strip())
                            })
                        else:
                            fromImports.add(%*{"line": lineNum, "statement": stripped})
                        continue

                    if stripped.startsWith("import "):
                        let rest = stripped[7..^1]

                        let bracketIdx = rest.find("/[")
                        if bracketIdx >= 0:
                            let prefix = rest[0..<bracketIdx] & "/"
                            var bracketContent = rest[(bracketIdx+2)..^1]

                            let closeIdx = bracketContent.find("]")
                            if closeIdx >= 0:
                                bracketContent = bracketContent[0..<closeIdx]
                                let modules = bracketContent.split(",").mapIt(it.strip())
                                for modd in modules:
                                    if modd.len > 0:
                                        imports.add(%*{
                                            "line": lineNum,
                                            "module": prefix & "/" & modd,
                                            "statement": stripped
                                        })
                            else:
                                inImportBlock = true
                                blockStartLine = lineNum
                                blockKind = "import_bracket"
                                bracketPrefix = prefix
                                let modules = bracketContent.split(",").mapIt(it.strip())
                                for modd in modules:
                                    if modd.len > 0:
                                        imports.add(%*{
                                            "line": lineNum,
                                            "module": prefix & modd,
                                            "statement": stripped,
                                            "block_start": blockStartLine
                                        })
                            continue
                        else:
                            let modules = rest.split(",").mapIt(it.strip())
                            for modd in modules:
                                if modd.len > 0:
                                    imports.add(%*{
                                        "line": lineNum, "module": modd, "statement": stripped
                                    })
                        continue

                    if stripped.startsWith("export "):
                        let rest = stripped[7..^1]
                        let modules = rest.split(",").mapIt(it.strip())
                        for modd in modules:
                            if modd.len > 0:
                                exports.add(%*{
                                    "line": lineNum, "module": modd, "statement": stripped
                                })
                        continue

                    if inImportBlock:
                        if blockKind == "import_bracket":
                            let closeIdx = stripped.find("]")
                            var content = stripped
                            if closeIdx >= 0:
                                content = stripped[0..<closeIdx]
                                inImportBlock = false
                                bracketPrefix = ""

                            if content.len > 0 and not content.startsWith("#"):
                                let modules = content.split(",").mapIt(it.strip())
                                for modd in modules:
                                    if modd.len > 0:
                                        imports.add(%*{
                                            "line": lineNum,
                                            "module": bracketPrefix & modd,
                                            "statement": "import " & bracketPrefix & "[...]",
                                            "block_start": blockStartLine
                                        })
                        else:
                            let indent = line.len - line.strip(leading=true).len
                            if indent > 0 or stripped.len == 0 or stripped.startsWith("#"):
                                if stripped.len > 0 and not stripped.startsWith("#"):
                                    let modules = stripped.split(",").mapIt(it.strip())
                                    for modd in modules:
                                        if modd.len > 0:
                                            imports.add(%*{
                                                "line": lineNum, "module": modd,
                                                "statement": "import " & modd,
                                                "block_start": blockStartLine
                                            })
                            else:
                                inImportBlock = false
                                lineNum -= 1
                                continue

                    if inExportBlock:
                        let indent = line.len - line.strip(leading=true).len
                        if indent > 0 or stripped.len == 0 or stripped.startsWith("#"):
                            if stripped.len > 0 and not stripped.startsWith("#"):
                                let modules = stripped.split(",").mapIt(it.strip())
                                for modd in modules:
                                    if modd.len > 0:
                                        exports.add(%*{
                                            "line": lineNum, "module": modd,
                                            "statement": "export " & modd,
                                            "block_start": blockStartLine
                                        })
                        else:
                            inExportBlock = false
                            lineNum -= 1
                            continue

                return toolSuccess(%*{
                    "filename": filename, "path": realPath,
                    "imports": imports, "exports": exports,
                    "from_imports": fromImports,
                    "total": imports.len + exports.len + fromImports.len
                })
            except IOError as e:
                return toolError(&"Failed to read file: {e.msg}")
    )


proc NimListProcsTool*(basePath: string = "."): Tool {.tool.} =
    ## List proc signatures in a Nim source file.
    let absBasePath = absolutePath(basePath).normalizedPath

    Tool(
        name        : "nim_list_procs"
        ,description: "List all proc/func/method signatures in a Nim source file. Returns proc names with line numbers."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to analyze (e.g., 'agent.nim')"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(absBasePath, filename)

            if not fileExists(realPath):
                return toolError(&"Source file not found: {filename} (resolved to: {realPath})")

            var procs: seq[JsonNode] = @[]
            var lineNum = 0

            try:
                let content = readFile(realPath)
                var inMultiLine = false
                var currentProc = ""
                var startLine = 0

                const callableKeywords = ["proc", "func", "method", "iterator", "converter", "template", "macro"]

                for line in content.splitLines():
                    lineNum += 1
                    let stripped = line.strip()

                    var isCallableStart = false
                    for kw in callableKeywords:
                        if stripped.startsWith(kw & " "):
                            isCallableStart = true
                            break

                    if isCallableStart and not inMultiLine:
                        inMultiLine = true
                        currentProc = line
                        startLine = lineNum

                        if stripped.endsWith("=") or " = " in stripped:
                            inMultiLine = false
                            procs.add(%*{"line": startLine, "signature": currentProc.strip()})
                            currentProc = ""

                    elif inMultiLine:
                        currentProc.add("\n" & line)
                        if stripped.endsWith("=") or stripped == "" or
                           (stripped.len > 0 and stripped[0] notin {' ', '\t'}):
                            inMultiLine = false
                            procs.add(%*{"line": startLine, "signature": currentProc.strip()})
                            currentProc = ""

                if inMultiLine and currentProc.len > 0:
                    procs.add(%*{"line": startLine, "signature": currentProc.strip()})

                return toolSuccess(%*{
                    "filename": filename, "path": realPath,
                    "procedures": procs, "count": procs.len
                })
            except IOError as e:
                return toolError(&"Failed to read file: {e.msg}")
    )


# =============================================================================
# Shell/Process Tools
# =============================================================================

proc ShellExecTool*(basePath: string = ".", allowedCommands: seq[string] = @[]): Tool {.tool.} =
    ## Execute shell commands (optionally restricted).
    let
        allowed     = allowedCommands
        absBasePath = absolutePath(basePath).normalizedPath

    Tool(
        name        : "shell_exec"
        ,description: "Execute a shell command in the workspace."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "command": {
                    "type": "string"
                    ,"description": "Shell command to execute"
                }
            }
            ,"required": ["command"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let cmd = args["command"].getStr

            if allowed.len > 0:
                var isAllowed = false
                for pattern in allowed:
                    if cmd.startsWith(pattern):
                        isAllowed = true
                        break
                if not isAllowed:
                    return toolError(&"Command not allowed. Permitted: {allowed.join(\", \")}")

            let result = runCommandInDir(cmd, absBasePath)
            return result.toJson
    )


proc ReadErrorsTool*(basePath: string = "."): Tool {.tool.} =
    ## Parse and summarize Nim compilation errors.
    Tool(
        name        : "read_errors"
        ,description: "Parse Nim compilation errors and provide structured analysis."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "error_output": {
                    "type": "string"
                    ,"description": "The raw error output from compilation"
                }
            }
            ,"required": ["error_output"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let errorOutput = args["error_output"].getStr

            var errors: seq[JsonNode] = @[]
            var warnings: seq[JsonNode] = @[]
            var hints: seq[JsonNode] = @[]

            for line in errorOutput.splitLines:
                let trimmed = line.strip
                if trimmed.len == 0: continue

                if "Error:" in trimmed:
                    var parts = trimmed.split("Error:")
                    errors.add(%*{
                        "location": parts[0].strip
                        ,"message": if parts.len > 1: parts[1].strip else: ""
                        ,"raw": trimmed
                    })
                elif "Warning:" in trimmed:
                    var parts = trimmed.split("Warning:")
                    warnings.add(%*{
                        "location": parts[0].strip
                        ,"message": if parts.len > 1: parts[1].strip else: ""
                    })
                elif "Hint:" in trimmed:
                    var parts = trimmed.split("Hint:")
                    hints.add(%*{
                        "location": parts[0].strip
                        ,"message": if parts.len > 1: parts[1].strip else: ""
                    })

            return toolSuccess(%*{
                "errors": errors, "warnings": warnings, "hints": hints,
                "error_count": errors.len, "warning_count": warnings.len,
                "hint_count": hints.len
            })
    )


# =============================================================================
# Auto-generate listTools() for this module
# =============================================================================

generateToolList()


# =============================================================================
# Toolkits (unchanged — these are just convenience bundles)
# =============================================================================

proc NimDevToolkit*(basePath: string = ".", nimFlags: seq[string] = @[]): Toolkit =
    result = newToolkit("nim_dev", "Nim compilation, execution, and debugging tools")
    result.add NimCompileTool(basePath, nimFlags)
    result.add NimRunTool(basePath, nimFlags)
    result.add NimCheckTool(basePath)
    result.add NimTestTool(basePath, nimFlags)
    result.add ReadErrorsTool(basePath)
    result.add NimListTypesTool(basePath)
    result.add NimListProcsTool(basePath)
    result.add NimListImportsTool(basePath)


proc NimRunOnlyToolkit*(basePath: string = ".", nimFlags: seq[string] = @[]): Toolkit =
    result = newToolkit("nim_run_only", "Run Nim files only")
    result.add NimRunTool(basePath, nimFlags)
    result.add NimCheckTool(basePath)


proc CodeExecToolkit*(basePath: string = ".", nimFlags: seq[string] = @[], shellAllowed: seq[string] = @[]): Toolkit =
    result = newToolkit("code_exec", "Complete code execution environment")
    result.add NimCompileTool(basePath, nimFlags)
    result.add NimRunTool(basePath, nimFlags)
    result.add NimCheckTool(basePath)
    result.add NimTestTool(basePath, nimFlags)
    result.add ReadErrorsTool(basePath)
    result.add ShellExecTool(basePath, shellAllowed)