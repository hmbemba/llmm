discard """
High-Precision Code Editing Tools

Tools for making surgical edits to source files without full overwrites.
Designed for LLM agents that are bad at counting lines and writing regex.

Tools:
    - ApplyDiffTool: Search-and-replace blocks (find exact text, replace with new text)
    - InsertAtMarkerTool: Insert code at a line number or after a regex match
    - ReadFileOutlineTool: Get a structural outline of a Nim file (types, procs, imports)
    - PatchFileTool: Apply multiple search-and-replace operations in one call

Toolkits:
    - CodeEditToolkit: All code editing tools
    - CodeEditReadOnlyToolkit: Just the outline tool (safe)
"""

import
    std/os
    ,std/json
    ,std/asyncdispatch
    ,std/strformat
    ,std/strutils
    ,std/sequtils
    ,std/re
    ,std/algorithm

import
    base


# -----------------------------------------------------------------------------
# Path Resolution (same pattern as codeexec.nim)
# -----------------------------------------------------------------------------

proc resolvePath(basePath, path: string): string =
    let absBasePath = absolutePath(basePath).normalizedPath
    var cleanPath = path.replace("\\", "/")
    var normalizedBase = absBasePath.replace("\\", "/").strip(chars = {'/'})
    
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
# apply_diff: Search-and-Replace Block
# -----------------------------------------------------------------------------

proc ApplyDiffTool*(basePath: string = "."): Tool =
    ## Find an exact block of text and replace it with new text.
    ## The LLM provides the exact text to find (must match uniquely)
    ## and the replacement text. Much safer than sed or line-number edits.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "apply_diff"
        ,description: """Find an exact block of text in a file and replace it with new text.
The search text must match EXACTLY ONE location in the file (including whitespace and indentation).
This is the safest way to make surgical edits - no line numbers or regex needed.
If search_text is not found or matches multiple locations, the operation fails safely."""
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "File to edit (relative to workspace)"
                }
                ,"search_text": {
                    "type": "string"
                    ,"description": "Exact text to find (must match uniquely). Include enough context lines to be unique."
                }
                ,"replace_text": {
                    "type": "string"
                    ,"description": "Text to replace with. Use empty string to delete the matched block."
                }
            }
            ,"required": ["filename", "search_text", "replace_text"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename    = args["filename"].getStr
                searchText  = args["search_text"].getStr
                replaceText = args["replace_text"].getStr
                realPath    = resolvePath(absBasePath, filename)
            
            if not fileExists(realPath):
                return toolError(&"File not found: {filename} (resolved to: {realPath})")
            
            if searchText.len == 0:
                return toolError("search_text cannot be empty")
            
            try:
                let content = readFile(realPath)
                
                # Count occurrences
                var count = 0
                var pos = 0
                while true:
                    let found = content.find(searchText, pos)
                    if found < 0: break
                    count += 1
                    pos = found + 1
                
                if count == 0:
                    # Try to help: find partial matches
                    let firstLine = searchText.splitLines()[0].strip()
                    var hint = ""
                    if firstLine.len > 10:
                        let partialPos = content.find(firstLine)
                        if partialPos >= 0:
                            let lineNum = content[0 ..< partialPos].count('\n') + 1
                            hint = &" (first line found at line {lineNum} - check whitespace/indentation)"
                    
                    return toolError(&"search_text not found in {filename}.{hint}")
                
                if count > 1:
                    return toolError(&"search_text matches {count} locations in {filename}. Add more context lines to make it unique.")
                
                # Exactly one match - apply the replacement
                let newContent = content.replace(searchText, replaceText)
                writeFile(realPath, newContent)
                
                # Calculate what changed
                let 
                    oldLines = searchText.countLines
                    newLines = replaceText.countLines
                    totalLines = newContent.countLines
                    matchPos = content.find(searchText)
                    matchLine = content[0 ..< matchPos].count('\n') + 1
                
                echo &"  ✓ apply_diff: {filename} line {matchLine} ({oldLines} lines → {newLines} lines)"
                
                return toolSuccess(%*{
                    "filename": filename
                    ,"match_line": matchLine
                    ,"old_lines": oldLines
                    ,"new_lines": newLines
                    ,"total_lines": totalLines
                }, message = &"Replaced {oldLines} lines with {newLines} lines at line {matchLine}")
                
            except IOError as e:
                return toolError(&"Failed to read/write file: {e.msg}")
    )


# -----------------------------------------------------------------------------
# patch_file: Multiple Search-and-Replace Operations
# -----------------------------------------------------------------------------

proc PatchFileTool*(basePath: string = "."): Tool =
    ## Apply multiple search-and-replace operations to a single file.
    ## Operations are applied in order. Each must match exactly once.
    ## If any operation fails, the entire patch is rolled back.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "patch_file"
        ,description: """Apply multiple search-and-replace edits to a file in one atomic operation.
Each edit finds exact text and replaces it. Edits are applied in order.
If ANY edit fails (text not found or matches multiple times), ALL edits are rolled back.
This is ideal for making several related changes to the same file."""
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "File to edit (relative to workspace)"
                }
                ,"edits": {
                    "type": "array"
                    ,"items": {
                        "type": "object"
                        ,"properties": {
                            "search": {
                                "type": "string"
                                ,"description": "Exact text to find (must match exactly once)"
                            }
                            ,"replace": {
                                "type": "string"
                                ,"description": "Replacement text"
                            }
                        }
                        ,"required": ["search", "replace"]
                        ,"additionalProperties": false
                    }
                    ,"description": "Array of {search, replace} operations applied in order"
                }
            }
            ,"required": ["filename", "edits"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                edits    = args["edits"]
                realPath = resolvePath(absBasePath, filename)
            
            if not fileExists(realPath):
                return toolError(&"File not found: {filename} (resolved to: {realPath})")
            
            if edits.len == 0:
                return toolError("edits array is empty")
            
            try:
                let originalContent = readFile(realPath)
                var content = originalContent
                var appliedEdits: seq[JsonNode] = @[]
                
                for i in 0 ..< edits.len:
                    let
                        edit    = edits[i]
                        search  = edit["search"].getStr
                        replace = edit["replace"].getStr
                    
                    if search.len == 0:
                        # Rollback
                        writeFile(realPath, originalContent)
                        return toolError(&"Edit #{i}: search text cannot be empty. All edits rolled back.")
                    
                    let count = content.count(search)
                    
                    if count == 0:
                        writeFile(realPath, originalContent)
                        return toolError(&"Edit #{i}: search text not found. All edits rolled back.")
                    
                    if count > 1:
                        writeFile(realPath, originalContent)
                        return toolError(&"Edit #{i}: search text matches {count} locations. All edits rolled back.")
                    
                    let matchPos = content.find(search)
                    let matchLine = content[0 ..< matchPos].count('\n') + 1
                    
                    content = content.replace(search, replace)
                    appliedEdits.add(%*{
                        "edit_index": i
                        ,"match_line": matchLine
                        ,"old_lines": search.countLines
                        ,"new_lines": replace.countLines
                    })
                
                # All edits succeeded - write the result
                writeFile(realPath, content)
                
                echo &"  ✓ patch_file: {filename} ({edits.len} edits applied)"
                
                return toolSuccess(%*{
                    "filename": filename
                    ,"edits_applied": edits.len
                    ,"details": %appliedEdits
                    ,"total_lines": content.countLines
                }, message = &"Applied {edits.len} edits to {filename}")
                
            except IOError as e:
                return toolError(&"Failed to read/write file: {e.msg}")
    )


# -----------------------------------------------------------------------------
# insert_at_marker: Insert Code at Line or Regex Match
# -----------------------------------------------------------------------------

proc InsertAtMarkerTool*(basePath: string = "."): Tool =
    ## Insert text at a specific location: line number, or after/before a regex match.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "insert_at_marker"
        ,description: """Insert text at a specific location in a file.
Modes:
  - "line": Insert at a specific line number (1-indexed). Text is inserted BEFORE the line.
  - "after_match": Insert AFTER the first line matching a regex pattern.
  - "before_match": Insert BEFORE the first line matching a regex pattern.
  - "end": Append to end of file.
"""
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "File to edit (relative to workspace)"
                }
                ,"mode": {
                    "type": "string"
                    ,"enum": ["line", "after_match", "before_match", "end"]
                    ,"description": "Where to insert: 'line' (by number), 'after_match'/'before_match' (by regex), 'end' (append)"
                }
                ,"text": {
                    "type": "string"
                    ,"description": "Text to insert"
                }
                ,"line_number": {
                    "type": "integer"
                    ,"description": "Line number (1-indexed) for mode='line'. Inserts BEFORE this line."
                }
                ,"pattern": {
                    "type": "string"
                    ,"description": "Regex pattern for mode='after_match'/'before_match'. Matches against stripped lines."
                }
            }
            ,"required": ["filename", "mode", "text"]
            ,"additionalProperties": false
        }
        ,strict     : false  # line_number and pattern are conditionally required
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                mode     = args["mode"].getStr
                text     = args["text"].getStr
                realPath = resolvePath(absBasePath, filename)
            
            if not fileExists(realPath):
                return toolError(&"File not found: {filename} (resolved to: {realPath})")
            
            try:
                var lines = readFile(realPath).splitLines()
                var insertLine = -1  # 0-indexed position to insert BEFORE
                
                case mode
                of "line":
                    if not args.hasKey("line_number"):
                        return toolError("mode='line' requires line_number parameter")
                    let ln = args["line_number"].getInt
                    if ln < 1 or ln > lines.len + 1:
                        return toolError(&"line_number {ln} out of range (file has {lines.len} lines)")
                    insertLine = ln - 1  # Convert to 0-indexed
                
                of "after_match":
                    if not args.hasKey("pattern"):
                        return toolError("mode='after_match' requires pattern parameter")
                    let pattern = args["pattern"].getStr
                    let regex = re(pattern)
                    for i, line in lines:
                        if line.strip().match(regex):
                            insertLine = i + 1  # After the matching line
                            break
                    if insertLine < 0:
                        return toolError(&"Pattern '{pattern}' not found in {filename}")
                
                of "before_match":
                    if not args.hasKey("pattern"):
                        return toolError("mode='before_match' requires pattern parameter")
                    let pattern = args["pattern"].getStr
                    let regex = re(pattern)
                    for i, line in lines:
                        if line.strip().match(regex):
                            insertLine = i  # Before the matching line
                            break
                    if insertLine < 0:
                        return toolError(&"Pattern '{pattern}' not found in {filename}")
                
                of "end":
                    insertLine = lines.len
                
                else:
                    return toolError(&"Unknown mode: {mode}")
                
                # Insert the text
                let newLines = text.splitLines()
                var result_lines: seq[string] = @[]
                result_lines.add(lines[0 ..< insertLine])
                result_lines.add(newLines)
                if insertLine < lines.len:
                    result_lines.add(lines[insertLine ..^ 1])
                
                writeFile(realPath, result_lines.join("\n"))
                
                echo &"  ✓ insert_at_marker: {filename} at line {insertLine + 1} ({newLines.len} lines inserted)"
                
                return toolSuccess(%*{
                    "filename": filename
                    ,"inserted_at_line": insertLine + 1
                    ,"lines_inserted": newLines.len
                    ,"total_lines": result_lines.len
                    ,"mode": mode
                }, message = &"Inserted {newLines.len} lines at line {insertLine + 1}")
                
            except IOError as e:
                return toolError(&"Failed to read/write file: {e.msg}")
            except RegexError as e:
                return toolError(&"Invalid regex pattern: {e.msg}")
    )


# -----------------------------------------------------------------------------
# read_file_outline: Structural Outline (Types, Procs, Imports only)
# -----------------------------------------------------------------------------

proc ReadFileOutlineTool*(basePath: string = "."): Tool =
    ## Parse a Nim file and return only the structural outline:
    ## imports, type definitions, and proc/func/method signatures.
    ## Saves massive amounts of context vs reading the entire file.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "read_file_outline"
        ,description: """Get a structural outline of a Nim source file WITHOUT the implementation details.
Returns: imports, type definitions (with fields), and proc/func/method signatures.
This gives you the "map" of a file using ~10% of the tokens that file_read would use.
Use this FIRST to understand a file's structure before making targeted edits."""
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Nim source file to outline (e.g., 'agent.nim')"
                }
                ,"include_comments": {
                    "type": "boolean"
                    ,"description": "Include doc comments (## lines) in the outline. Default: true"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : false  # include_comments is optional
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                includeComments = if args.hasKey("include_comments"): args["include_comments"].getBool else: true
                realPath = resolvePath(absBasePath, filename)
            
            if not fileExists(realPath):
                return toolError(&"File not found: {filename} (resolved to: {realPath})")
            
            try:
                let content = readFile(realPath)
                let allLines = content.splitLines()
                var outline: seq[string] = @[]
                var lineNum = 0
                
                # Track state
                var inTypeSection = false
                var inTypeDef = false       # Inside a type's field definitions
                var inProcBody = false
                var procIndent = 0
                var inDiscard = false       # Inside discard """ block (module docstring)
                var inImportBlock = false
                var importIndent = 0
                
                const callableKeywords = ["proc", "func", "method", "iterator", 
                                          "converter", "template", "macro"]
                
                for line in allLines:
                    lineNum += 1
                    let stripped = line.strip()
                    let indent = line.len - line.strip(leading=true).len
                    
                    # --- Module docstring (discard """ ... """) ---
                    if stripped.startsWith("discard \"\"\""):
                        inDiscard = true
                        if includeComments:
                            outline.add(&"# L{lineNum}: [module docstring]")
                        continue
                    if inDiscard:
                        if stripped == "\"\"\"":
                            inDiscard = false
                        continue
                    
                    # --- Skip empty lines and regular comments in proc bodies ---
                    if inProcBody:
                        if indent <= procIndent and stripped.len > 0 and not stripped.startsWith("#"):
                            inProcBody = false
                            # Fall through to process this line
                        else:
                            continue
                    
                    # --- Import blocks ---
                    if stripped == "import" or stripped == "export" or 
                       stripped.startsWith("import ") or stripped.startsWith("export ") or
                       stripped.startsWith("from "):
                        outline.add(&"# L{lineNum}:")
                        outline.add(line)
                        if stripped == "import" or stripped == "export":
                            inImportBlock = true
                            importIndent = indent
                        continue
                    
                    if inImportBlock:
                        if indent > importIndent or stripped.len == 0 or stripped.startsWith(",") or stripped.startsWith("#"):
                            if stripped.len > 0:
                                outline.add(line)
                            continue
                        else:
                            inImportBlock = false
                            # Fall through
                    
                    # --- Type sections ---
                    if stripped == "type" or stripped == "type*":
                        inTypeSection = true
                        outline.add("")
                        outline.add(&"# L{lineNum}:")
                        outline.add(line)
                        continue
                    
                    if inTypeSection:
                        if indent == 0 and stripped.len > 0 and stripped != "type":
                            inTypeSection = false
                            inTypeDef = false
                            # Fall through
                        else:
                            # Include everything in the type section (definitions + fields)
                            if stripped.len > 0:
                                outline.add(line)
                            continue
                    
                    # --- Doc comments (## lines) ---
                    if includeComments and stripped.startsWith("##"):
                        outline.add(line)
                        continue
                    
                    # --- Callable definitions ---
                    var isCallable = false
                    for kw in callableKeywords:
                        if stripped.startsWith(kw & " ") or stripped.startsWith(kw & "*"):
                            isCallable = true
                            break
                    
                    if isCallable:
                        outline.add("")
                        outline.add(&"# L{lineNum}:")
                        
                        # Collect the full signature (may span multiple lines until = or {.)
                        var sig = line
                        var sigLineNum = lineNum
                        var j = lineNum  # index into allLines (0-based would be lineNum-1)
                        
                        # Check if signature continues on next lines
                        while j < allLines.len:
                            let nextLine = allLines[j]
                            let nextStripped = nextLine.strip()
                            
                            # Signature ends with = (body start) or is empty
                            if sig.strip().endsWith("="):
                                break
                            if j > lineNum - 1 and (nextStripped.len == 0 or 
                                (nextLine.len - nextLine.strip(leading=true).len == 0 and 
                                 not nextStripped.startsWith("(") and
                                 not nextStripped.startsWith(")") and
                                 not nextStripped.startsWith(",") and
                                 not nextStripped.startsWith(":"))):
                                break
                            
                            if j > lineNum - 1:  # Don't add the first line twice
                                sig.add("\n" & nextLine)
                            j += 1
                        
                        # Clean up: remove trailing = and body
                        var sigLines = sig.splitLines()
                        var cleanSig: seq[string] = @[]
                        for sl in sigLines:
                            var s = sl
                            # If line ends with " =", remove the " ="
                            if s.strip().endsWith(" ="):
                                s = s[0 ..< s.rfind(" =")]
                            elif s.strip() == "=":
                                continue
                            cleanSig.add(s)
                        
                        for s in cleanSig:
                            outline.add(s)
                        
                        # Mark that we're in a proc body to skip implementation
                        inProcBody = true
                        procIndent = indent
                        continue
                    
                    # --- Constants and lets at module level ---
                    if indent == 0 and (stripped.startsWith("const") or stripped.startsWith("let ") or 
                                        stripped.startsWith("var ") or stripped.startsWith("let") or
                                        stripped.startsWith("var")):
                        outline.add("")
                        outline.add(&"# L{lineNum}:")
                        outline.add(line)
                        # Include the block if it's a const/let/var section
                        if stripped == "const" or stripped == "let" or stripped == "var":
                            # Next indented lines are part of this section
                            var k = lineNum  # 0-based: lineNum is current (1-based), so next is lineNum (0-based)
                            while k < allLines.len:
                                let nextLine = allLines[k]
                                let nextIndent = nextLine.len - nextLine.strip(leading=true).len
                                let nextStripped = nextLine.strip()
                                if nextIndent == 0 and nextStripped.len > 0:
                                    break
                                if nextStripped.len > 0:
                                    outline.add(nextLine)
                                k += 1
                        continue
                
                # Build the outline text
                let outlineText = outline.join("\n")
                let compressionRatio = if content.len > 0: 
                    (outlineText.len.float / content.len.float * 100).int 
                else: 0
                
                echo &"  ✓ read_file_outline: {filename} ({allLines.len} lines → {outline.len} outline lines, {compressionRatio}% of original)"
                
                return toolSuccess(%*{
                    "filename": filename
                    ,"path": realPath
                    ,"outline": outlineText
                    ,"original_lines": allLines.len
                    ,"outline_lines": outline.len
                    ,"compression_pct": compressionRatio
                })
                
            except IOError as e:
                return toolError(&"Failed to read file: {e.msg}")
    )


# -----------------------------------------------------------------------------
# Toolkits
# -----------------------------------------------------------------------------

proc CodeEditToolkit*(basePath: string = "."): Toolkit =
    ## All code editing tools: apply_diff, patch_file, insert_at_marker, read_file_outline
    result = newToolkit("code_edit", "High-precision code editing tools")
    result.add ApplyDiffTool(basePath)
    result.add PatchFileTool(basePath)
    result.add InsertAtMarkerTool(basePath)
    result.add ReadFileOutlineTool(basePath)


proc CodeEditReadOnlyToolkit*(basePath: string = "."): Toolkit =
    ## Just the outline tool (safe, read-only)
    result = newToolkit("code_edit_readonly", "Code structure analysis (read-only)")
    result.add ReadFileOutlineTool(basePath)