## subagents.nim — Hierarchical agent management
##
## Enables agents to spawn, manage, and communicate with child agents.
## Subagents are independent agents that run in the parent's workspace
## but have isolated sessions and can be monitored/controlled.
##
## Usage:
##   # In a parent agent's tool handler:
##   let child = await parent.createSubagent(
##     name = "researcher",
##     role = "Research specialist",
##     instructions = "Find information about..."
##   )
##   let result = await child.run("Research quantum computing")
##   await parent.waitForSubagent(child.id)

import std/[
  json,
  times,
  options,
  asyncdispatch,
  asyncfutures,
  strformat,
  os,
  tables,
  sequtils,
  hashes,
  strutils,
  oids
]

# Import allFutures from asyncfutures


import ./agent
import ./sessions
import ./store
import ../tools/base
import ../../general_helpers
import ../providers/openai_responses
import ic

type
  SubagentStatus* = enum
    ssCreating      ## Being initialized
    ssReady         ## Ready to run tasks
    ssRunning       ## Currently executing a task
    ssCompleted     ## Task finished successfully
    ssFailed        ## Task failed with error
    ssCancelled     ## Was cancelled by parent

  SubagentResult* = object
    ## Result from a subagent task execution
    success*      : bool
    output*       : string           ## Text output from the subagent
    toolCalls*    : int              ## Number of tool calls made
    tokensUsed*   : int              ## Total tokens consumed
    elapsed*      : Duration
    error*        : Option[string]   ## Error message if failed
    artifacts*    : seq[string]      ## Files created/modified

  SubagentHandle* = ref object
    ## Reference to a child agent
    id*           : string           ## Unique subagent ID
    name*         : string           ## Human-readable name
    parentId*     : string           ## Parent agent ID
    status*       : SubagentStatus
    createdAt*    : DateTime
    config*       : AgentConfig      ## Subagent's configuration
    agent*        : Agent            ## The actual agent instance
    currentTask*  : Option[string]   ## Current task if running
    result*       : Option[SubagentResult]
    
    # Async control
    runFuture*    : Option[Future[SubagentResult]]
    cancelToken*  : bool             ## Set to true to cancel

  SubagentRegistry* = ref object of SubagentRegistryBase
    ## Tracks all subagents of a parent agent
    parentId*     : string
    subagents*    : OrderedTable[string, SubagentHandle]  ## id -> handle
    byName*       : Table[string, string]                  ## name -> id
    maxSubagents* : int                                    ## Limit (0 = unlimited)
    defaultModel* : string                                 ## Fallback model

  SubagentEventKind* = enum
    sekCreated
    sekStarted
    sekCompleted
    sekFailed
    sekCancelled

  SubagentEvent* = object
    timestamp*  : DateTime
    subagentId* : string
    parentId*   : string
    kind*       : SubagentEventKind
    details*    : JsonNode

  SubagentEventHandler* = proc(e: SubagentEvent) {.gcsafe.}

# -----------------------------------------------------------------------------
# Event Dispatch
# -----------------------------------------------------------------------------

var globalSubagentHandlers {.threadvar.}: seq[SubagentEventHandler]

proc onSubagentEvent*(handler: SubagentEventHandler) {.gcsafe.} =
  ## Register a global handler for subagent events
  globalSubagentHandlers.add(handler)

proc emitSubagentEvent(subagent: SubagentHandle, kind: SubagentEventKind, details: JsonNode = %*{}) {.gcsafe.} =
  let event = SubagentEvent(
    timestamp: now(),
    subagentId: subagent.id,
    parentId: subagent.parentId,
    kind: kind,
    details: details
  )
  for handler in globalSubagentHandlers:
    handler(event)

# -----------------------------------------------------------------------------
# Registry Management
# -----------------------------------------------------------------------------

proc newSubagentRegistry*(parentId: string, maxSubagents: int = 10, defaultModel: string = ""): SubagentRegistry =
  ## Create a new registry for managing child agents
  SubagentRegistry(
    parentId: parentId,
    subagents: initOrderedTable[string, SubagentHandle](),
    byName: initTable[string, string](),
    maxSubagents: maxSubagents,
    defaultModel: defaultModel
  )

proc count*(reg: SubagentRegistry): int =
  ## Number of active subagents
  reg.subagents.len

proc canCreate*(reg: SubagentRegistry): bool =
  ## Check if we can create more subagents
  if reg.maxSubagents <= 0: return true
  return reg.subagents.len < reg.maxSubagents

proc get*(reg: SubagentRegistry, id: string): Option[SubagentHandle] =
  ## Get a subagent by ID
  if reg.subagents.hasKey(id):
    return some(reg.subagents[id])
  return none(SubagentHandle)

proc getByName*(reg: SubagentRegistry, name: string): Option[SubagentHandle] =
  ## Get a subagent by name
  if reg.byName.hasKey(name):
    let id = reg.byName[name]
    return reg.get(id)
  return none(SubagentHandle)

proc list*(reg: SubagentRegistry, statusFilter: Option[SubagentStatus] = none(SubagentStatus)): seq[SubagentHandle] =
  ## List all subagents, optionally filtered by status
  result = @[]
  for handle in reg.subagents.values:
    if statusFilter.isNone or handle.status == statusFilter.get:
      result.add(handle)

proc remove*(reg: SubagentRegistry, id: string): bool =
  ## Remove a subagent from the registry
  if not reg.subagents.hasKey(id):
    return false
  
  let handle = reg.subagents[id]
  if handle.name.len > 0:
    reg.byName.del(handle.name)
  reg.subagents.del(id)
  return true

# Helper to cast base ref to SubagentRegistry
template getRegistry(a: Agent): SubagentRegistry =
  doAssert(not a.state.subagentRegistry.isNil, "Subagent registry is nil")
  cast[SubagentRegistry](a.state.subagentRegistry)

# -----------------------------------------------------------------------------
# Subagent Creation
# -----------------------------------------------------------------------------

proc generateSubagentId(parentId: string, name: string): string =
  ## Generate a unique ID for a subagent
  let slug = if name.len > 0: name.toSlug() else: "subagent"
  let timestamp = now().format("yyyyMMddHHmmss")
  let random = $hash($genOid())
  result = &"{slug}_{timestamp}_{random[0..5]}"

# List of tool names that should NOT be inherited by subagents (to prevent recursion)
const SubagentToolNames* = [
  "create_subagent",
  "list_subagents", 
  "send_to_subagent",
  "get_subagent_status",
  "wait_for_subagent",
  "wait_for_all_subagents",
  "cancel_subagent",
  "cleanup_subagent"
]

proc createSubagent*(
  parent: Agent,
  name: string,
  role: string,
  instructions: string = "",
  model: string = "",
  systemPrompt: string = "",
  maxToolCalls: int = 50,
  inheritTools: bool = true,
  extraTools: seq[Tool] = @[],
  lightweight: bool = true,
  personaContent: string = "",
  staticContext: string = ""
): Future[SubagentHandle] {.async, gcsafe.} =
  ## Create a new subagent as a child of the parent agent
  ##
  ## Phase 3 Parameters (for optimal prompt caching):
  ##   personaContent: Static persona/role description (cached across turns)
  ##   staticContext: Additional static context (knowledge, guidelines, etc.)
  
  # Check if registry exists
  var reg: SubagentRegistry
  if parent.state.subagentRegistry.isNil:
    reg = newSubagentRegistry(
      parentId = parent.cfg.id,
      maxSubagents = 10,
      defaultModel = parent.cfg.model
    )
    parent.state.subagentRegistry = reg  # Assign directly (no cast needed)
  else:
    reg = getRegistry(parent)
  
  # Check limits
  if not reg.canCreate():
    raise newException(ValueError, &"Maximum subagents ({reg.maxSubagents}) reached")
  
  # Check for name collision
  if name.len > 0 and reg.byName.hasKey(name):
    raise newException(ValueError, &"Subagent with name '{name}' already exists")
  
  # Determine model
  let useModel = if model.len > 0: model 
                 elif reg.defaultModel.len > 0: reg.defaultModel
                 else: parent.cfg.model
  
  # Build system prompt
  var fullSystemPrompt = systemPrompt
  if fullSystemPrompt.len == 0:
    fullSystemPrompt = &"""You are a specialized subagent named "{name}".
Role: {role}

You work as part of a team led by a parent agent. Your job is to:
1. Focus on your specific role and expertise
2. Complete assigned tasks efficiently
3. Report back with clear, actionable results
4. Ask for clarification if the task is unclear

Instructions from parent:
{instructions}

Remember: You are autonomous but report to the parent agent. Be concise and actionable."""

  # Create subagent workspace subdirectory
  let subagentWorkspace = parent.cfg.workspaceDir / "subagents" / name.toSlug()
  discard dirExistsOrMk(subagentWorkspace)
  
  # Create the subagent ID
  let subagentId = generateSubagentId(parent.cfg.id, name)
  
  # Build the subagent's tools
  var subagentTools = initOrderedTable[string, Tool]()
  
  # Inherit tools from parent if requested
  if inheritTools:
    for toolName, tool in parent.cfg.tools:
      # Skip subagent-related tools to prevent infinite recursion
      if toolName notin SubagentToolNames:
        subagentTools[toolName] = tool
  
  # Add extra tools
  for tool in extraTools:
    subagentTools[tool.name] = tool
  
  # Create the agent config - inherit cache settings from parent
  let subagentConfig = AgentConfig(
    id: subagentId,
    name: name,
    role: role,
    model: useModel,
    systemPrompt: fullSystemPrompt,
    instructions: instructions,
    workspaceDir: subagentWorkspace,
    dbPath: subagentWorkspace / &"{name.toSlug()}.db",
    tools: subagentTools,
    policy: AgentPolicy(maxToolCalls: maxToolCalls),
    enableReflection: (not lightweight),
    promptCacheRetention: parent.cfg.promptCacheRetention,  # Inherit retention policy
    
    # Phase 3: Static content for optimal caching
    personaContent: personaContent,
    staticContext: staticContext
  )
  
  # Create the agent instance with its own provider for cache isolation  # Subagents get strategic cache keys based on their role/name for optimal caching
  var subagentProvider = parent.provider
  if parent.provider of OpenAIResponsesProvider:
    let openaiParentProv = OpenAIResponsesProvider(parent.provider)
    # Generate strategic cache key: subagent_{role}_{name}_{parent_id}
    # This groups same-role subagents under the same cache key for efficiency    let cacheKey = &"subagent_{role.toSlug()}_{name.toSlug()}_{parent.cfg.id[0..7]}"
    let retention = if parent.cfg.promptCacheRetention.len > 0: parent.cfg.promptCacheRetention else: "in_memory"
    subagentProvider = openaiParentProv.withPromptCacheConfig(
      cacheKey = cacheKey,
      retention = retention
    )
  
  var subagentAgent = Agent(
    provider: subagentProvider,
    cfg: subagentConfig,
    state: AgentState()  # Will be initialized
  )
  
  # Initialize the agent (lightweight subagents skip heavy stores)
  subagentAgent = subagentAgent.new(lightweight = lightweight)
  
  # Create the handle
  let handle = SubagentHandle(
    id: subagentId,
    name: name,
    parentId: parent.cfg.id,
    status: ssReady,
    createdAt: now(),
    config: subagentConfig,
    agent: subagentAgent,
    currentTask: none(string),
    result: none(SubagentResult),
    cancelToken: false
  )
  
  # Register in parent's registry
  reg.subagents[subagentId] = handle
  if name.len > 0:
    reg.byName[name] = subagentId
  
  emitSubagentEvent(handle, sekCreated, %*{ "model": useModel })
  
  ic "Created subagent", name, "with ID", subagentId
  return handle

# -----------------------------------------------------------------------------
# Subagent Execution
# -----------------------------------------------------------------------------

# Forward declaration - implemented at end of file to avoid circular import issues
proc runTaskAsync(handle: SubagentHandle, task: string, maxToolCalls: int = 0): Future[SubagentResult] {.async, gcsafe.}

proc run*(handle: SubagentHandle, task: string, maxToolCalls: int = 0): Future[SubagentResult] {.async, gcsafe.} =
  ## Run a task on this subagent and wait for completion
  if handle.status == ssRunning:
    raise newException(ValueError, "Subagent is already running a task")
  
  handle.runFuture = some(runTaskAsync(handle, task, maxToolCalls))
  result = await handle.runFuture.get()
  handle.runFuture = none(Future[SubagentResult])

proc runAsync*(handle: SubagentHandle, task: string, maxToolCalls: int = 0): Future[void] {.async, gcsafe.} =
  ## Start a task on this subagent without waiting for completion
  if handle.status == ssRunning:
    raise newException(ValueError, "Subagent is already running a task")
  
  handle.runFuture = some(runTaskAsync(handle, task, maxToolCalls))

proc waitFor*(handle: SubagentHandle, timeout: Duration = initDuration(minutes = 5)): Future[SubagentResult] {.async, gcsafe.} =
  ## Wait for the subagent to complete its current task
  if handle.runFuture.isNone:
    if handle.result.isSome:
      return handle.result.get
    raise newException(ValueError, "Subagent is not running")
  
  let fut = handle.runFuture.get()
  
  # Wait with timeout
  let completed = await fut.withTimeout(timeout.inMilliseconds.int)
  if not completed:
    handle.cancelToken = true
    raise newException(CatchableError, "Subagent execution timed out")
  
  result = fut.read()
  handle.runFuture = none(Future[SubagentResult])

proc cancel*(handle: SubagentHandle): bool {.gcsafe.} =
  ## Request cancellation of the current task
  if handle.status != ssRunning:
    return false
  handle.cancelToken = true
  return true

# -----------------------------------------------------------------------------
# Parent Agent Integration Helpers
# -----------------------------------------------------------------------------

proc listSubagents*(parent: Agent, statusFilter: Option[SubagentStatus] = none(SubagentStatus)): seq[SubagentHandle] {.gcsafe.} =
  ## List all subagents of a parent agent
  if parent.state.subagentRegistry.isNil:
    return @[]
  return getRegistry(parent).list(statusFilter)

proc getSubagent*(parent: Agent, id: string): Option[SubagentHandle] {.gcsafe.} =
  ## Get a subagent by ID
  if parent.state.subagentRegistry.isNil:
    return none(SubagentHandle)
  return getRegistry(parent).get(id)

proc getSubagentByName*(parent: Agent, name: string): Option[SubagentHandle] {.gcsafe.} =
  ## Get a subagent by name
  if parent.state.subagentRegistry.isNil:
    return none(SubagentHandle)
  return getRegistry(parent).getByName(name)

proc waitForAll*(parent: Agent, timeout: Duration = initDuration(minutes = 10)): Future[seq[SubagentResult]] {.async, gcsafe.} =
  ## Wait for all running subagents to complete
  if parent.state.subagentRegistry.isNil:
    return @[]
  
  let running = getRegistry(parent).list(some(ssRunning))
  var results: seq[SubagentResult] = @[]
  
  # Wait for all running subagents with timeout
  let startTime = now()
  for handle in running:
    if handle.runFuture.isSome:
      let elapsed = now() - startTime
      let remainingTimeout = timeout - elapsed
      if remainingTimeout <= initDuration(0):
        discard handle.cancel()
        continue
      try:
        discard await handle.runFuture.get().withTimeout(remainingTimeout.inMilliseconds.int)
      except:
        discard handle.cancel()
  
  # Collect results
  for handle in running:
    if handle.result.isSome:
      results.add(handle.result.get)
  
  return results

proc cleanupSubagent*(parent: Agent, id: string): bool {.gcsafe.} =
  ## Remove a subagent and clean up its resources
  let handleOpt = parent.getSubagent(id)
  if handleOpt.isNone:
    return false
  
  let handle = handleOpt.get()
  
  # Cancel if running
  if handle.status == ssRunning:
    discard handle.cancel()
  
  # Remove from registry
  if parent.state.subagentRegistry.isNil:
    return false
  return getRegistry(parent).remove(id)

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

proc `$`*(status: SubagentStatus): string =
  case status
  of ssCreating: "creating"
  of ssReady: "ready"
  of ssRunning: "running"
  of ssCompleted: "completed"
  of ssFailed: "failed"
  of ssCancelled: "cancelled"

proc toJson*(handle: SubagentHandle): JsonNode =
  ## Convert subagent handle to JSON for tool results
  result = %*{
    "id": handle.id,
    "name": handle.name,
    "status": $handle.status,
    "createdAt": $handle.createdAt,
    "model": handle.config.model,
    "role": handle.config.role
  }
  
  if handle.currentTask.isSome:
    result["currentTask"] = %handle.currentTask.get()
  
  if handle.result.isSome:
    let r = handle.result.get()
    result["result"] = %*{
      "success": r.success,
      "output": r.output,
      "toolCalls": r.toolCalls,
      "tokensUsed": r.tokensUsed,
      "elapsedMs": r.elapsed.inMilliseconds,
      "error": if r.error.isSome: r.error.get() else: ""
    }

proc toJson*(subagentResult: SubagentResult): JsonNode =
  ## Convert subagent result to JSON
  %*{
    "success": subagentResult.success,
    "output": subagentResult.output,
    "toolCalls": subagentResult.toolCalls,
    "tokensUsed": subagentResult.tokensUsed,
    "elapsedMs": subagentResult.elapsed.inMilliseconds,
    "error": if subagentResult.error.isSome: subagentResult.error.get() else: "",
    "artifacts": subagentResult.artifacts
  }

# -----------------------------------------------------------------------------
# Implementation of forward-declared procs (at end to avoid circular imports)
# -----------------------------------------------------------------------------

import ../primitives/tick

proc runTaskAsync(handle: SubagentHandle, task: string, maxToolCalls: int = 0): Future[SubagentResult] {.async, gcsafe.} =
  ## Internal: Run a task on a subagent asynchronously
  
  handle.status = ssRunning
  handle.currentTask = some(task)
  handle.cancelToken = false
  
  emitSubagentEvent(handle, sekStarted, %*{ "task": task })
  
  let startTime = now()
  var toolCallCount = 0
  var artifacts: seq[string] = @[]
  
  try:
    let maxCalls = if maxToolCalls > 0: maxToolCalls else: handle.config.policy.maxToolCalls
    
    # Run the chat turn
    let tickResult = await tick.chatTurn(handle.agent, task, maxToolCalls = maxCalls)
    
    let elapsed = now() - startTime
    
    # Check if cancelled during execution
    if handle.cancelToken:
      handle.status = ssCancelled
      result = SubagentResult(
        success: false,
        output: "Cancelled by parent",
        toolCalls: tickResult.toolCalls.len,
        tokensUsed: tickResult.tokensUsed,
        elapsed: elapsed,
        error: some("Cancelled by parent"),
        artifacts: artifacts
      )
      emitSubagentEvent(handle, sekCancelled, %*{})
      return
    
    # Success
    handle.status = ssCompleted
    result = SubagentResult(
      success: true,
      output: tickResult.text,
      toolCalls: tickResult.toolCalls.len,
      tokensUsed: tickResult.tokensUsed,
      elapsed: elapsed,
      error: none(string),
      artifacts: artifacts
    )
    handle.result = some(result)
    emitSubagentEvent(handle, sekCompleted, %*{ 
      "tokens": tickResult.tokensUsed,
      "toolCalls": tickResult.toolCalls.len
    })
    
  except CatchableError as e:
    let elapsed = now() - startTime
    handle.status = ssFailed
    result = SubagentResult(
      success: false,
      output: "",
      toolCalls: toolCallCount,
      tokensUsed: 0,
      elapsed: elapsed,
      error: some(e.msg),
      artifacts: artifacts
    )
    handle.result = some(result)
    emitSubagentEvent(handle, sekFailed, %*{ "error": e.msg })
