discard """
Verification & Introspection Tools

Tools for the agent to verify its work and query the Nim compiler
for type information rather than guessing.

Tools:
    - NimSuggestQueryTool: Query nimsuggest for completions, definitions, type info
    - RunTestsTool: Run tests for a specific module and report results
    - NimDocTool: Generate and read documentation for a module
    - TypeCheckExprTool: Check the type of a Nim expression in context

Toolkits:
    - VerificationToolkit: All verification tools
    - NimIntrospectionToolkit: nimsuggest + type checking

Note: nimsuggest must be available on PATH. Install via:
    nimble install nimsuggest
    OR it comes with the Nim installation
"""

import
    std/os
    ,std/json
    ,std/asyncdispatch
    ,std/strformat
    ,std/strutils
    ,std/sequtils
    ,std/osproc
    ,std/tempfiles
    ,std/times

import
    base


# -----------------------------------------------------------------------------
# Path Resolution
# -----------------------------------------------------------------------------

proc resolvePath(basePath, path: string): string =
    let absBasePath = absolutePath(basePath).normalizedPath
    var cleanPath = path.replace("\\", "/")
    
    if cleanPath.startsWith("./"):
        cleanPath = cleanPath[2..^1]
    
    when defined(windows):
        let isAbsolute = cleanPath.len >= 2 and cleanPath[1] == ':'
    else:
        let isAbsolute = cleanPath.len > 0 and cleanPath[0] == '/'
    
    if isAbsolute:
        result = cleanPath.normalizedPath
    else:
        while cleanPath.len > 0 and cleanPath[0] in {'/', '\\'}:
            cleanPath = cleanPath[1..^1]
        cleanPath = cleanPath.replace("..", "")
        result = (absBasePath / cleanPath).normalizedPath


proc runCmd(cmd: string, workDir: string = ""): tuple[output: string, exitCode: int] =
    let effectiveDir = if workDir.len > 0: absolutePath(workDir).normalizedPath else: getCurrentDir()
    when defined(windows):
        let fullCmd = &"cmd /c \"cd /d \"{effectiveDir}\" && {cmd}\""
    else:
        let fullCmd = &"cd \"{effectiveDir}\" && {cmd}"
    try:
        result = execCmdEx(fullCmd)
    except:
        result = ("Failed to execute: " & cmd, -1)


# =============================================================================
# NimSuggest Query Tool
# =============================================================================

proc NimSuggestQueryTool*(basePath: string = "."): Tool =
    ## Query nimsuggest for IDE-like information about Nim code.
    ## This wraps nimsuggest's one-shot mode for quick queries.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "nimsuggest_query"
        ,description: """Query the Nim compiler for type information, definitions, and completions.
Use this instead of guessing what arguments a proc takes or what type something is.
Modes:
  - "def": Find the definition of a symbol (jump-to-definition)
  - "sug": Get completion suggestions at a position
  - "use": Find all usages of a symbol
  - "type": Get the type of a symbol
  - "outline": Get the file's symbol outline from the compiler"""
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to query"
                }
                ,"mode": {
                    "type": "string"
                    ,"enum": ["def", "sug", "use", "type", "outline"]
                    ,"description": "Query mode: def (definition), sug (suggestions), use (usages), type (type info), outline"
                }
                ,"line": {
                    "type": "integer"
                    ,"description": "Line number (1-indexed) of the cursor position"
                }
                ,"col": {
                    "type": "integer"
                    ,"description": "Column number (0-indexed) of the cursor position"
                }
            }
            ,"required": ["filename", "mode"]
            ,"additionalProperties": false
        }
        ,strict     : false  # line/col optional for outline mode
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                mode     = args["mode"].getStr
                realPath = resolvePath(absBasePath, filename)
            
            if not fileExists(realPath):
                return toolError(&"File not found: {filename} (resolved to: {realPath})")
            
            # For outline mode, we can use nim's --dump or a simple approach
            if mode == "outline":
                # Use nim check with --listFullPaths for a quick outline
                let cmd = &"nim check --listFullPaths --hints:off --warnings:off \"{realPath}\" 2>&1"
                let (output, _) = runCmd(cmd, absBasePath)
                
                # Also provide our own parsed outline as a fallback
                return toolSuccess(%*{
                    "filename": filename
                    ,"mode": "outline"
                    ,"compiler_output": output[0 ..< min(3000, output.len)]
                })
            
            # For other modes, we need line/col
            if not args.hasKey("line") or not args.hasKey("col"):
                return toolError(&"mode='{mode}' requires line and col parameters")
            
            let
                line = args["line"].getInt
                col  = args["col"].getInt
            
            # Try nimsuggest in one-shot mode
            # nimsuggest --stdin --v3 file.nim << "mode file.nim:line:col"
            # Fallback: use nim check + nim dump for basic info
            
            # First try: nimsuggest --terse
            let queryStr = &"{mode} \"{realPath}\":{line}:{col}"
            
            # Write a temp query file for nimsuggest stdin
            let (tmpFile, tmpPath) = createTempFile("nimsuggest_", ".query")
            tmpFile.write(queryStr)
            tmpFile.close()
            
            let cmd = &"nimsuggest --terse --maxresults:10 \"{realPath}\" < \"{tmpPath}\""
            let (output, exitCode) = runCmd(cmd, absBasePath)
            
            # Clean up temp file
            try: removeFile(tmpPath)
            except: discard
            
            if exitCode != 0 and output.len == 0:
                # Fallback: try nim check for basic error info
                let checkCmd = &"nim check --hints:on \"{realPath}\" 2>&1"
                let (checkOutput, _) = runCmd(checkCmd, absBasePath)
                
                return toolSuccess(%*{
                    "filename": filename
                    ,"mode": mode
                    ,"line": line
                    ,"col": col
                    ,"nimsuggest_available": false
                    ,"fallback_output": checkOutput[0 ..< min(2000, checkOutput.len)]
                    ,"note": "nimsuggest not available or failed. Showing nim check output instead."
                })
            
            # Parse nimsuggest output
            var results: seq[JsonNode] = @[]
            for resultLine in output.splitLines():
                let parts = resultLine.split('\t')
                if parts.len >= 3:
                    var entry = %*{
                        "kind": parts[0]
                        ,"symbol": if parts.len > 1: parts[1] else: ""
                        ,"signature": if parts.len > 2: parts[2] else: ""
                    }
                    if parts.len > 3: entry["file"] = %parts[3]
                    if parts.len > 4: entry["line"] = %parts[4]
                    if parts.len > 5: entry["col"] = %parts[5]
                    if parts.len > 6: entry["doc"] = %parts[6]
                    results.add(entry)
            
            echo &"  ✓ nimsuggest_query: {mode} {filename}:{line}:{col} → {results.len} results"
            
            return toolSuccess(%*{
                "filename": filename
                ,"mode": mode
                ,"line": line
                ,"col": col
                ,"results": %results
                ,"nimsuggest_available": true
            })
    )


# =============================================================================
# Run Tests Tool (targeted)
# =============================================================================

proc RunTestsTool*(basePath: string = ".", nimFlags: seq[string] = @[]): Tool =
    ## Run tests for a specific module, or run all tests matching a pattern.
    ## More targeted than NimTestTool - can run a specific test proc.
    let 
        defaultFlags = nimFlags
        absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "run_tests"
        ,description: """Run Nim tests with detailed output. Can run:
- A specific test file: {"filename": "tests/test_agent.nim"}
- All tests in a directory: {"directory": "tests/"}
- Tests matching a pattern: {"pattern": "test_*memory*"}
Returns stdout/stderr so you can see exactly what passed/failed."""
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Specific test file to run"
                }
                ,"directory": {
                    "type": "string"
                    ,"description": "Directory to search for test files"
                }
                ,"pattern": {
                    "type": "string"
                    ,"description": "Glob pattern for test file names (e.g., 'test_*memory*')"
                }
                ,"flags": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Additional nim compiler flags"
                }
                ,"verbose": {
                    "type": "boolean"
                    ,"description": "Show full output even for passing tests (default: false)"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : false  # All parameters are optional/conditional
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            var flags = defaultFlags
            if args.hasKey("flags"):
                for f in args["flags"]:
                    flags.add(f.getStr)
            let flagStr = flags.join(" ")
            let verbose = if args.hasKey("verbose"): args["verbose"].getBool else: false
            
            # Determine which test files to run
            var testFiles: seq[string] = @[]
            
            if args.hasKey("filename"):
                let realPath = resolvePath(absBasePath, args["filename"].getStr)
                if not fileExists(realPath):
                    return toolError(&"Test file not found: {args[\"filename\"].getStr}")
                testFiles.add(realPath)
            
            elif args.hasKey("directory") or args.hasKey("pattern"):
                let searchDir = if args.hasKey("directory"):
                    resolvePath(absBasePath, args["directory"].getStr)
                else:
                    absBasePath
                
                let pattern = if args.hasKey("pattern"): args["pattern"].getStr else: "test_*.nim"
                
                if dirExists(searchDir):
                    for path in walkDirRec(searchDir):
                        let name = extractFilename(path)
                        if name.endsWith(".nim"):
                            # Simple glob matching
                            let pat = pattern.replace("*", "")
                            if pat.len == 0 or pat in name:
                                testFiles.add(path)
            
            else:
                # Default: find all tests
                for path in walkDirRec(absBasePath):
                    let name = extractFilename(path)
                    if name.endsWith(".nim") and (name.startsWith("test_") or name.endsWith("_test.nim")):
                        testFiles.add(path)
            
            if testFiles.len == 0:
                return toolSuccess(%*{"tests_found": 0}, "No test files found")
            
            var 
                results: seq[JsonNode] = @[]
                passed = 0
                failed = 0
                totalDuration = 0.0
            
            for testFile in testFiles:
                let startTime = epochTime()
                let cmd = &"nim r {flagStr} \"{testFile}\""
                let (output, exitCode) = runCmd(cmd, absBasePath)
                let duration = epochTime() - startTime
                totalDuration += duration
                
                let relPath = testFile.relativePath(absBasePath)
                
                if exitCode == 0:
                    passed += 1
                    echo &"  ✓ PASS: {relPath} ({duration:.2f}s)"
                else:
                    failed += 1
                    echo &"  ✗ FAIL: {relPath} ({duration:.2f}s)"
                
                var entry = %*{
                    "file": relPath
                    ,"passed": exitCode == 0
                    ,"exit_code": exitCode
                    ,"duration_seconds": duration
                }
                
                # Always include output for failures, optionally for passes
                if exitCode != 0 or verbose:
                    entry["output"] = %output[0 ..< min(3000, output.len)]
                
                results.add(entry)
            
            let summary = &"{passed}/{testFiles.len} tests passed ({totalDuration:.1f}s total)"
            echo &"  → {summary}"
            
            return toolSuccess(%*{
                "summary": summary
                ,"tests_found": testFiles.len
                ,"passed": passed
                ,"failed": failed
                ,"total_duration_seconds": totalDuration
                ,"results": %results
            })
    )


# =============================================================================
# Type Check Expression Tool
# =============================================================================

proc TypeCheckExprTool*(basePath: string = "."): Tool =
    ## Check the type of a Nim expression by compiling a temporary file.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "type_check_expr"
        ,description: """Check what type a Nim expression has. Creates a temporary file that imports
the target module and uses `static: echo typeof(expr)` to get the type from the compiler.
Useful when you're not sure what type a proc returns or what a variable is."""
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "expression": {
                    "type": "string"
                    ,"description": "Nim expression to type-check (e.g., 'newAgent(...)', 'myVar')"
                }
                ,"imports": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Import statements needed (e.g., ['std/json', '../agent'])"
                }
                ,"context": {
                    "type": "string"
                    ,"description": "Additional Nim code to run before the expression (variable declarations, etc.)"
                }
            }
            ,"required": ["expression"]
            ,"additionalProperties": false
        }
        ,strict     : false
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let expr = args["expression"].getStr
            
            var code = ""
            
            # Add imports
            if args.hasKey("imports"):
                for imp in args["imports"]:
                    code.add(&"import {imp.getStr}\n")
            
            code.add("\n")
            
            # Add context
            if args.hasKey("context"):
                code.add(args["context"].getStr & "\n\n")
            
            # Add type check
            code.add(&"echo \"TYPE: \", typeof({expr})\n")
            
            # Write temp file
            let tmpPath = absBasePath / "_typecheck_tmp.nim"
            try:
                writeFile(tmpPath, code)
                
                let cmd = &"nim check \"{tmpPath}\""
                let (output, exitCode) = runCmd(cmd, absBasePath)
                
                # Clean up
                try: removeFile(tmpPath)
                except: discard
                
                # Try to extract the type from the output
                var typeInfo = ""
                for line in output.splitLines():
                    if "TYPE:" in line:
                        typeInfo = line.split("TYPE:")[^1].strip()
                        break
                
                if typeInfo.len > 0:
                    echo &"  ✓ type_check_expr: typeof({expr}) = {typeInfo}"
                    return toolSuccess(%*{
                        "expression": expr
                        ,"type": typeInfo
                    })
                else:
                    # Return compiler output for debugging
                    return toolSuccess(%*{
                        "expression": expr
                        ,"type": "unknown"
                        ,"compiler_output": output[0 ..< min(2000, output.len)]
                        ,"exit_code": exitCode
                        ,"note": "Could not determine type. Check compiler output for errors."
                    })
                
            except IOError as e:
                return toolError(&"Failed to write temp file: {e.msg}")
    )


# =============================================================================
# Nim Doc Tool
# =============================================================================

proc NimDocTool*(basePath: string = "."): Tool =
    ## Generate documentation for a Nim module.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "nim_doc"
        ,description: """Generate and read documentation for a Nim module.
Uses `nim doc` to extract all exported procs, types, and their doc comments.
Useful for understanding a module's public API without reading all the source."""
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to document"
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
                return toolError(&"File not found: {filename} (resolved to: {realPath})")
            
            # Generate JSON doc
            let outPath = absBasePath / "_doc_output.json"
            let cmd = &"nim jsondoc \"{realPath}\" --out:\"{outPath}\" 2>&1"
            let (output, exitCode) = runCmd(cmd, absBasePath)
            
            if exitCode != 0:
                # Fallback: just return nim check output
                return toolSuccess(%*{
                    "filename": filename
                    ,"doc_generated": false
                    ,"compiler_output": output[0 ..< min(2000, output.len)]
                    ,"note": "nim jsondoc failed. Check for compilation errors first."
                })
            
            # Read the generated doc
            var docContent = ""
            if fileExists(outPath):
                try:
                    docContent = readFile(outPath)
                    removeFile(outPath)
                except:
                    discard
            
            if docContent.len > 0:
                try:
                    let doc = parseJson(docContent)
                    echo &"  ✓ nim_doc: {filename}"
                    return toolSuccess(%*{
                        "filename": filename
                        ,"doc_generated": true
                        ,"documentation": doc
                    })
                except:
                    return toolSuccess(%*{
                        "filename": filename
                        ,"doc_generated": true
                        ,"raw_doc": docContent[0 ..< min(5000, docContent.len)]
                    })
            else:
                return toolSuccess(%*{
                    "filename": filename
                    ,"doc_generated": false
                    ,"note": "No documentation output generated"
                })
    )


# =============================================================================
# Toolkits
# =============================================================================

proc VerificationToolkit*(basePath: string = ".", nimFlags: seq[string] = @[]): Toolkit =
    ## All verification tools
    result = newToolkit("verification", "Code verification and testing tools")
    result.add NimSuggestQueryTool(basePath)
    result.add RunTestsTool(basePath, nimFlags)
    result.add TypeCheckExprTool(basePath)
    result.add NimDocTool(basePath)

proc NimIntrospectionToolkit*(basePath: string = "."): Toolkit =
    ## Just the compiler query tools (no test running)
    result = newToolkit("nim_introspection", "Nim compiler introspection tools")
    result.add NimSuggestQueryTool(basePath)
    result.add TypeCheckExprTool(basePath)
    result.add NimDocTool(basePath)