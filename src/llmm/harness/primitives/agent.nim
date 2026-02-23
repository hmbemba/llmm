import std/[
  json,
  times,
  options,
  asyncdispatch,
  strformat,
  private/ospaths2,
  os,
  tables,
  sequtils
]

import sessions
import store
import ../tools/base
import ../../general_helpers

# Default provider (OpenAI Responses)
import ../providers/base as prov
import ../providers/openai_responses
import ../tools/codeact

import ./mem/[
  memory,
  memory_tool,
  knowledge,
  knowledge_tool
]

import ../../embeddings

import ic,rz

# Forward declaration for subagent support - actual type defined in subagents.nim
# We use a base type to avoid circular dependency while maintaining GC safety

type
  SubagentRegistryBase* = ref object of RootObj  ## Base type for subagent registry (extended in subagents.nim)
  FailureKind* = enum
    fkTimeout
    fkmaxToolCalls
    fkToolError
    fkApiError
    fkValidationError
    fkUserAbort
    fkUnknownTool

  AgentEventKind* = enum
    aekThinking      # model is reasoning (before tool calls)
    aekToolCall      # about to execute a tool
    aekToolResult    # tool returned
    aekMessage       # model produced text output
    aekCheckpoint    # HITL pause point
    aekError         # something went wrong

  AgentEvent* = object
    timestamp*        : DateTime
    numSpawn*         : int
    tokensUsed*       : int
    cumulativeTokens* : int
    elapsed*          : Duration

    case kind*: AgentEventKind
    of aekThinking:
      thought*: string

    of aekToolCall:
      callToolName*: string
      callToolArgs*: JsonNode
      callToolId*  : string

    of aekToolResult:
      resultToolId*: string
      resultOutput*: JsonNode
      resultOk*    : bool
      resultError* : string

    of aekMessage:
      msgText*: string

    of aekCheckpoint:
      checkpointReason* : string
      checkpointPending*: JsonNode

    of aekError:
      errorKind*       : FailureKind
      errorMessage*    : string
      errorRecoverable*: bool

  EventHandler* = proc(e: AgentEvent) {.gcsafe.}

  EventDispatcher* = object
    handlers: Table[AgentEventKind, seq[EventHandler]]
    globalHandlers: seq[EventHandler] # fire on ALL events

  AgentPolicy* = object
    maxToolCalls*       = 100
    maxTokens*          : int
    timeout*            : Duration
    allowedTools*       : seq[string]
    hitlEvery*          : int
    requireCheckpoints* : bool

  AgentState* = object
    failureTracker* : ToolFailureTracker
    totalTokensUsed*: tuple[input: int, output: int, combined: int]
    events*         : EventDispatcher
    session*        : sessions.ChatSession
    memoryStore*    : MemoryStore
    agentStore*     : AgentStore       ## Unified SQLite storage
    knowledgeStore* : KnowledgeStore
    subagentRegistry*: SubagentRegistryBase  ## Child agents (nil if not using subagents). Cast to SubagentRegistry in subagents.nim

  AgentConfig* = object
    id*               : string
    name*             : string
    role*             : string
    model*            : string

    systemPrompt*     : string
    instructions*     : string

    workspaceDir*     : string
    dbPath*           : string           ## Path to unified SQLite database

    tools*            : OrderedTable[string, Tool]
    policy*           : AgentPolicy
    enableReflection* = true # Post-turn memory reflection

    knowledgeConfig*  : KnowledgeConfig  ## Chunking/batch settings

  Agent* = ref object
    ## Provider used by tick/chatTurn.
    provider* : prov.LlmProvider

    cfg*      : AgentConfig
    state*    : AgentState


include agent/events
include agent/tools

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------
proc new*(a: Agent, lightweight: bool = false): Agent =
  ## Initialize an agent.
  ## 
  ## Parameters:
  ##   lightweight: If true, skip heavy initializations (KnowledgeStore, MemoryStore).
  ##                Use for subagents that don't need memory/knowledge capabilities.
  # Default provider if none was provided
  if a.provider.isNil:
    raise newException(ValueError, "No Agent.provider was provided")
    #if a.client.isNil:
    #a.provider = newOpenAIResponsesProvider(a.client)


  # Assign defaults for workspace directory if not provided
  if a.cfg.workspaceDir.len == 0:
    a.cfg.workspaceDir = getCurrentDir() / "workspace"

  # Default dbPath: workspace / agent_<slug>_<id>.db
  if a.cfg.dbPath.len == 0:
    a.cfg.dbPath = a.cfg.workspaceDir / &"agent_{a.cfg.name.toSlug}_{a.cfg.id}.db"

  if a.state.session.isNil:
    a.state.session = newChatSession()

  # Initialize the unified AgentStore (creates all tables)
  if a.state.agentStore.isNil:
    icb "Initializing AgentStore"
    discard dirExistsOrMk a.cfg.workspaceDir
    a.state.agentStore = newAgentStore(a.cfg.dbPath)

  # Ensure the active session is tracked in the database
  discard a.state.agentStore.ensureSessionExists(
    a.state.session.id,
    a.state.session.name
  )

  # Initialize MemoryStore using the shared Db handle (skip for lightweight subagents)
  if not lightweight and a.state.memoryStore.isNil:
    icb "Initializing MemoryStore (shared db)"
    a.state.memoryStore = newMemoryStore(a.state.agentStore.db)

  # Ensure the memory tool is registered for this agent (skip for lightweight)
  if not lightweight:
    a.addTools MemoryTool(a.state.memoryStore)

  # Initialize KnowledgeStore (skip for lightweight subagents)
  if not lightweight and a.state.knowledgeStore.isNil:
    icb "Initializing KnowledgeStore"

    # Note: KnowledgeStore.client is optional - only needed for ingest/search operations
    # Reading documents works without a client

    var vectorExtPath = ""
    if a.cfg.knowledgeConfig.vectorExtPath.len > 0:
      vectorExtPath = a.cfg.knowledgeConfig.vectorExtPath
    else:
      when defined windows:
        vectorExtPath = fileExistsOrErr currentSourcePath.parentDir.parentDir.parentDir.parentDir / "deps/vector.dll"
      elif defined linux:
        vectorExtPath = fileExistsOrErr currentSourcePath.parentDir.parentDir.parentDir.parentDir / "deps/vector.so"
      elif defined darwin:
        vectorExtPath = fileExistsOrErr currentSourcePath.parentDir.parentDir.parentDir.parentDir / "deps/vector.dylib"
      else:
        raise newException(ValueError, "Unsupported OS for default sqlite-vector extension path")

    ic vectorExtPath

    a.state.knowledgeStore = newKnowledgeStore(
      db                   = a.state.agentStore.db,
      vectorExtPath        = vectorExtPath,
      config               = a.cfg.knowledgeConfig
    )

    # Register the knowledge tool
    a.addTools KnowledgeTool(a.state.knowledgeStore)

  return a

# ---------------------------------------------------------------------------
# CodeAct Integration
# ---------------------------------------------------------------------------
proc enableCodeAct*(a: Agent, pythonExe: string = "") =
  ## Enable CodeAct for this agent - allows the LLM to write Python code
  ## that can call other tools. Each agent gets its own persistent Python process.
  ##
  ## Parameters:
  ##   pythonExe: Path to Python executable (auto-detected if empty)
  ##             On Windows uses 'python', on Unix uses 'python3'
  ##
  ## Example:
  ##   var agent = new Agent(...)
  ##   agent.enableCodeAct()  # Auto-detect Python
  ##   # or
  ##   agent.enableCodeAct("python3.11")  # Use specific Python
  
  # Create dispatch closure that uses the agent's tools
  let dispatch: CodeActDispatch = proc(name: string, args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
    if not a.cfg.tools.hasKey(name):
      return toolError("Unknown tool: " & name)
    # Execute the tool handler
    return await a.cfg.tools[name].handler(args)
  
  # Get list of available tools from agent's tools table
  var availableTools: seq[string] = @[]
  for toolName in a.cfg.tools.keys:
    availableTools.add(toolName)
  
  # Create the CodeAct runtime with per-agent Python process
  let rt = newCodeActRuntime(
    workspaceDir = a.cfg.workspaceDir,
    dispatch = dispatch,
    availableTools = availableTools,
    pythonExe = pythonExe
  )
  
  # Add the codeact_tool to the agent
  a.addTools CodeActTool(rt)
  
  # Append CodeAct guidance to system prompt
  let codeActPrompt = """

---
CODEACT CAPABILITY: You have access to a Python interpreter via the `codeact_tool`. 

WHEN TO USE CODEACT:
- Use codeact_tool when you need to perform calculations, data processing, or multi-step operations
- Use it when you need to chain multiple tool calls together with logic/conditionals
- Use it for file content analysis, text processing, or complex transformations
- Prefer codeact_tool over multiple separate tool calls when the operations are related

HOW TO USE CODEACT:
- Write Python code that can call other tools using: tools("tool_name", arg1=value1, arg2=value2)
- OR use direct syntax: tool_name(arg1=value1, arg2=value2)
- Variables and imports persist across codeact_tool calls
- The Python environment is persistent for this agent session
- AVOID printing full tool results - print small summaries only to save tokens
- Return values from tools() are JSON dictionaries you can work with in Python

"""
  a.cfg.systemPrompt &= codeActPrompt
  
  ic "CodeAct enabled for agent", a.cfg.name

# Note: enableSubagents proc is defined in subagents.nim to avoid circular imports

# ---------------------------------------------------------------------------
# Session management (for REPL use)
# ---------------------------------------------------------------------------

proc switchSession*(a: Agent, sessionId: string, name: string = "") =
  ## Switch the agent to a different session. Clears in-memory conversation
  ## state and ensures the session is tracked in the database.
  icb "switchSession", sessionId, name

  let sessionName = if name.len > 0: name else: "Session " & sessionId[^6..^1]

  # Create new in-memory session
  a.state.session = ChatSession(
    id        : sessionId,
    name      : sessionName,
    createdAt : now(),
    messages  : @[]
  )

  # Ensure it exists in the db
  discard a.state.agentStore.ensureSessionExists(sessionId, sessionName)

  ic "Switched to session", sessionId, sessionName

proc currentSessionId*(a: Agent): string =
  ## Returns the current session's id.
  a.state.session.id
