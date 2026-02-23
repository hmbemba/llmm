discard """
PowerShell execution tools for running PowerShell commands and scripts.

Tools:
    - PwshExecTool: Execute a PowerShell command
    - PwshScriptTool: Execute a PowerShell script file
    - PwshScriptCreateTool: Create and execute a PowerShell script
    - PwshModuleListTool: List installed PowerShell modules
    - PwshModuleImportTool: Import a PowerShell module
    - PwshGetCommandTool: Get available commands matching a pattern
    - PwshGetProcessTool: Get running processes
    - PwshGetServiceTool: Get Windows services
    - PwshEnvVarTool: Get or set environment variables

Toolkits:
    - PwshBasicToolkit: Basic PowerShell execution (exec, script)
    - PwshFullToolkit: Full PowerShell toolkit with all tools
    - PwshReadOnlyToolkit: Read-only operations (safe for untrusted use)

Note on strict mode:
    OpenAI's strict mode requires ALL properties to be in "required" array.
    Tools with optional parameters must use strict=false.

Example:
    import oai/tools/powershelltools

    var reg = newToolRegistry()
    reg.addTools PwshBasicToolkit(basePath = "./workspace")
"""

import
    std/os
    ,std/json
    ,std/asyncdispatch
    ,std/strformat
    ,std/strutils
    ,std/osproc
    ,std/times
    ,std/streams

import
    base


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
    PwshResult* = object
        exitCode*   : int
        stdout*     : string
        stderr*     : string
        duration*   : float  # seconds
        command*    : string

proc maxLen(str: string, maxLen: int): string =
    if str.len >= maxLen:
        let lenn = maxLen - 1
        return str[0..lenn]
    return str


proc runPwshCommand(command: string, workDir: string = "", timeout: int = 60): PwshResult =
    ## Run a PowerShell command and capture output.
    let startTime = epochTime()
    
    result.command = command
    
    # Determine the working directory - use absolute path
    let effectiveWorkDir =
        if workDir.len > 0:
            absolutePath(workDir).normalizedPath
        else:
            getCurrentDir()
    
    # Build the PowerShell command
    # Use -NoProfile for faster startup, -NonInteractive for non-interactive mode
    # -ExecutionPolicy Bypass to avoid execution policy issues
    let escapedCmd = command.replace("\"", "\\\"")
    
    when defined(windows):
        let fullCmd = &"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"{escapedCmd}\""
    else:
        # On Linux/macOS, use pwsh (PowerShell Core)
        let fullCmd = &"pwsh -NoProfile -NonInteractive -Command \"{escapedCmd}\""
    
    try:
        let process = startProcess(
            fullCmd,
            workingDir = effectiveWorkDir,
            options = {poUsePath, poStdErrToStdOut, poEvalCommand}
        )
        
        # Simple blocking read
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


proc runPwshScript(scriptPath: string, args: seq[string] = @[], workDir: string = ""): PwshResult =
    ## Run a PowerShell script file and capture output.
    let startTime = epochTime()
    
    let effectiveWorkDir =
        if workDir.len > 0:
            absolutePath(workDir).normalizedPath
        else:
            getCurrentDir()
    
    # Build arguments string
    let argsStr = if args.len > 0: " " & args.join(" ") else: ""
    
    when defined(windows):
        let fullCmd = &"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{scriptPath}\"{argsStr}"
    else:
        let fullCmd = &"pwsh -NoProfile -NonInteractive -File \"{scriptPath}\"{argsStr}"
    
    result.command = fullCmd
    
    try:
        let process = startProcess(
            fullCmd,
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


proc toJson(r: PwshResult): JsonNode =
    %*{
        "exitCode": r.exitCode
        ,"stdout": r.stdout
        ,"stderr": r.stderr
        ,"duration_seconds": r.duration
        ,"command": r.command
        ,"success": r.exitCode == 0
    }


# -----------------------------------------------------------------------------
# PowerShell Tools
# -----------------------------------------------------------------------------

proc PwshExecTool*(basePath: string = "."): Tool =
    ## Execute a PowerShell command.
    ## strict=true - only required parameter.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "pwsh_exec"
        ,description: "Execute a PowerShell command and return the output."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "command": {
                    "type": "string"
                    ,"description": "PowerShell command to execute (e.g., 'Get-Process | Select-Object -First 5')"
                }
            }
            ,"required": ["command"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let command = args["command"].getStr
            
            echo &"  → PowerShell: {command}"
            let result = runPwshCommand(command, absBasePath)
            
            if result.exitCode == 0:
                echo &"  ✓ Success ({result.duration:.2f}s)"
            else:
                echo &"  ✗ Failed (exit {result.exitCode})"
            
            return result.toJson
    )


proc PwshScriptTool*(basePath: string = "."): Tool =
    ## Execute a PowerShell script file.
    ## Note: strict=false because args is optional.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "pwsh_script"
        ,description: "Execute a PowerShell script file (.ps1)."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "PowerShell script file to execute (e.g., 'script.ps1')"
                }
                ,"args": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Arguments to pass to the script"
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
                echo &"  ✗ Script not found: {realPath}"
                return toolError(&"Script file not found: {filename} (resolved to: {realPath})")
            
            var scriptArgs: seq[string] = @[]
            if args.hasKey("args"):
                for a in args["args"]:
                    scriptArgs.add(a.getStr)
            
            echo &"  → Running script: {realPath}"
            let result = runPwshScript(realPath, scriptArgs, absBasePath)
            
            if result.exitCode == 0:
                echo &"  ✓ Success ({result.duration:.2f}s)"
            else:
                echo &"  ✗ Failed (exit {result.exitCode})"
            
            var output = result.toJson
            output["filename"] = %filename
            output["path"] = %realPath
            return output
    )


proc PwshScriptCreateTool*(basePath: string = "."): Tool =
    ## Create and optionally execute a PowerShell script.
    ## Note: strict=false because execute and args are optional.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "pwsh_script_create"
        ,description: "Create a PowerShell script file and optionally execute it."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "Filename for the script (e.g., 'myscript.ps1')"
                }
                ,"content": {
                    "type": "string"
                    ,"description": "PowerShell script content"
                }
                ,"execute": {
                    "type": "boolean"
                    ,"description": "Whether to execute the script after creating it (default: false)"
                }
                ,"args": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Arguments to pass when executing"
                }
            }
            ,"required": ["filename", "content"]
            ,"additionalProperties": false
        }
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let
                filename = args["filename"].getStr
                content = args["content"].getStr
                realPath = resolvePath(absBasePath, filename)
                shouldExecute = if args.hasKey("execute"): args["execute"].getBool else: false
            
            # Create parent directories if needed
            let parentDir = parentDir(realPath)
            if parentDir.len > 0 and not dirExists(parentDir):
                createDir(parentDir)
            
            try:
                writeFile(realPath, content)
                echo &"  ✓ Created script: {realPath}"
            except IOError as e:
                echo &"  ✗ Failed to create script: {e.msg}"
                return toolError(&"Failed to create script: {e.msg}")
            
            var output = %*{
                "success": true
                ,"filename": filename
                ,"path": realPath
                ,"created": true
            }
            
            if shouldExecute:
                var scriptArgs: seq[string] = @[]
                if args.hasKey("args"):
                    for a in args["args"]:
                        scriptArgs.add(a.getStr)
                
                echo &"  → Executing script: {realPath}"
                let result = runPwshScript(realPath, scriptArgs, absBasePath)
                
                if result.exitCode == 0:
                    echo &"  ✓ Execution success ({result.duration:.2f}s)"
                else:
                    echo &"  ✗ Execution failed (exit {result.exitCode})"
                
                output["executed"] = %true
                output["execution_result"] = result.toJson
            else:
                output["executed"] = %false
            
            return output
    )


proc PwshModuleListTool*(): Tool =
    ## List installed PowerShell modules.
    ## strict=false because name filter is optional.
    Tool(
        name        : "pwsh_module_list"
        ,description: "List installed PowerShell modules."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "name": {
                    "type": "string"
                    ,"description": "Filter modules by name pattern (supports wildcards like 'Az*')"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            var cmd = "Get-Module -ListAvailable"
            if args.hasKey("name") and args["name"].getStr.len > 0:
                let nameFilter = args["name"].getStr
                cmd = &"Get-Module -ListAvailable -Name '{nameFilter}'"
            
            cmd &= " | Select-Object Name, Version, ModuleType | ConvertTo-Json"
            
            echo &"  → Listing modules"
            let result = runPwshCommand(cmd)
            
            if result.exitCode == 0:
                echo &"  ✓ Success"
                try:
                    let modules = parseJson(result.stdout)
                    return toolSuccess(%*{"modules": modules})
                except JsonParsingError:
                    # Single result or empty - return raw output
                    return toolSuccess(%*{"raw_output": result.stdout})
            else:
                echo &"  ✗ Failed"
                return result.toJson
    )


proc PwshModuleImportTool*(): Tool =
    ## Import a PowerShell module.
    ## strict=true - only required parameter.
    Tool(
        name        : "pwsh_module_import"
        ,description: "Import a PowerShell module for use."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "name": {
                    "type": "string"
                    ,"description": "Name of the module to import"
                }
            }
            ,"required": ["name"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let moduleName = args["name"].getStr
            let cmd = &"Import-Module '{moduleName}' -ErrorAction Stop; Write-Output 'Module imported successfully'"
            
            echo &"  → Importing module: {moduleName}"
            let result = runPwshCommand(cmd)
            
            if result.exitCode == 0:
                echo &"  ✓ Module imported"
                return toolSuccess(%*{"module": moduleName}, "Module imported successfully")
            else:
                echo &"  ✗ Failed to import module"
                return result.toJson
    )


proc PwshGetCommandTool*(): Tool =
    ## Get available PowerShell commands matching a pattern.
    ## strict=true - only required parameter.
    Tool(
        name        : "pwsh_get_command"
        ,description: "Get available PowerShell commands matching a pattern."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "pattern": {
                    "type": "string"
                    ,"description": "Command name pattern (supports wildcards like '*Process*')"
                }
            }
            ,"required": ["pattern"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let pattern = args["pattern"].getStr
            let cmd = &"Get-Command -Name '{pattern}' | Select-Object Name, CommandType, Source | ConvertTo-Json"
            
            echo &"  → Getting commands: {pattern}"
            let result = runPwshCommand(cmd)
            
            if result.exitCode == 0:
                echo &"  ✓ Success"
                try:
                    let commands = parseJson(result.stdout)
                    return toolSuccess(%*{"commands": commands})
                except JsonParsingError:
                    return toolSuccess(%*{"raw_output": result.stdout})
            else:
                echo &"  ✗ Failed"
                return result.toJson
    )


proc PwshGetProcessTool*(): Tool =
    ## Get running processes.
    ## strict=false because name filter is optional.
    Tool(
        name        : "pwsh_get_process"
        ,description: "Get running processes, optionally filtered by name."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "name": {
                    "type": "string"
                    ,"description": "Process name to filter (supports wildcards)"
                }
                ,"top": {
                    "type": "integer"
                    ,"description": "Number of top processes to return (by CPU or memory)"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            var cmd = "Get-Process"
            
            if args.hasKey("name") and args["name"].getStr.len > 0:
                let nameFilter = args["name"].getStr
                cmd &= &" -Name '{nameFilter}'"
            
            cmd &= " | Select-Object Id, ProcessName, CPU, WorkingSet64"
            
            if args.hasKey("top"):
                let top = args["top"].getInt
                cmd &= &" | Sort-Object CPU -Descending | Select-Object -First {top}"
            
            cmd &= " | ConvertTo-Json"
            
            echo &"  → Getting processes"
            let result = runPwshCommand(cmd)
            
            if result.exitCode == 0:
                echo &"  ✓ Success"
                try:
                    let processes = parseJson(result.stdout)
                    return toolSuccess(%*{"processes": processes})
                except JsonParsingError:
                    return toolSuccess(%*{"raw_output": result.stdout})
            else:
                echo &"  ✗ Failed"
                return result.toJson
    )


proc PwshGetServiceTool*(): Tool =
    ## Get Windows services.
    ## strict=false because all parameters are optional.
    Tool(
        name        : "pwsh_get_service"
        ,description: "Get Windows services, optionally filtered by name or status."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "name": {
                    "type": "string"
                    ,"description": "Service name to filter (supports wildcards)"
                }
                ,"status": {
                    "type": "string"
                    ,"enum": ["Running", "Stopped", "Paused"]
                    ,"description": "Filter by service status"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            var cmd = "Get-Service"
            
            if args.hasKey("name") and args["name"].getStr.len > 0:
                let nameFilter = args["name"].getStr
                cmd &= &" -Name '{nameFilter}'"
            
            cmd &= " | Select-Object Name, DisplayName, Status, StartType"
            
            if args.hasKey("status"):
                let status = args["status"].getStr
                cmd &= &" | Where-Object {{ $_.Status -eq '{status}' }}"
            
            cmd &= " | ConvertTo-Json"
            
            echo &"  → Getting services"
            let result = runPwshCommand(cmd)
            
            if result.exitCode == 0:
                echo &"  ✓ Success"
                try:
                    let services = parseJson(result.stdout)
                    return toolSuccess(%*{"services": services})
                except JsonParsingError:
                    return toolSuccess(%*{"raw_output": result.stdout})
            else:
                echo &"  ✗ Failed"
                return result.toJson
    )


proc PwshEnvVarTool*(): Tool =
    ## Get or set environment variables.
    ## strict=false because value is optional (get vs set).
    Tool(
        name        : "pwsh_env_var"
        ,description: "Get or set an environment variable. If value is provided, sets the variable; otherwise gets it."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "name": {
                    "type": "string"
                    ,"description": "Environment variable name"
                }
                ,"value": {
                    "type": "string"
                    ,"description": "Value to set (omit to get current value)"
                }
                ,"scope": {
                    "type": "string"
                    ,"enum": ["Process", "User", "Machine"]
                    ,"description": "Scope for setting variable (default: Process)"
                }
            }
            ,"required": ["name"]
            ,"additionalProperties": false
        }
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let varName = args["name"].getStr
            
            if args.hasKey("value"):
                # Set the variable
                let value = args["value"].getStr
                let scope = if args.hasKey("scope"): args["scope"].getStr else: "Process"
                let cmd = &"[Environment]::SetEnvironmentVariable('{varName}', '{value}', '{scope}'); Write-Output 'Variable set'"
                
                echo &"  → Setting {varName}"
                let result = runPwshCommand(cmd)
                
                if result.exitCode == 0:
                    echo &"  ✓ Variable set"
                    return toolSuccess(%*{
                        "name": varName
                        ,"value": value
                        ,"scope": scope
                        ,"action": "set"
                    })
                else:
                    echo &"  ✗ Failed"
                    return result.toJson
            else:
                # Get the variable
                let cmd = &"$env:{varName}"
                
                echo &"  → Getting {varName}"
                let result = runPwshCommand(cmd)
                
                if result.exitCode == 0:
                    let value = result.stdout.strip
                    echo &"  ✓ Got value"
                    return toolSuccess(%*{
                        "name": varName
                        ,"value": value
                        ,"action": "get"
                    })
                else:
                    echo &"  ✗ Failed"
                    return result.toJson
    )


proc PwshGetHelpTool*(): Tool =
    ## Get help for a PowerShell command.
    ## strict=true - only required parameter.
    Tool(
        name        : "pwsh_get_help"
        ,description: "Get help documentation for a PowerShell command."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "command": {
                    "type": "string"
                    ,"description": "Command to get help for"
                }
            }
            ,"required": ["command"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let command = args["command"].getStr
            let cmd = &"Get-Help '{command}' -Detailed"
            
            echo &"  → Getting help for: {command}"
            let result = runPwshCommand(cmd)
            
            if result.exitCode == 0:
                echo &"  ✓ Success"
                return toolSuccess(%*{
                    "command": command
                    ,"help": result.stdout
                })
            else:
                echo &"  ✗ Failed"
                return result.toJson
    )


proc PwshInvokeWebRequestTool*(): Tool =
    ## Make a web request using PowerShell.
    ## strict=false because method, headers, body are optional.
    Tool(
        name        : "pwsh_web_request"
        ,description: "Make an HTTP web request using PowerShell's Invoke-WebRequest."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "uri": {
                    "type": "string"
                    ,"description": "URL to request"
                }
                ,"method": {
                    "type": "string"
                    ,"enum": ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"]
                    ,"description": "HTTP method (default: GET)"
                }
                ,"body": {
                    "type": "string"
                    ,"description": "Request body (for POST/PUT/PATCH)"
                }
                ,"contentType": {
                    "type": "string"
                    ,"description": "Content-Type header value"
                }
            }
            ,"required": ["uri"]
            ,"additionalProperties": false
        }
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let uri = args["uri"].getStr
            let httpMethod = if args.hasKey("method"): args["method"].getStr else: "GET"
            
            var cmd = &"Invoke-WebRequest -Uri '{uri}' -Method {httpMethod}"
            
            if args.hasKey("contentType"):
                let ct = args["contentType"].getStr
                cmd &= &" -ContentType '{ct}'"
            
            if args.hasKey("body"):
                let body = args["body"].getStr.replace("'", "''")
                cmd &= &" -Body '{body}'"
            
            cmd &= " | Select-Object StatusCode, StatusDescription, @{N='Content';E={$_.Content | ConvertTo-Json}} | ConvertTo-Json"
            
            echo &"  → {httpMethod} {uri}"
            let result = runPwshCommand(cmd)
            
            if result.exitCode == 0:
                echo &"  ✓ Success"
                try:
                    let response = parseJson(result.stdout)
                    return toolSuccess(%*{"response": response})
                except JsonParsingError:
                    return toolSuccess(%*{"raw_output": result.stdout})
            else:
                echo &"  ✗ Failed"
                return result.toJson
    )


proc PwshJsonQueryTool*(basePath: string = "."): Tool =
    ## Query JSON data using PowerShell.
    ## strict=false because file and json are mutually exclusive options.
    let absBasePath = absolutePath(basePath).normalizedPath
    
    Tool(
        name        : "pwsh_json_query"
        ,description: "Query and transform JSON data using PowerShell. Provide either a filename or raw JSON."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "filename": {
                    "type": "string"
                    ,"description": "JSON file to query"
                }
                ,"json": {
                    "type": "string"
                    ,"description": "Raw JSON string to query"
                }
                ,"query": {
                    "type": "string"
                    ,"description": "PowerShell expression to apply (e.g., '.items | Where-Object { $_.active }' or '.data.users')"
                }
            }
            ,"required": ["query"]
            ,"additionalProperties": false
        }
        ,strict     : false  # Has optional parameters
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let query = args["query"].getStr
            var cmd: string
            
            if args.hasKey("filename"):
                let filename = args["filename"].getStr
                let realPath = resolvePath(absBasePath, filename)
                
                if not fileExists(realPath):
                    return toolError(&"File not found: {filename}")
                
                cmd = &"$data = Get-Content '{realPath}' -Raw | ConvertFrom-Json; $data{query} | ConvertTo-Json -Depth 10"
            elif args.hasKey("json"):
                let jsonStr = args["json"].getStr.replace("'", "''")
                cmd = &"$data = '{jsonStr}' | ConvertFrom-Json; $data{query} | ConvertTo-Json -Depth 10"
            else:
                return toolError("Either 'filename' or 'json' must be provided")
            
            echo &"  → Querying JSON"
            let result = runPwshCommand(cmd)
            
            if result.exitCode == 0:
                echo &"  ✓ Success"
                try:
                    let queryResult = parseJson(result.stdout)
                    return toolSuccess(%*{"result": queryResult})
                except JsonParsingError:
                    return toolSuccess(%*{"raw_output": result.stdout})
            else:
                echo &"  ✗ Failed"
                return result.toJson
    )


# -----------------------------------------------------------------------------
# Toolkits
# -----------------------------------------------------------------------------

proc PwshBasicToolkit*(basePath: string = "."): Toolkit =
    ## Basic PowerShell execution toolkit.
    result = newToolkit("pwsh_basic", "Basic PowerShell command and script execution")
    result.add PwshExecTool(basePath)
    result.add PwshScriptTool(basePath)
    result.add PwshScriptCreateTool(basePath)


proc PwshFullToolkit*(basePath: string = "."): Toolkit =
    ## Full PowerShell toolkit with all tools.
    result = newToolkit("pwsh_full", "Complete PowerShell toolkit")
    result.add PwshExecTool(basePath)
    result.add PwshScriptTool(basePath)
    result.add PwshScriptCreateTool(basePath)
    result.add PwshModuleListTool()
    result.add PwshModuleImportTool()
    result.add PwshGetCommandTool()
    result.add PwshGetProcessTool()
    result.add PwshGetServiceTool()
    result.add PwshEnvVarTool()
    result.add PwshGetHelpTool()
    result.add PwshInvokeWebRequestTool()
    result.add PwshJsonQueryTool(basePath)


proc PwshReadOnlyToolkit*(): Toolkit =
    ## Read-only PowerShell operations (safe for untrusted use).
    result = newToolkit("pwsh_readonly", "Read-only PowerShell operations")
    result.add PwshModuleListTool()
    result.add PwshGetCommandTool()
    result.add PwshGetProcessTool()
    result.add PwshGetServiceTool()
    result.add PwshGetHelpTool()


proc PwshSystemInfoToolkit*(): Toolkit =
    ## System information gathering toolkit.
    result = newToolkit("pwsh_sysinfo", "System information and monitoring")
    result.add PwshGetProcessTool()
    result.add PwshGetServiceTool()
    result.add PwshEnvVarTool()


proc PwshDevToolkit*(basePath: string = "."): Toolkit =
    ## Development-focused PowerShell toolkit.
    result = newToolkit("pwsh_dev", "PowerShell development tools")
    result.add PwshExecTool(basePath)
    result.add PwshScriptTool(basePath)
    result.add PwshScriptCreateTool(basePath)
    result.add PwshModuleListTool()
    result.add PwshModuleImportTool()
    result.add PwshGetCommandTool()
    result.add PwshGetHelpTool()
    result.add PwshJsonQueryTool(basePath)