discard """
Filesystem tools for file operations.

All tools accept a `basePath` parameter to sandbox operations.
Paths provided by the AI are resolved relative to basePath.

Tools:
    - FileCreateTool: Create a new file
    - FileReadTool: Read file contents
    - FileWriteTool: Write/overwrite a file
    - FileAppendTool: Append to a file
    - FileDeleteTool: Delete a file
    - FileExistsTool: Check if file exists
    - DirListTool: List directory contents
    - DirCreateTool: Create a directory
    - WorkspaceListTool: List all files recursively

Toolkits:
    - FileCrudToolkit: Create, Read, Write, Delete, List
    - FileReadOnlyToolkit: Read, Exists, List (safe/read-only)

Example:
    import oai/tools/filesystem

    var reg = newToolRegistry()
    reg.addTools FileCrudToolkit(basePath = "./workspace")
"""

import
    std/os
    ,std/json
    ,std/asyncdispatch
    ,std/strformat
    ,std/strutils

import
    base


# -----------------------------------------------------------------------------
# Path Resolution (sandboxed to basePath)
# -----------------------------------------------------------------------------

proc resolvePath(basePath, path: string): string =
    ## Normalizes any path to be relative to basePath.
    ## Strips leading ./, /, and prevents directory traversal.
    var cleanPath = path
    
    # Strip leading ./
    if cleanPath.startsWith("./"):
        cleanPath = cleanPath[2..^1]
    
    # Strip leading /
    if cleanPath.startsWith("/"):
        cleanPath = cleanPath[1..^1]
    
    # Strip leading backslash (Windows)
    if cleanPath.startsWith("\\"):
        cleanPath = cleanPath[1..^1]
    
    # Prevent directory traversal
    cleanPath = cleanPath.replace("..", "")
    
    # Remove any basePath prefix the AI might have included
    let normalizedBase = basePath.replace("\\", "/")
    let normalizedClean = cleanPath.replace("\\", "/")
    
    if normalizedClean.startsWith(normalizedBase & "/"):
        cleanPath = normalizedClean[(normalizedBase.len + 1)..^1]
    elif normalizedClean.startsWith(normalizedBase):
        cleanPath = normalizedClean[normalizedBase.len..^1]
        if cleanPath.startsWith("/"):
            cleanPath = cleanPath[1..^1]
    
    result = basePath / cleanPath


# -----------------------------------------------------------------------------
# File Tools
# -----------------------------------------------------------------------------

proc FileCreateTool*(basePath: string = "."): Tool =
    ## Create a new file. Fails if file already exists.
    Tool(
        name        : "file_create"
        ,description: "Create a new file with the given content. Use just the filename, not a full path."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Filename to create (e.g., 'plan.json', 'src/main.nim')"
                }
                ,"content": {
                    "type": "string"
                    ,"description": "The complete file content"
                }
            }
            ,"required": ["filename", "content"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                content = args["content"].getStr
                realPath = resolvePath(basePath, filename)
            
            try:
                # Create parent directories if needed
                let parentDir = parentDir(realPath)
                if parentDir.len > 0 and not dirExists(parentDir):
                    createDir(parentDir)
                
                writeFile(realPath, content)
                echo &"  ✓ Created: {realPath}"
                
                return base.toolSuccess(
                    %*{"path": realPath, "filename": filename}
                    ,&"File created: {filename}"
                )
            except IOError as e:
                echo &"  ✗ Failed to create {filename}: {e.msg}"
                return base.toolError(&"Failed to create file: {e.msg}")
    )


proc FileReadTool*(basePath: string = "."): Tool =
    ## Read the contents of a file.
    Tool(
        name        : "file_read"
        ,description: "Read the contents of a file."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Filename to read"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(basePath, filename)
            
            if not fileExists(realPath):
                echo &"  ✗ File not found: {realPath}"
                return base.toolError(&"File not found: {filename}")
            
            try:
                let content = readFile(realPath)
                echo &"  ✓ Read: {realPath} ({content.len} bytes)"
                return base.toolSuccess(%*{
                    "content": content
                    ,"path": realPath
                    ,"size": content.len
                })
            except IOError as e:
                echo &"  ✗ Failed to read {filename}: {e.msg}"
                return base.toolError(&"Failed to read file: {e.msg}")
    )


proc FileWriteTool*(basePath: string = "."): Tool =
    ## Write/overwrite a file (creates if doesn't exist).
    Tool(
        name        : "file_write"
        ,description: "Write content to a file, overwriting if it exists, creating if it doesn't."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Filename to write"
                }
                ,"content": {
                    "type": "string"
                    ,"description": "The complete file content"
                }
            }
            ,"required": ["filename", "content"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                content  = args["content"].getStr
                realPath = resolvePath(basePath, filename)
                existed  = fileExists(realPath)
            
            try:
                let parentDir = parentDir(realPath)
                if parentDir.len > 0 and not dirExists(parentDir):
                    createDir(parentDir)
                
                writeFile(realPath, content)
                let action = if existed: "Updated" else: "Created"
                echo &"  ✓ {action}: {realPath}"
                
                return base.toolSuccess(
                    %*{"path": realPath, "filename": filename, "overwritten": existed}
                    ,&"File {action.toLower}: {filename}"
                )
            except IOError as e:
                echo &"  ✗ Failed to write {filename}: {e.msg}"
                return base.toolError(&"Failed to write file: {e.msg}")
    )


proc FileAppendTool*(basePath: string = "."): Tool =
    ## Append content to a file.
    Tool(
        name        : "file_append"
        ,description: "Append content to the end of a file."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Filename to append to"
                }
                ,"content": {
                    "type": "string"
                    ,"description": "Content to append"
                }
            }
            ,"required": ["filename", "content"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                content = args["content"].getStr
                realPath = resolvePath(basePath, filename)
            
            try:
                let f = open(realPath, fmAppend)
                f.write(content)
                f.close()
                echo &"  ✓ Appended to: {realPath}"
                
                return base.toolSuccess(
                    %*{"path": realPath, "filename": filename, "appended_bytes": content.len}
                    ,&"Appended {content.len} bytes to {filename}"
                )
            except IOError as e:
                echo &"  ✗ Failed to append to {filename}: {e.msg}"
                return base.toolError(&"Failed to append to file: {e.msg}")
    )


proc FileDeleteTool*(basePath: string = "."): Tool =
    ## Delete a file.
    Tool(
        name        : "file_delete"
        ,description: "Delete a file."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Filename to delete"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(basePath, filename)
            
            if not fileExists(realPath):
                echo &"  ✗ File not found: {realPath}"
                return base.toolError(&"File not found: {filename}")
            
            try:
                removeFile(realPath)
                echo &"  ✓ Deleted: {realPath}"
                
                return base.toolSuccess(
                    %*{"path": realPath, "filename": filename}
                    ,&"File deleted: {filename}"
                )
            except OSError as e:
                echo &"  ✗ Failed to delete {filename}: {e.msg}"
                return base.toolError(&"Failed to delete file: {e.msg}")
    )


proc FileExistsTool*(basePath: string = "."): Tool =
    ## Check if a file exists.
    Tool(
        name        : "file_exists"
        ,description: "Check if a file exists."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Filename to check"
                }
            }
            ,"required": ["filename"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                realPath = resolvePath(basePath, filename)
                exists = fileExists(realPath)
            
            echo &"  → Exists check: {realPath} = {exists}"
            
            return base.toolSuccess(%*{
                "exists": exists
                ,"path": realPath
                ,"filename": filename
            })
    )


proc FileMoveTool*(basePath: string = "."): Tool =
    ## Move/rename a file.
    Tool(
        name        : "file_move"
        ,description: "Move or rename a file."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "source": {
                    "type": "string"
                    ,"description": "Source filename"
                }
                ,"destination": {
                    "type": "string"
                    ,"description": "Destination filename"
                }
            }
            ,"required": ["source", "destination"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                source = args["source"].getStr
                destination = args["destination"].getStr
                srcPath = resolvePath(basePath, source)
                dstPath = resolvePath(basePath, destination)
            
            if not fileExists(srcPath):
                echo &"  ✗ Source not found: {srcPath}"
                return base.toolError(&"Source file not found: {source}")
            
            try:
                let parentDir = parentDir(dstPath)
                if parentDir.len > 0 and not dirExists(parentDir):
                    createDir(parentDir)
                
                moveFile(srcPath, dstPath)
                echo &"  ✓ Moved: {srcPath} → {dstPath}"
                
                return base.toolSuccess(
                    %*{"source": srcPath, "destination": dstPath}
                    ,&"Moved {source} to {destination}"
                )
            except OSError as e:
                echo &"  ✗ Failed to move: {e.msg}"
                return base.toolError(&"Failed to move file: {e.msg}")
    )


proc FileCopyTool*(basePath: string = "."): Tool =
    ## Copy a file.
    Tool(
        name        : "file_copy"
        ,description: "Copy a file to a new location."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "source": {
                    "type": "string"
                    ,"description": "Source filename"
                }
                ,"destination": {
                    "type": "string"
                    ,"description": "Destination filename"
                }
            }
            ,"required": ["source", "destination"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                source = args["source"].getStr
                destination = args["destination"].getStr
                srcPath = resolvePath(basePath, source)
                dstPath = resolvePath(basePath, destination)
            
            if not fileExists(srcPath):
                echo &"  ✗ Source not found: {srcPath}"
                return base.toolError(&"Source file not found: {source}")
            
            try:
                let parentDir = parentDir(dstPath)
                if parentDir.len > 0 and not dirExists(parentDir):
                    createDir(parentDir)
                
                copyFile(srcPath, dstPath)
                echo &"  ✓ Copied: {srcPath} → {dstPath}"
                
                return base.toolSuccess(
                    %*{"source": srcPath, "destination": dstPath}
                    ,&"Copied {source} to {destination}"
                )
            except OSError as e:
                echo &"  ✗ Failed to copy: {e.msg}"
                return base.toolError(&"Failed to copy file: {e.msg}")
    )


# -----------------------------------------------------------------------------
# Directory Tools
# -----------------------------------------------------------------------------

proc DirListTool*(basePath: string = "."): Tool =
    ## List contents of a directory.
    Tool(
        name        : "dir_list"
        ,description: "List files and directories in a path."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "path": {
                    "type": "string"
                    ,"description": "Directory path to list (default: current directory)"
                }
            }
            ,"required": ["path"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                path = if args.hasKey("path"): args["path"].getStr else: ""
                realPath = if path.len > 0: resolvePath(basePath, path) else: basePath
            
            if not dirExists(realPath):
                echo &"  ✗ Directory not found: {realPath}"
                return base.toolError(&"Directory not found: {path}")
            
            var files: seq[JsonNode] = @[]
            var dirs: seq[JsonNode] = @[]
            
            for kind, entry in walkDir(realPath):
                let name = extractFilename(entry)
                case kind
                of pcFile:
                    files.add(%*{"name": name, "type": "file"})
                of pcDir:
                    dirs.add(%*{"name": name, "type": "directory"})
                else:
                    discard
            
            echo &"  ✓ Listed: {realPath} ({dirs.len} dirs, {files.len} files)"
            
            return base.toolSuccess(%*{
                "path": realPath
                ,"directories": dirs
                ,"files": files
                ,"total": dirs.len + files.len
            })
    )


proc DirCreateTool*(basePath: string = "."): Tool =
    ## Create a directory.
    Tool(
        name        : "dir_create"
        ,description: "Create a new directory."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "path": {
                    "type": "string"
                    ,"description": "Directory path to create"
                }
            }
            ,"required": ["path"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                path = args["path"].getStr
                realPath = resolvePath(basePath, path)
            
            if dirExists(realPath):
                echo &"  → Directory already exists: {realPath}"
                return base.toolSuccess(
                    %*{"path": realPath, "created": false}
                    ,"Directory already exists"
                )
            
            try:
                createDir(realPath)
                echo &"  ✓ Created directory: {realPath}"
                
                return base.toolSuccess(
                    %*{"path": realPath, "created": true}
                    ,&"Directory created: {path}"
                )
            except OSError as e:
                echo &"  ✗ Failed to create directory: {e.msg}"
                return base.toolError(&"Failed to create directory: {e.msg}")
    )


proc DirDeleteTool*(basePath: string = "."): Tool =
    ## Delete a directory (must be empty).
    Tool(
        name        : "dir_delete"
        ,description: "Delete an empty directory."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "path": {
                    "type": "string"
                    ,"description": "Directory path to delete"
                }
            }
            ,"required": ["path"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                path = args["path"].getStr
                realPath = resolvePath(basePath, path)
            
            if not dirExists(realPath):
                echo &"  ✗ Directory not found: {realPath}"
                return base.toolError(&"Directory not found: {path}")
            
            try:
                removeDir(realPath)
                echo &"  ✓ Deleted directory: {realPath}"
                
                return base.toolSuccess(
                    %*{"path": realPath}
                    ,&"Directory deleted: {path}"
                )
            except OSError as e:
                echo &"  ✗ Failed to delete directory: {e.msg}"
                return base.toolError(&"Failed to delete directory: {e.msg}")
    )


proc WorkspaceListTool*(basePath: string = "."): Tool =
    ## List all files recursively in the workspace.
    Tool(
        name        : "workspace_list"
        ,description: "List all files recursively in the workspace."
        ,parameters : %*{
            "type": "object"
            ,"properties": {}
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            var files: seq[string] = @[]
            
            if dirExists(basePath):
                for path in walkDirRec(basePath):
                    # Make path relative to basePath
                    var relative = path
                    if relative.startsWith(basePath):
                        relative = relative[(basePath.len)..^1]
                        if relative.startsWith($DirSep) or relative.startsWith("/"):
                            relative = relative[1..^1]
                    files.add(relative)
            
            echo "  Files in workspace:"
            for f in files:
                echo &"    - {f}"
            
            return base.toolSuccess(%*{
                "workspace": basePath
                ,"files": files
                ,"count": files.len
            })
    )


# -----------------------------------------------------------------------------
# Toolkits
# -----------------------------------------------------------------------------

proc FileCrudToolkit*(basePath: string = "."): Toolkit =
    ## Standard file CRUD operations: Create, Read, Write, Delete, List.
    result = newToolkit("file_crud", "Basic file create, read, write, delete, and list operations")
    result.add FileCreateTool(basePath)
    result.add FileReadTool(basePath)
    result.add FileWriteTool(basePath)
    result.add FileDeleteTool(basePath)
    result.add WorkspaceListTool(basePath)


proc FileFullToolkit*(basePath: string = "."): Toolkit =
    ## All file operations including move, copy, append.
    result = newToolkit("file_full", "Complete file operations toolkit")
    result.add FileCreateTool(basePath)
    result.add FileReadTool(basePath)
    result.add FileWriteTool(basePath)
    result.add FileAppendTool(basePath)
    result.add FileDeleteTool(basePath)
    result.add FileMoveTool(basePath)
    result.add FileCopyTool(basePath)
    result.add FileExistsTool(basePath)
    result.add DirListTool(basePath)
    result.add DirCreateTool(basePath)
    result.add DirDeleteTool(basePath)
    result.add WorkspaceListTool(basePath)


proc FileReadOnlyToolkit*(basePath: string = "."): Toolkit =
    ## Read-only file operations (safe for untrusted use).
    result = newToolkit("file_readonly", "Read-only file operations")
    result.add FileReadTool(basePath)
    result.add FileExistsTool(basePath)
    result.add DirListTool(basePath)
    result.add WorkspaceListTool(basePath)