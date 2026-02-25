discard """
Base types for the reusable tools system.

Tools are defined as factory procs that return Tool objects.
This allows tools to be parameterized (e.g., different base paths).

Toolkits are bundles of related tools that often go together.

Example:
    import oai/tools/base
    import oai/tools/filesystem

    var reg = newToolRegistry()
    reg.addTools FileCrudToolkit(basePath = "./workspace")
    
    # Or individual tools:
    reg.addTools FileCreateTool(basePath = "./workspace")
    reg.addTools @[FileReadTool("./workspace"), FileDeleteTool("./workspace")]
"""

import
    std/asyncdispatch
    ,std/json
    ,std/options
    ,std/tables
    ,std/strformat


type
    ToolHandler* = proc(args: JsonNode): Future[JsonNode] {.gcsafe.}

    ## A single tool definition with its handler.
    ## Tools are typically created via factory procs that can accept parameters.
    Tool            * = object
        name        * : string
        description * : string
        parameters  * : JsonNode
        strict      * : bool
        handler     * : ToolHandler
        isBuiltIn   * : bool
        isEnabled   * = true     ## Whether tool is available for LLM use (can be toggled at runtime)

    ## A bundle of related tools that often go together.
    ## Example: FileCrudToolkit contains create, read, update, delete, list tools.
    Toolkit         * = object
        name        * : string
        description * : string
        tools       * : seq[Tool]

proc BuiltInTool*(parameters : JsonNode ): Tool = Tool(
        parameters  : parameters
        ,isBuiltIn  : true
    )


# -----------------------------------------------------------------------------
# Toolkit Constructors
# -----------------------------------------------------------------------------

proc newToolkit*(name: string, description: string = ""): Toolkit = Toolkit(
        name         : name
        ,description : description
        ,tools       : @[]
    )



proc add*(tk: var Toolkit, t: Tool) =
    ## Add a tool to the toolkit.
    tk.tools.add(t)

proc add*(tk: var Toolkit, tools: openArray[Tool]) =
    ## Add multiple tools to the toolkit.
    for t in tools:
        tk.tools.add(t)


proc len*(tk: Toolkit): int =
    tk.tools.len


iterator items*(tk: Toolkit): Tool =
    for t in tk.tools:
        yield t


# -----------------------------------------------------------------------------
# Tool Helpers
# -----------------------------------------------------------------------------

proc `%`*(t: Tool): JsonNode =
    ## Convert a Tool to the OpenAI function tool JSON format.
    result = %*{
        "type": "function"
        ,"name": t.name
    }
    if t.description.len > 0:
        result["description"] = %t.description
    if t.parameters != nil:
        result["parameters"] = t.parameters
    if t.strict:
        result["strict"] = %true


# -----------------------------------------------------------------------------
# Common Result Helpers (for tool handlers)
# -----------------------------------------------------------------------------

proc tool_call_was_successful*(tc_payload: JsonNode): bool =
    ## Check if a tool call tc_payload indicates success.
    ## String payloads (e.g., Moonshot encrypted content) are treated as successful.
    if tc_payload == nil:
        return false
    if tc_payload.kind == JString:
        return true
    if tc_payload.kind == JObject and tc_payload.hasKey("success"):
        return tc_payload["success"].getBool
    return false

proc get_tool_call_error*(tc_payload: JsonNode): string =
    ## Extract the error message from a tool call tc_payload, if present.
    ## Returns empty string for string payloads (no error).
    if tc_payload == nil or tc_payload.kind != JObject:
        return ""
    if tc_payload.hasKey("error"):
        return tc_payload["error"].getStr
    return ""

proc toolSuccess*(data: JsonNode = nil, message: string = ""): JsonNode =
    ## Create a successful tool result.
    result = %*{"success": true}
    if data != nil:
        for k, v in data.pairs:
            result[k] = v
    if message.len > 0:
        result["message"] = %message


proc toolError*(error: string): JsonNode =
    ## Create a failed tool result.
    %*{
        "success": false
        ,"error": error
    }


proc toolResult*(success: bool, data: JsonNode = nil, error: string = ""): JsonNode =
    ## Create a tool result with explicit success/failure.
    if success:
        toolSuccess(data)
    else:
        toolError(error)




proc functionTool*(
    name                : string
    ,description        : string = ""
    ,parameters         : JsonNode = nil
    ,strict             : bool = false
)   : JsonNode =
    discard """
    Create a function tool configuration
    """
    result              = %*{
        "type"          : "function"
        ,"name"         : name
    }
    if description.len > 0:
        result["description"] = %description
    if parameters != nil:
        result["parameters"] = parameters
    if strict:
        result["strict"] = %true

proc toolJson*(t: Tool): JsonNode =
    ## Convert to the Responses API function-tool shape.
    result = functionTool(
        name            = t.name
        ,description    = t.description
        ,parameters     = t.parameters
        ,strict         = t.strict
    )



proc getToolDefinitionsJson*(tools: seq[Tool]): JsonNode =
  ## Returns formatted tool definitions as JSON for the developer message.
  ## Used to populate cache with tool schema once per agent.
  ##
  ## Example output:
  ##   {
  ##     "tool_definitions": [
  ##       {"name": "file_read", "description": "...", "parameters": {...}},
  ##       ...
  ##     ],
  ##     "total_tools": 5
  ##   }
  var toolDefs: seq[JsonNode] = @[]
  for t in tools:
    toolDefs.add(%t)
  
  return %*{
    "tool_definitions": toolDefs,
    "total_tools": toolDefs.len
  }

# -----------------------------------------------------------------------------
# Tool output helpers
# -----------------------------------------------------------------------------

proc functionOutput*(callId: string, payload: string): JsonNode =
    ## Build a function_call_output item.
    %*{
        "type"     : "function_call_output"
        ,"call_id" : callId
        ,"output"  : payload
    }


proc functionOutput*(callId: string, payload: JsonNode): JsonNode =
    functionOutput(callId, $payload)




# -----------------------------------------------------------------------------
# Tool Filtering
# -----------------------------------------------------------------------------

proc getEnabledTools*(tools: OrderedTable[string, Tool]): seq[Tool] =
  ## Returns only tools that are enabled (isEnabled = true).
  ## Used when sending tools to the LLM to respect runtime enable/disable.
  for name, tool in tools:
    if tool.isEnabled:
      result.add(tool)

proc getEnabledToolDefinitions*(tools: OrderedTable[string, Tool]): JsonNode =
  ## Returns formatted tool definitions for only enabled tools.
  ## Used when building LLM requests.
  var toolDefs: seq[JsonNode] = @[]
  for name, tool in tools:
    if tool.isEnabled:
      toolDefs.add(%tool)
  
  return %*{
    "tool_definitions": toolDefs,
    "total_tools": toolDefs.len
  }
