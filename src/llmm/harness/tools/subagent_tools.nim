## subagent_tools.nim — Tools for agents to create/manage subagents
##
## These tools allow agents to:
##   - Create specialized child agents for specific tasks
##   - Delegate work and monitor progress
##   - Collect results from parallel subagent execution
##
## Example workflow:
##   1. Agent creates subagents: researcher, coder, reviewer
##   2. Agent delegates tasks to each subagent
##   3. Agent waits for all to complete
##   4. Agent synthesizes results

import std/[
  json,
  times,
  options,
  asyncdispatch,
  strformat,
  strutils,
  sequtils
]

import ./base
import ../primitives/agent
import ../primitives/subagents
import ../../general_helpers

# -----------------------------------------------------------------------------
# Helper: Cast pointer back to Agent (for gcsafe closure capture)
# -----------------------------------------------------------------------------

template parentFromPtr(parentPtr: pointer): Agent =
  cast[Agent](parentPtr)

# -----------------------------------------------------------------------------
# Tool: create_subagent
# -----------------------------------------------------------------------------

proc CreateSubagentTool*(parent: Agent): Tool =
  ## Factory for the create_subagent tool
  ## 
  ## Creates a new specialized subagent as a child of the current agent.
  ## The subagent inherits the parent's provider and optionally inherits tools.
  
  let parameters = %*{
    "type": "object",
    "properties": {
      "name": {
        "type": "string",
        "description": "Unique name for this subagent (e.g., 'researcher', 'code_helper')"
      },
      "role": {
        "type": "string",
        "description": "The role/purpose of this subagent (e.g., 'Research specialist', 'Code reviewer')"
      },
      "instructions": {
        "type": "string",
        "description": "Specific instructions for this subagent's behavior and focus"
      },
      "model": {
        "type": "string",
        "description": "Model to use (defaults to parent's model if not specified)"
      },
      "max_tool_calls": {
        "type": "integer",
        "description": "Maximum tool calls allowed per task (default: 50)",
        "default": 50
      },
      "inherit_tools": {
        "type": "boolean",
        "description": "Whether to inherit tools from parent agent (default: true)",
        "default": true
      }
    },
    "required": ["name", "role"]
  }
  
  let parentPtr = cast[pointer](parent)

  proc handler(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    try:
      let parent = parentFromPtr(parentPtr)
      let name = args["name"].getStr()
      let role = args["role"].getStr()
      let instructions = args.getOrDefault("instructions").getStr("")
      let model = args.getOrDefault("model").getStr("")
      let maxToolCalls = args.getOrDefault("max_tool_calls").getInt(50)
      let inheritTools = args.getOrDefault("inherit_tools").getBool(true)
      
      let handle = await createSubagent(
        parent = parent,
        name = name,
        role = role,
        instructions = instructions,
        model = model,
        maxToolCalls = maxToolCalls,
        inheritTools = inheritTools
      )
      
      return toolSuccess(
        data = handle.toJson(),
        message = &"Created subagent '{name}' (ID: {handle.id})"
      )
      
    except CatchableError as e:
      return toolError(&"Failed to create subagent: {e.msg}")
  
  Tool(
    name: "create_subagent",
    description: """Create a specialized child agent (subagent) to handle a specific task.

Use this when you need to:
- Delegate work to a specialized agent with different expertise
- Run tasks in parallel with multiple agents
- Isolate complex work from your main context
- Create a team of agents for a multi-step workflow

The subagent will have its own isolated session and workspace, but shares your provider.
Subagents can inherit your tools (except subagent management tools to prevent recursion).

Example: Create a "researcher" subagent to gather information while you work on other tasks.""",
    parameters: parameters,
    handler: handler,
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Tool: list_subagents
# -----------------------------------------------------------------------------

proc ListSubagentsTool*(parent: Agent): Tool =
  ## Factory for the list_subagents tool
  
  let parentPtr = cast[pointer](parent)
  
  let parameters = %*{
    "type": "object",
    "properties": {
      "status_filter": {
        "type": "string",
        "description": "Filter by status: 'running', 'completed', 'failed', 'ready', 'all' (default: 'all')",
        "enum": ["running", "completed", "failed", "ready", "all"],
        "default": "all"
      }
    }
  }
  
  proc handler(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    let parent = parentFromPtr(parentPtr)
    var statusFilter: Option[SubagentStatus] = none(SubagentStatus)
    
    if args.hasKey("status_filter"):
      let filterStr = args["status_filter"].getStr("all")
      case filterStr
      of "running": statusFilter = some(ssRunning)
      of "completed": statusFilter = some(ssCompleted)
      of "failed": statusFilter = some(ssFailed)
      of "ready": statusFilter = some(ssReady)
      else: discard
    
    let subagents = parent.listSubagents(statusFilter)
    
    if subagents.len == 0:
      return toolSuccess(message = "No subagents found")
    
    var subagentList: seq[JsonNode] = @[]
    for handle in subagents:
      subagentList.add(handle.toJson())
    
    return toolSuccess(
      data = %*{"subagents": subagentList, "count": subagents.len},
      message = &"Found {subagents.len} subagent(s)"
    )
  
  Tool(
    name: "list_subagents",
    description: "List all subagents created by this agent, optionally filtered by status.",
    parameters: parameters,
    handler: handler,
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Tool: send_to_subagent
# -----------------------------------------------------------------------------

proc SendToSubagentTool*(parent: Agent): Tool =
  ## Factory for the send_to_subagent tool
  ## 
  ## Sends a task to a subagent and optionally waits for completion
  
  let parentPtr = cast[pointer](parent)
  
  let parameters = %*{
    "type": "object",
    "properties": {
      "subagent_id": {
        "type": "string",
        "description": "ID or name of the subagent to send the task to"
      },
      "task": {
        "type": "string",
        "description": "The task/instruction to give to the subagent"
      },
      "wait": {
        "type": "boolean",
        "description": "Whether to wait for completion (true) or run async (false). Default: true",
        "default": true
      },
      "max_tool_calls": {
        "type": "integer",
        "description": "Max tool calls for this task (default: use subagent's default)",
        "default": 0
      },
      "timeout_seconds": {
        "type": "integer",
        "description": "Timeout in seconds when waiting (default: 300 = 5 minutes)",
        "default": 300
      }
    },
    "required": ["subagent_id", "task"]
  }
  
  proc handler(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    try:
      let parent = parentFromPtr(parentPtr)
      let subagentId = args["subagent_id"].getStr()
      let task = args["task"].getStr()
      let wait = args.getOrDefault("wait").getBool(true)
      let maxToolCalls = args.getOrDefault("max_tool_calls").getInt(0)
      let timeoutSeconds = args.getOrDefault("timeout_seconds").getInt(300)
      
      # Try to find by ID first, then by name
      var handleOpt = parent.getSubagent(subagentId)
      if handleOpt.isNone:
        handleOpt = parent.getSubagentByName(subagentId)
      
      if handleOpt.isNone:
        return toolError(&"Subagent not found: '{subagentId}'")
      
      let handle = handleOpt.get()
      
      # Check if already running
      if handle.status == ssRunning:
        return toolError(&"Subagent '{handle.name}' is already running a task")
      
      if wait:
        # Synchronous execution
        let result = await handle.run(task, maxToolCalls)
        
        if result.success:
          return toolSuccess(
            data = result.toJson(),
            message = &"Subagent '{handle.name}' completed successfully ({result.tokensUsed} tokens, {result.toolCalls} tool calls)"
          )
        else:
          return toolError(&"Subagent '{handle.name}' failed: {result.error.get(\"unknown error\")}")
      else:
        # Asynchronous execution
        await handle.runAsync(task, maxToolCalls)
        return toolSuccess(
          data = handle.toJson(),
          message = &"Task sent to subagent '{handle.name}' (running asynchronously)"
        )
        
    except CatchableError as e:
      return toolError(&"Error sending task to subagent: {e.msg}")
  
  Tool(
    name: "send_to_subagent",
    description: """Send a task to a subagent and optionally wait for completion.

Use this to delegate work to a subagent. You can either:
1. Wait for completion (default): The task runs and you get the result
2. Run asynchronously: The task starts and you can check status later

When waiting, specify a timeout to prevent hanging indefinitely.

Example: "Research the latest AI papers" → sends to a researcher subagent""",
    parameters: parameters,
    handler: handler,
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Tool: get_subagent_status
# -----------------------------------------------------------------------------

proc GetSubagentStatusTool*(parent: Agent): Tool =
  ## Factory for the get_subagent_status tool
  
  let parentPtr = cast[pointer](parent)
  
  let parameters = %*{
    "type": "object",
    "properties": {
      "subagent_id": {
        "type": "string",
        "description": "ID or name of the subagent to check"
      }
    },
    "required": ["subagent_id"]
  }
  
  proc handler(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    let parent = parentFromPtr(parentPtr)
    let subagentId = args["subagent_id"].getStr()
    
    var handleOpt = parent.getSubagent(subagentId)
    if handleOpt.isNone:
      handleOpt = parent.getSubagentByName(subagentId)
    
    if handleOpt.isNone:
      return toolError(&"Subagent not found: '{subagentId}'")
    
    let handle = handleOpt.get()
    return toolSuccess(
      data = handle.toJson(),
      message = &"Subagent '{handle.name}' is {handle.status}"
    )
  
  Tool(
    name: "get_subagent_status",
    description: "Get the current status and result (if completed) of a subagent.",
    parameters: parameters,
    handler: handler,
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Tool: wait_for_subagent
# -----------------------------------------------------------------------------

proc WaitForSubagentTool*(parent: Agent): Tool =
  ## Factory for the wait_for_subagent tool
  
  let parentPtr = cast[pointer](parent)
  
  let parameters = %*{
    "type": "object",
    "properties": {
      "subagent_id": {
        "type": "string",
        "description": "ID or name of the subagent to wait for"
      },
      "timeout_seconds": {
        "type": "integer",
        "description": "Maximum time to wait in seconds (default: 300 = 5 minutes)",
        "default": 300
      }
    },
    "required": ["subagent_id"]
  }
  
  proc handler(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    try:
      let parent = parentFromPtr(parentPtr)
      let subagentId = args["subagent_id"].getStr()
      let timeoutSeconds = args.getOrDefault("timeout_seconds").getInt(300)
      
      var handleOpt = parent.getSubagent(subagentId)
      if handleOpt.isNone:
        handleOpt = parent.getSubagentByName(subagentId)
      
      if handleOpt.isNone:
        return toolError(&"Subagent not found: '{subagentId}'")
      
      let handle = handleOpt.get()
      
      if handle.status notin [ssRunning, ssReady]:
        # Already done - return cached result
        if handle.result.isSome:
          let r = handle.result.get()
          if r.success:
            return toolSuccess(
              data = handle.toJson(),
              message = &"Subagent '{handle.name}' already completed"
            )
          else:
            return toolError(&"Subagent '{handle.name}' failed: {r.error.get(\"unknown\")}")
        else:
          return toolSuccess(message = &"Subagent '{handle.name}' is {handle.status}")
      
      # Wait for completion
      let result = await handle.waitFor(initDuration(seconds = timeoutSeconds))
      
      if result.success:
        return toolSuccess(
          data = result.toJson(),
          message = &"Subagent '{handle.name}' completed successfully"
        )
      else:
        return toolError(&"Subagent '{handle.name}' failed: {result.error.get(\"unknown error\")}")
        
    except CatchableError as e:
      return toolError(&"Error waiting for subagent: {e.msg}")
  
  Tool(
    name: "wait_for_subagent",
    description: """Wait for a running subagent to complete and return its result.

Use this when you previously started a subagent asynchronously and now need its result.
Specify a timeout to prevent waiting indefinitely.

If the subagent already completed, returns the cached result immediately.""",
    parameters: parameters,
    handler: handler,
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Tool: wait_for_all_subagents
# -----------------------------------------------------------------------------

proc WaitForAllSubagentsTool*(parent: Agent): Tool =
  ## Factory for the wait_for_all_subagents tool
  
  let parentPtr = cast[pointer](parent)
  
  let parameters = %*{
    "type": "object",
    "properties": {
      "timeout_seconds": {
        "type": "integer",
        "description": "Maximum time to wait in seconds (default: 600 = 10 minutes)",
        "default": 600
      }
    }
  }
  
  proc handler(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    try:
      let parent = parentFromPtr(parentPtr)
      let timeoutSeconds = args.getOrDefault("timeout_seconds").getInt(600)
      
      let results = await parent.waitForAll(initDuration(seconds = timeoutSeconds))
      
      var successCount = 0
      var failCount = 0
      var outputs: seq[JsonNode] = @[]
      
      for result in results:
        if result.success:
          successCount.inc
        else:
          failCount.inc
        outputs.add(result.toJson())
      
      let message = &"All subagents completed: {successCount} succeeded, {failCount} failed"
      
      return toolSuccess(
        data = %*{
          "results": outputs,
          "summary": {
            "total": results.len,
            "succeeded": successCount,
            "failed": failCount
          }
        },
        message = message
      )
        
    except CatchableError as e:
      return toolError(&"Error waiting for subagents: {e.msg}")
  
  Tool(
    name: "wait_for_all_subagents",
    description: """Wait for all running subagents to complete.

Use this after starting multiple subagents asynchronously to collect all results.
Returns a summary of all results with success/failure counts.

If no subagents are running, returns immediately with cached results.""",
    parameters: parameters,
    handler: handler,
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Tool: cancel_subagent
# -----------------------------------------------------------------------------

proc CancelSubagentTool*(parent: Agent): Tool =
  ## Factory for the cancel_subagent tool
  
  let parentPtr = cast[pointer](parent)
  
  let parameters = %*{
    "type": "object",
    "properties": {
      "subagent_id": {
        "type": "string",
        "description": "ID or name of the subagent to cancel"
      }
    },
    "required": ["subagent_id"]
  }
  
  proc handler(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    let parent = parentFromPtr(parentPtr)
    let subagentId = args["subagent_id"].getStr()
    
    var handleOpt = parent.getSubagent(subagentId)
    if handleOpt.isNone:
      handleOpt = parent.getSubagentByName(subagentId)
    
    if handleOpt.isNone:
      return toolError(&"Subagent not found: '{subagentId}'")
    
    let handle = handleOpt.get()
    
    if handle.cancel():
      return toolSuccess(message = &"Cancellation requested for subagent '{handle.name}'")
    else:
      return toolError(&"Subagent '{handle.name}' is not running (status: {handle.status})")
  
  Tool(
    name: "cancel_subagent",
    description: "Cancel a running subagent task.",
    parameters: parameters,
    handler: handler,
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Tool: cleanup_subagent
# -----------------------------------------------------------------------------

proc CleanupSubagentTool*(parent: Agent): Tool =
  ## Factory for the cleanup_subagent tool
  
  let parentPtr = cast[pointer](parent)
  
  let parameters = %*{
    "type": "object",
    "properties": {
      "subagent_id": {
        "type": "string",
        "description": "ID or name of the subagent to cleanup"
      }
    },
    "required": ["subagent_id"]
  }
  
  proc handler(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    let parent = parentFromPtr(parentPtr)
    let subagentId = args["subagent_id"].getStr()
    
    if parent.cleanupSubagent(subagentId):
      return toolSuccess(message = &"Subagent '{subagentId}' cleaned up successfully")
    else:
      return toolError(&"Failed to cleanup subagent '{subagentId}' (may not exist)")
  
  Tool(
    name: "cleanup_subagent",
    description: """Clean up a subagent and remove it from the registry.

This frees resources and removes the subagent. The subagent should not be running.
Results from completed subagents are lost after cleanup.""",
    parameters: parameters,
    handler: handler,
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Toolkit Bundle
# -----------------------------------------------------------------------------

proc SubagentToolkit*(parent: Agent): Toolkit =
  ## Factory that creates all subagent management tools
  ## 
  ## Usage:
  ##   agent.addTools SubagentToolkit(agent)
  
  var tk = newToolkit("subagent_management", "Tools for creating and managing child agents")
  
  tk.add CreateSubagentTool(parent)
  tk.add ListSubagentsTool(parent)
  tk.add SendToSubagentTool(parent)
  tk.add GetSubagentStatusTool(parent)
  tk.add WaitForSubagentTool(parent)
  tk.add WaitForAllSubagentsTool(parent)
  tk.add CancelSubagentTool(parent)
  tk.add CleanupSubagentTool(parent)
  
  return tk


# -----------------------------------------------------------------------------
# Enable Subagents on Agent
# -----------------------------------------------------------------------------

proc enableSubagents*(a: Agent, maxSubagents: int = 10) =
  ## Enable subagent support for this agent - allows the LLM to create and
  ## manage child agents for task delegation.
  ##
  ## Parameters:
  ##   maxSubagents: Maximum number of concurrent subagents (default: 10)
  ##
  ## Example:
  ##   var agent = new Agent(...)
  ##   agent.enableSubagents()  # Enable with default limit
  ##   # Agent can now use create_subagent, send_to_subagent, etc.
  
  # Initialize the subagent registry and store as base ref (GC-tracked)
  let reg = newSubagentRegistry(
    parentId = a.cfg.id,
    maxSubagents = maxSubagents,
    defaultModel = a.cfg.model
  )
  a.state.subagentRegistry = reg  # Assign directly (no cast needed)
  
  # Add all subagent management tools
  a.addTools SubagentToolkit(a)
