discard """
Code execution tools for compiling and running Nim code.
FIXED VERSION: Uses absolute paths and avoids working directory issues.

Tools:
    - NimCompileTool: Compile a Nim file
    - NimRunTool: Compile and run a Nim file
    - NimCheckTool: Check syntax without compiling
    - ShellExecTool: Run arbitrary shell commands
    - ProcessOutputTool: Capture and analyze process output

Toolkits:
    - NimDevToolkit: Full Nim development tools
    - NimRunOnlyToolkit: Just run capability (safer)

Note on strict mode:
    OpenAI's strict mode requires ALL properties to be in "required" array.
    Tools with optional parameters must use strict=false.


"""

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
    #debug


# -----------------------------------------------------------------------------
# Path Resolution (sandboxed to basePath)
# -----------------------------------------------------------------------------

proc resolvePath(basePath, path: string): string =
    ## Resolve a path relative to basePath, returning an ABSOLUTE path.
    ## Handles cases where the path might already include the basePath prefix.
    
    # First, get the absolute basePath
    let absBasePath = absolutePath(basePath).normalizedPath
    
    var cleanPath = path.replace("\\", "/")
    var normalizedBase = absBasePath.replace("\\", "/")
    
    # Strip trailing slashes from base
    normalizedBase = normalizedBase.strip(chars = {'/'})
    
    # Strip leading ./ from path
    if cleanPath.startsWith("./"):
        cleanPath = cleanPath[2..^1]
    
    # Check if cleanPath is already absolute
    when defined(windows):
        let isAbsolute = cleanPath.len >= 2 and cleanPath[1] == ':'
    else:
        let isAbsolute = cleanPath.len > 0 and cleanPath[0] == '/'
    
    if isAbsolute:
        # If already absolute, just normalize it
        result = cleanPath.normalizedPath
    else:
        # KEY FIX: If cleanPath already starts with basePath (or relative equivalent), strip it
        let relBase = basePath.replace("\\", "/").strip(chars = {'/'})
        if cleanPath.startsWith(relBase & "/"):
            cleanPath = cleanPath[(relBase.len + 1)..^1]
        elif cleanPath.startsWith(normalizedBase & "/"):
            cleanPath = cleanPath[(normalizedBase.len + 1)..^1]
        
        # Safety: strip leading slashes and .. traversal
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

proc max_len(str : string, max_len:int) : string = 
    if str.len >= max_len:
        let lenn = max_len - 1
        return str[0..lenn]
    return str


proc runCommand(cmd: string, workDir: string = "", timeout: int = 60): ExecResult =
    ## Run a command and capture output.
    ## FIXED: Always use absolute working directory to avoid path duplication.
    let startTime = epochTime()
    
    result.command = cmd
    
    # Determine the working directory - use absolute path
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
        
        # Simple blocking read (for now)
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
    ## Alternative: Run command by cd'ing first, then executing.
    ## This avoids osproc working directory issues entirely.
    let startTime = epochTime()
    
    let absWorkDir = absolutePath(workDir).normalizedPath
    
    when defined(windows):
        # Use cmd /c with cd && command
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


# -----------------------------------------------------------------------------
# Nim Tools
# -----------------------------------------------------------------------------

proc NimCompileTool*(basePath: string = ".", nimFlags: seq[string] = @[]): Tool =
    ## Compile a Nim file without running it.
    ## Note: strict=false because flags and backend are optional.
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
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(absBasePath, filename)
                backend  = if args.hasKey("backend"): args["backend"].getStr else: "c"
            
            if not fileExists(realPath):
                return toolError(&"Source file not found: {filename} (resolved to: {realPath})")
            
            # Build flags
            var flags = defaultFlags
            if args.hasKey("flags"):
                for f in args["flags"]:
                    flags.add(f.getStr)
            
            let flagStr = flags.join(" ")
            # Use absolute path in command
            let cmd = &"nim {backend} {flagStr} \"{realPath}\""
            
            # Run from basePath but with absolute file path
            let result = runCommandInDir(cmd, absBasePath)
            
            var output = result.toJson
            output["filename"] = %filename
            output["path"] = %realPath
            return output
    )


proc NimRunTool*(basePath: string = ".", nimFlags: seq[string] = @[]): Tool =
    ## Compile and run a Nim file.
    ## Note: strict=false because flags and args are optional.
    let defaultFlags = nimFlags
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "nim_run"
        ,description: "Nim source file to run - just the filename, NOT the full path (e.g., 'poc01.nim', NOT 'workspace/poc01.nim')"
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
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(absBasePath, filename)
            
            if not fileExists(realPath):
                return toolError(&"Source file not found: {filename} (resolved to: {realPath})")
            
            # Build flags
            var flags = defaultFlags
            if args.hasKey("flags"):
                for f in args["flags"]:
                    flags.add(f.getStr)
            
            # Build program args
            var programArgs = ""
            if args.hasKey("args"):
                let argList = args["args"].mapIt(it.getStr)
                programArgs = " -- " & argList.join(" ")
            
            let flagStr = flags.join(" ")
            # Use absolute path in command
            let cmd = &"nim r {flagStr} \"{realPath}\"{programArgs}"
            
            # Run from basePath but with absolute file path
            let result = runCommandInDir(cmd, absBasePath)
            
            var output = result.toJson
            output["filename"] = %filename
            output["path"] = %realPath
            return output
    )


proc NimCheckTool*(basePath: string = "."): Tool =
    ## Check Nim file syntax without compiling.
    ## strict=true is fine here - only required parameter.
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


proc NimTestTool*(basePath: string = ".", nimFlags: seq[string] = @[]): Tool =
    ## Run Nim tests (files matching test_*.nim or *_test.nim).
    ## Note: strict=false because all parameters are optional.
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
            # Note: NO "required" field at all, or empty array - OpenAI requires
            # strict=false when not all properties are required
        }
        ,strict     : false  # CRITICAL: Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            var flags = defaultFlags
            if args.hasKey("flags"):
                for f in args["flags"]:
                    flags.add(f.getStr)
            
            let flagStr = flags.join(" ")
            
            if args.hasKey("filename") and args["filename"].getStr.len > 0:
                # Run specific test
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
                # Discover and run all tests
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
                    
                    if result.exitCode == 0:
                        passed += 1
                    else:
                        failed += 1
                    
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



# -----------------------------------------------------------------------------
# Nim Source Analysis Tools
# -----------------------------------------------------------------------------

proc NimListTypesTool*(basePath: string = "."): Tool =
    ## List type definitions in a Nim source file using native parsing.
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
                    
                    # Check for type section start
                    if stripped == "type":
                        inTypeSection = true
                        continue
                    
                    # Check for type section end (non-indented line that's not a comment or empty)
                    if inTypeSection and stripped.len > 0 and not stripped.startsWith("#"):
                        let indent = line.len - line.strip(leading=true).len
                        if indent == 0 and not (stripped.startsWith("type ") or stripped == "type"):
                            # This might be end of type section, but could also be a one-liner
                            # Check if it's a type definition on one line
                            if not (stripped.contains("=") and not stripped.startsWith("import") and 
                                   not stripped.startsWith("export") and not stripped.startsWith("from")):
                                inTypeSection = false
                                continue
                    
                    if inTypeSection:
                        # Check if this is a new type definition (indented, followed by = or {.})
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
                            # If we were building a previous type, save it
                            if currentType.len > 0:
                                types.add(%*{
                                    "line": startLine,
                                    "definition": currentType.strip()
                                })
                            
                            currentType = line
                            startLine = lineNum
                            
                            # Check if type ends on this line (one-liner)
                            braceDepth = 0
                            for i, c in stripped:
                                if c == '{': braceDepth += 1
                                elif c == '}': braceDepth -= 1
                            
                            # Simple heuristic: if line ends with basic type or has no opening brace/paren
                            if stripped.endsWith("object") or stripped.endsWith("enum") or 
                               stripped.endsWith("tuple") or stripped.endsWith("ref object") or
                               stripped.endsWith("ptr object") or stripped.endsWith("distinct") or
                               (not stripped.contains("{") and not stripped.contains("(")) or
                               (braceDepth == 0 and (stripped.endsWith("}") or stripped.endsWith(")"))):
                                types.add(%*{
                                    "line": startLine,
                                    "definition": currentType.strip()
                                })
                                currentType = ""
                        
                        elif currentType.len > 0:
                            # Continuation of multi-line type
                            currentType.add("\n" & line)
                            
                            # Track brace depth to detect end
                            for c in stripped:
                                if c == '{': braceDepth += 1
                                elif c == '}': braceDepth -= 1
                            
                            # Check for end of type definition
                            if stripped == "" or (braceDepth <= 0 and stripped.endsWith("}")) or
                               (not stripped.startsWith(" ") and not stripped.startsWith("\t") and not stripped.startsWith("#")):
                                types.add(%*{
                                    "line": startLine,
                                    "definition": currentType.strip()
                                })
                                currentType = ""
                                braceDepth = 0
                
                # Don't forget the last type
                if currentType.len > 0:
                    types.add(%*{
                        "line": startLine,
                        "definition": currentType.strip()
                    })
                
                return toolSuccess(%*{
                    "filename": filename,
                    "path": realPath,
                    "types": types,
                    "count": types.len
                })
                
            except IOError as e:
                return toolError(&"Failed to read file: {e.msg}")
    )


proc NimListImportsTool*(basePath: string = "."): Tool =
    ## List imports and exports in a Nim source file using native parsing.
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
                var blockKind = ""  # "import", "export", or "import_bracket"
                var bracketPrefix = ""  # Stores prefix like "std/" for bracket imports
                
                for line in content.splitLines():
                    lineNum += 1
                    let stripped = line.strip()
                    
                    # Skip empty lines and comments (unless in block)
                    if stripped.len == 0 or stripped.startsWith("#"):
                        if not inImportBlock and not inExportBlock:
                            continue
                    
                    # Check for block start (import or export on their own line)
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
                    
                    # Handle from/module import syntax
                    if stripped.startsWith("from "):
                        let parts = stripped.split(" import ")
                        if parts.len >= 2:
                            fromImports.add(%*{
                                "line": lineNum,
                                "module": parts[0][5..^1].strip(),  # Remove "from "
                                "symbols": parts[1..^1].join(" import ").split(",").mapIt(it.strip())
                            })
                        else:
                            fromImports.add(%*{
                                "line": lineNum,
                                "statement": stripped
                            })
                        continue
                    
                    # Handle single-line import/export statements
                    if stripped.startsWith("import "):
                        let rest = stripped[7..^1]  # Remove "import "
                        
                        # Check for bracket syntax: import std/[...]
                        let bracketIdx = rest.find("/[")
                        if bracketIdx >= 0:
                            let prefix = rest[0..<bracketIdx] & "/"  # e.g., "std/"
                            var bracketContent = rest[(bracketIdx+2)..^1]  # After "std/["
                            
                            # Check if bracket closes on same line
                            let closeIdx = bracketContent.find("]")
                            if closeIdx >= 0:
                                # Single line bracket: import std/[foo, bar]
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
                                # Multi-line bracket: import std/[\n    foo,\n    bar\n]
                                # Start tracking the bracket content
                                inImportBlock = true
                                blockStartLine = lineNum
                                blockKind = "import_bracket"
                                bracketPrefix = prefix  # Store prefix like "std/" for later lines
                                # Process any modules on the same line as the opening bracket
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
                            # Regular comma-separated imports
                            let modules = rest.split(",").mapIt(it.strip())
                            for modd in modules:
                                if modd.len > 0:
                                    imports.add(%*{
                                        "line": lineNum,
                                        "module": modd,
                                        "statement": stripped
                                    })
                        continue
                    
                    if stripped.startsWith("export "):
                        let rest = stripped[7..^1]  # Remove "export "
                        let modules = rest.split(",").mapIt(it.strip())
                        for modd in modules:
                            if modd.len > 0:
                                exports.add(%*{
                                    "line": lineNum,
                                    "module": modd,
                                    "statement": stripped
                                })
                        continue
                    
                    # Handle multi-line import/export blocks
                    if inImportBlock:
                        if blockKind == "import_bracket":
                            # Handling multi-line bracket: import std/[\n  foo,\n  bar\n]
                            let closeIdx = stripped.find("]")
                            var content = stripped
                            if closeIdx >= 0:
                                # End of bracket
                                content = stripped[0..<closeIdx]
                                inImportBlock = false
                                bracketPrefix = ""  # Clear stored prefix
                            
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
                            # Regular multi-line import block
                            let indent = line.len - line.strip(leading=true).len
                            if indent > 0 or stripped.len == 0 or stripped.startsWith("#"):
                                if stripped.len > 0 and not stripped.startsWith("#"):
                                    # It's a module in the block
                                    let modules = stripped.split(",").mapIt(it.strip())
                                    for modd in modules:
                                        if modd.len > 0:
                                            imports.add(%*{
                                                "line": lineNum,
                                                "module": modd,
                                                "statement": "import " & modd,
                                                "block_start": blockStartLine
                                            })
                            else:
                                # Non-indented, non-empty line ends the block
                                inImportBlock = false
                                # Re-process this line as it might be something else
                                lineNum -= 1  # Hack: reprocess this line
                                continue
                    
                    if inExportBlock:
                        let indent = line.len - line.strip(leading=true).len
                        if indent > 0 or stripped.len == 0 or stripped.startsWith("#"):
                            if stripped.len > 0 and not stripped.startsWith("#"):
                                let modules = stripped.split(",").mapIt(it.strip())
                                for modd in modules:
                                    if modd.len > 0:
                                        exports.add(%*{
                                            "line": lineNum,
                                            "module": modd,
                                            "statement": "export " & modd,
                                            "block_start": blockStartLine
                                        })
                        else:
                            inExportBlock = false
                            lineNum -= 1
                            continue
                
                return toolSuccess(%*{
                    "filename": filename,
                    "path": realPath,
                    "imports": imports,
                    "exports": exports,
                    "from_imports": fromImports,
                    "total": imports.len + exports.len + fromImports.len
                })
                
            except IOError as e:
                return toolError(&"Failed to read file: {e.msg}")
    )

proc NimListProcsTool*(basePath: string = "."): Tool =
    ## List proc signatures in a Nim source file using native parsing.
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
            
            # Native Nim parsing - no shell escaping issues
            var procs: seq[JsonNode] = @[]
            var lineNum = 0
            
            try:
                let content = readFile(realPath)
                var inMultiLine = false
                var currentProc = ""
                var startLine = 0
                
                # Keywords that start a callable definition
                const callableKeywords = ["proc", "func", "method", "iterator", "converter", "template", "macro"]
                
                for line in content.splitLines():
                    lineNum += 1
                    let stripped = line.strip()
                    
                    # Check if line starts with a callable keyword
                    var isCallableStart = false
                    var keywordLen = 0
                    
                    for kw in callableKeywords:
                        if stripped.startsWith(kw & " "):
                            isCallableStart = true
                            keywordLen = kw.len
                            break
                    
                    if isCallableStart and not inMultiLine:
                        # Start of a new callable
                        inMultiLine = true
                        currentProc = line
                        startLine = lineNum
                        
                        # Check if it ends on this line
                        if stripped.endsWith("=") or " = " in stripped:
                            inMultiLine = false
                            procs.add(%*{
                                "line": startLine,
                                "signature": currentProc.strip()
                            })
                            currentProc = ""
                    
                    elif inMultiLine:
                        currentProc.add("\n" & line)
                        # Check for end of signature
                        if stripped.endsWith("=") or stripped == "" or 
                           (stripped.len > 0 and stripped[0] notin {' ', '\t'}):
                            inMultiLine = false
                            procs.add(%*{
                                "line": startLine,
                                "signature": currentProc.strip()
                            })
                            currentProc = ""
                
                # Handle case where file ends while still in a proc
                if inMultiLine and currentProc.len > 0:
                    procs.add(%*{
                        "line": startLine,
                        "signature": currentProc.strip()
                    })
                
                return toolSuccess(%*{
                    "filename": filename,
                    "path": realPath,
                    "procedures": procs,
                    "count": procs.len
                })
                
            except IOError as e:
                return toolError(&"Failed to read file: {e.msg}")
    )




# -----------------------------------------------------------------------------
# Shell/Process Tools
# -----------------------------------------------------------------------------

proc ShellExecTool*(basePath: string = ".", allowedCommands: seq[string] = @[]): Tool =
    ## Execute shell commands (optionally restricted).
    ## strict=true - only required parameter.
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
            
            # Check allowed commands if restricted
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


proc ReadErrorsTool*(basePath: string = "."): Tool =
    ## Parse and summarize compilation errors.
    ## strict=true - only required parameter.
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
                if trimmed.len == 0:
                    continue
                
                # Parse Nim error format: file(line, col) Error: message
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
                "errors": errors
                ,"warnings": warnings
                ,"hints": hints
                ,"error_count": errors.len
                ,"warning_count": warnings.len
                ,"hint_count": hints.len
            })
    )


# -----------------------------------------------------------------------------
# Toolkits
# -----------------------------------------------------------------------------

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
    ## Just run capability (safer, no arbitrary shell).
    result = newToolkit("nim_run_only", "Run Nim files only")
    result.add NimRunTool(basePath, nimFlags)
    result.add NimCheckTool(basePath)


proc CodeExecToolkit*(basePath: string = ".", nimFlags: seq[string] = @[], shellAllowed: seq[string] = @[]): Toolkit =
    ## Full code execution toolkit including shell.
    result = newToolkit("code_exec", "Complete code execution environment")
    result.add NimCompileTool(basePath, nimFlags)
    result.add NimRunTool(basePath, nimFlags)
    result.add NimCheckTool(basePath)
    result.add NimTestTool(basePath, nimFlags)
    result.add ReadErrorsTool(basePath)
    result.add ShellExecTool(basePath, shellAllowed)