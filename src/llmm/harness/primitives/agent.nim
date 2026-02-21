import std/[
json
,times
,options
,asyncdispatch
,strformat
,private/ospaths2
,os
,tables
,sequtils

]
,sessions
,store
,../tools/base
,../../providers/oai/responses/types
,../../providers/oai/oai_client
,../../providers/oai/utils/builders
,../../general_helpers


import ./mem/[
memory
,memory_tool
,knowledge
,knowledge_tool
]
import ../../embeddings

import ic,rz


type
    FailureKind * = enum
        fkTimeout
        fkmaxToolCalls
        fkToolError
        fkApiError
        fkValidationError
        fkUserAbort
        fkUnknownTool

    AgentEventKind * = enum
        aekThinking      # model is reasoning (before tool calls)
        aekToolCall      # about to execute a tool
        aekToolResult    # tool returned
        aekMessage       # model produced text output
        aekCheckpoint    # HITL pause point
        aekError         # something went wrong

    AgentEvent           * = object
        timestamp        * : DateTime
        numSpawn         * : int
        tokensUsed       * : int
        cumulativeTokens * : int
        elapsed          * : Duration
        
        case kind * : AgentEventKind
        of aekThinking:
            thought * : string
            
        of aekToolCall:
            callToolName * : string
            callToolArgs * : JsonNode
            callToolId   * : string
            
        of aekToolResult:
            resultToolId * : string
            resultOutput * : JsonNode
            resultOk     * : bool
            resultError  * : string
            
        of aekMessage:
            msgText * : string
            
        of aekCheckpoint:
            checkpointReason  * : string
            checkpointPending * : JsonNode
            
        of aekError:
            errorKind        * : FailureKind
            errorMessage     * : string
            errorRecoverable * : bool

    EventHandler* = proc(e: AgentEvent) 

    EventDispatcher     * = object
        handlers        : Table[AgentEventKind, seq[EventHandler]]
        globalHandlers  : seq[EventHandler]  # fire on ALL events

    AgentPolicy            * = object
        maxToolCalls       * = 100
        maxTokens          * : int
        timeout            * : Duration
        allowedTools       * : seq[string]
        hitlEvery          * : int
        requireCheckpoints * : bool

    AgentState           * = object
        failureTracker   * : ToolFailureTracker
        totalTokensUsed  * : tuple[input: int, output: int, combined: int]
        events           * : EventDispatcher
        session          * : sessions.ChatSession
        memoryStore      * : MemoryStore
        agentStore       * : AgentStore       ## Unified SQLite storage
        knowledgeStore   * : KnowledgeStore

    AgentConfig          * = object
        id               * : string
        name             * : string
        role             * : string
        model            * : string

        systemPrompt     * : string
        instructions     * : string

        workspaceDir     * : string
        dbPath           * : string           ## Path to unified SQLite database

        tools            * : OrderedTable[string, Tool]
        policy           * : AgentPolicy
        enableReflection * = true # Post-turn memory reflection
        
        knowledgeConfig  * : KnowledgeConfig  ## Chunking/batch settings


    Agent                * = ref object
        client           * : OpenAIClient
        cfg              * : AgentConfig
        state            * : AgentState


include agent/events
include agent/tools

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------
proc new*(a : Agent) : Agent =
    if a.client.isNil: raise newException(ValueError, "Agent's client is not initialized")

    # Assign defaults for workspace directory if not provided
    if a.cfg.workspaceDir.len == 0: a.cfg.workspaceDir = getCurrentDir() / "workspace"

    # Default dbPath: workspace / agent_<slug>_<id>.db
    if a.cfg.dbPath.len == 0: a.cfg.dbPath = a.cfg.workspaceDir / &"agent_{a.cfg.name.toSlug}_{a.cfg.id}.db"

    if a.state.session.isNil: a.state.session = sessions.ChatSession(createdAt : now())

    # Initialize the unified AgentStore (creates all tables)
    if a.state.agentStore.isNil:
        icb "Initializing AgentStore"
        discard dirExistsOrMk a.cfg.workspaceDir
        a.state.agentStore = newAgentStore(a.cfg.dbPath)

    # Initialize MemoryStore using the shared Db handle
    if a.state.memoryStore.isNil:
        icb "Initializing MemoryStore (shared db)"
        a.state.memoryStore = newMemoryStore(a.state.agentStore.db)
    
    # Ensure the memory tool is registered for this agent
    a.addTools MemoryTool(a.state.memoryStore)


    # Initialize KnowledgeStore if vector extension path is configured
    if a.state.knowledgeStore.isNil:
        icb "Initializing KnowledgeStore"

        # Create the embedding provider
        let embedder = a.client.newOpenAIEmbedder()

        var vectorExtPath = ""
        if a.cfg.knowledgeConfig.vectorExtPath.len > 0:
            vectorExtPath = a.cfg.knowledgeConfig.vectorExtPath
        else:
            when defined windows:
                vectorExtPath = fileExistsOrErr currentSourcePath.parentDir.parentDir.parentDir.parentDir / "deps/vector.dll"  ## default path to vect
            elif defined linux:
                vectorExtPath = fileExistsOrErr currentSourcePath.parentDir.parentDir.parentDir.parentDir / "deps/vector.so"
            elif defined darwin:
                vectorExtPath = fileExistsOrErr currentSourcePath.parentDir.parentDir.parentDir.parentDir / "deps/vector.dylib"
            else:
                raise newException(ValueError, "Unsupported OS for default sqlite-vector extension path")
        
        ic vectorExtPath
        
        a.state.knowledgeStore = newKnowledgeStore(
            db                 = a.state.agentStore.db
            ,embedder          = embedder
            ,vectorExtPath     = vectorExtPath
            ,config            = a.cfg.knowledgeConfig
        )

        # Register the knowledge tool
        a.addTools KnowledgeTool(a.state.knowledgeStore)


    return a