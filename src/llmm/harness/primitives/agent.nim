import std/[
json
,times
,options
,asyncdispatch
,strformat
,private/ospaths2
,os
,tables

]
,sessions
,../tools/base
,../../providers/oai/responses/types
,../../providers/oai/oai_client
,../../providers/oai/utils/builders
,../../general_helpers
,./memory/tool        


import ./memory/types
import ./memory/store  
import ./memory/integration

import ic

type
    FailureKind * = enum
        fkTimeout
        fkmaxToolCalls
        fkToolError
        fkApiError
        fkValidationError
        fkUserAbort

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

    AgentPolicy            * = object
        maxToolCalls       * = 50
        maxTokens          * : int
        timeout            * : Duration
        allowedTools       * : seq[string]
        hitlEvery          * : int
        requireCheckpoints * : bool

    ToolRegistry  * = object
        tools     * : Table[string, Tool]
        registry  * : seq[string]

    Agent                * = ref object
        ####### Config
        client           * : OpenAIClient
        id               * : string
        name             * : string
        role             * : string
        model            * : string
        
        systemPrompt     * : string
        instructions     * : string
        
        workspaceDir     * : string
        artifactsDir     * : string
        memoryStore      * : MemoryStore           

        onEvent          * : proc(e: AgentEvent) 
        tools            * : ToolRegistry
        policy           * : AgentPolicy
        enableReflection * : bool                  ## Post-turn memory reflection
        
        # Runtime Properties 
        # Persistent memory (lazy-init)
        # in memory/store.nim

        #scratchpad       * : string                
        #eventHistory     * : seq[AgentEvent]      
        session          * : sessions.ChatSession
        # Works by appending to a seq[JsonNode] called session.messages
        # Agent sends the entire session.messages as context for each turn

        failureTracker   * : ToolFailureTracker   
        numSpawns        * : int
        totalTokensUsed  * : tuple[input: int, output: int, combined: int]


include agent_events



# ---------------------------------------------------------------------------
# Tool registration (unchanged)
# ---------------------------------------------------------------------------

proc addTools *(tool: Tool) : ToolRegistry =
    var registry  = ToolRegistry(
        tools     : initTable[string, Tool]()
        ,registry : @[]
    )
    registry.tools[tool.name] = tool
    registry.registry.add(tool.name)
    return registry

proc addTools *(tk : Toolkit) : ToolRegistry =
    var registry  = ToolRegistry(
        tools     : initTable[string, Tool]()
        ,registry : @[]
    )
    for tool in tk.tools:
        registry.tools[tool.name] = tool
        registry.registry.add(tool.name)
    return registry

proc tool_already_registered*(agent: Agent, toolName: string): bool =
    return toolName in agent.tools.registry

proc addTools * (newTools: seq[Tool]) : ToolRegistry =
    var registry  = ToolRegistry(
        tools     : initTable[string, Tool]()
        ,registry : @[]
    )
    for tool in newTools:
        registry.tools[tool.name] = tool
        registry.registry.add(tool.name)
    return registry

proc addTools * (agent: Agent, newTools: seq[Tool]) =
    for tool in newTools:
        if agent.tool_already_registered(tool.name): continue
        agent.tools.tools[tool.name] = tool
        agent.tools.registry.add(tool.name)

proc addTools * (agent: Agent, tool: Tool) =
    if agent.tool_already_registered(tool.name): return
    agent.tools.tools[tool.name] = tool
    agent.tools.registry.add(tool.name)

proc addTools * (agent: Agent, toolkit: Toolkit) =
    for tool in toolkit.tools:
        if agent.tool_already_registered(tool.name): continue
        agent.tools.tools[tool.name] = tool
        agent.tools.registry.add(tool.name)

proc addTools * (agent: Agent, toolkit: seq[Toolkit]) =
    for tk in toolkit:
        for tool in tk.tools:
            if agent.tool_already_registered(tool.name): continue
            agent.tools.tools[tool.name] = tool
            agent.tools.registry.add(tool.name)

proc `%`*(zone: Timezone): JsonNode =
    %zone.name



# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

proc new*(a : Agent) : Agent =
    if a.client.isNil: raise newException(ValueError, "Agent's client is not initialized")

    if a.workspaceDir.len == 0: a.workspaceDir = getCurrentDir() / "workspace"
    if a.artifactsDir.len == 0: a.artifactsDir = a.workspaceDir  / ".artifacts" / &"agent_{a.name.toSlug}_{a.id}"

    if a.session.isNil:
        a.session = sessions.ChatSession(createdAt : now())

    # ===== A: MEMORY INITIALIZATION & AUTO-INJECTION =====
    if a.memoryStore.isNil:
        icb "Initializing memory store"
        a.memoryStore = initAgentMemoryStore(
            a.artifactsDir
            ,a.name.toSlug
            ,a.id
        )


    # Reset failure tracker each turn
    a.failureTracker = newToolFailureTracker()


    if a.memoryStore.filepath.fileExists and a.memoryStore.entries.len == 0:
        icb "Memory store file exists but no entries found, loading from disk"
        a.memoryStore = newMemoryStore(a.memoryStore.filepath)
    
    # Ensure the memory tool is registered for this agent
    let memTool = MemoryTool(a.memoryStore)
    a.addTools(memTool)

    return a


when isMainModule:
    import mynimlib/[
        keys
    ]
    from mynimlib.utils import dirExistsOrMk
    
    import ic
    ,pretty
    ,asyncdispatch
    ,oids
    ,termui
    
    import ./tick
    ,../../tools
    ,./memory/tool

    
    discard """
    nim r -d:ic -d:ssl src/llmm/harness/primitives/agent.nim
    """
    blok "Setup Workspace":
        let 
            client         = OpenAIClient(apiKey : keys.open_ai_api_key)
            workDir        = currentSourcePath.parentDir / "workspace"
            workspaceDir   = dirExistsOrMk workDir
            artifactsDir   = dirExistsOrMk workDir / ".artifacts"
    blok "Create Agent and assign Tools":
        var coder = newAgent(
            client        = client
            ,id           = "6986b334c7ed8271f680661a"
            ,name         = "Coder"
            ,role         = "Software Engineer"
            ,model        = "gpt-4o-mini"
            ,systemPrompt = "You are a senior software engineer. Write clean, well-documented code."
            ,workspaceDir = workspaceDir
            ,artifactsDir = artifactsDir
            ,policy       = AgentPolicy(maxToolCalls : 10)
            ,tools        = addTools @[HITLTool(), FileCreateTool(workDir), webSearchTool()]
            ,enableReflection = true
        )

    blok "Set Event Handlers":
        coder.onErr:
            icr e.errorMessage,e

    blok "Run Agent":
        var resp = waitFor coder.ask"what am i working on?"
        ic resp