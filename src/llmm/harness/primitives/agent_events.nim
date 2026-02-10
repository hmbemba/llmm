blok "Event Helpers":
    proc newAgentEvent*(
        a                 : Agent
        ,tokensUsed       : int = 0
        ,cumulativeTokens : int = 0
        ,elapsed          : Duration = initDuration(seconds = 0)
        ,kind             : AgentEventKind 
    ) : AgentEvent =
        AgentEvent(
            timestamp         : now()
            ,numSpawn         : a.numSpawns
            ,tokensUsed       : tokensUsed
            ,cumulativeTokens : cumulativeTokens
            ,elapsed          : elapsed
            ,kind             : kind
        )


    proc ThinkingEvent*(
        a                : Agent
        ,thought          : string
        ,tokensUsed       : int = 0
        ,cumulativeTokens : int = 0
        ,elapsed          : Duration = initDuration(seconds = 0)
    ) : AgentEvent =
        result = newAgentEvent(a, tokensUsed, cumulativeTokens, elapsed, aekThinking)
        result.thought = thought

    proc ToolCallEvent*(
        a                : Agent
        ,callToolName     : string
        ,callToolArgs     : JsonNode
        ,callToolId       : string
        ,tokensUsed       : int = 0
        ,cumulativeTokens : int = 0
        ,elapsed          : Duration = initDuration(seconds = 0)
    ) : AgentEvent =
        result = newAgentEvent(a, tokensUsed, cumulativeTokens, elapsed, aekToolCall)
        result.callToolName = callToolName
        result.callToolArgs = callToolArgs
        result.callToolId   = callToolId

    proc ToolResultEvent*(
        a                : Agent
        ,resultToolId     : string
        ,resultOutput     : JsonNode
        ,resultOk         : bool
        ,resultError      : string = ""
        ,tokensUsed       : int = 0
        ,cumulativeTokens : int = 0
        ,elapsed          : Duration = initDuration(seconds = 0)
    ) : AgentEvent =
        result = newAgentEvent(a, tokensUsed, cumulativeTokens, elapsed, aekToolResult)
        result.resultToolId = resultToolId
        result.resultOutput = resultOutput
        result.resultOk     = resultOk
        result.resultError  = resultError

    proc MessageEvent*(
        a                : Agent
        ,msgText          : string
        ,tokensUsed       : int = 0
        ,cumulativeTokens : int = 0
        ,elapsed          : Duration = initDuration(seconds = 0)
    ) : AgentEvent =
        result         = newAgentEvent(a, tokensUsed, cumulativeTokens, elapsed,aekMessage)
        result.msgText = msgText

    proc CheckpointEvent*(
        a                   : Agent
        ,checkpointReason   : string
        ,checkpointPending  : JsonNode = newJNull()
        ,tokensUsed         : int = 0
        ,cumulativeTokens   : int = 0
        ,elapsed            : Duration = initDuration(seconds = 0)
    ) : AgentEvent =
        result = newAgentEvent(a, tokensUsed, cumulativeTokens, elapsed, aekCheckpoint)
        result.checkpointReason   = checkpointReason
        result.checkpointPending  = checkpointPending

    proc ErrorEvent*(
        a                : Agent
        ,errorKind        : FailureKind
        ,errorMessage     : string
        ,errorRecoverable : bool = false
        ,tokensUsed       : int = 0
        ,cumulativeTokens : int = 0
        ,elapsed          : Duration = initDuration(seconds = 0)
    ) : AgentEvent =
        result = newAgentEvent(a, tokensUsed, cumulativeTokens, elapsed, aekError)
        result.errorKind        = errorKind
        result.errorMessage     = errorMessage
        result.errorRecoverable = errorRecoverable

blok "Event Handling":
    proc emitEvent * (agent: Agent, event: AgentEvent) =
        #agent.memory.history.add(event)
        if agent.onEvent != nil:
            agent.onEvent(event)


    # template onErr*(body : untyped) =
    #     e.kind == aekError:
    #         body
    
    # template onErr*(a: Agent, body : untyped) =
    #     a.onEvent = proc(e {.inject.} : AgentEvent) =
    #         if e.kind == aekError:
    #             body
    
    # template onToolCall*(a: Agent, body : untyped) =
    #     a.onEvent = proc(e {.inject.} : AgentEvent) =
    #         if e.kind == aekToolCall:
    #             body
    
    # template onToolResult*(a: Agent, body : untyped) =
    #     a.onEvent = proc(e {.inject.} : AgentEvent) =
    #         if e.kind == aekToolResult:
    #             body
    
    # template onMessage*(a: Agent, body : untyped) =
    #     a.onEvent = proc(e {.inject.} : AgentEvent) =
    #         if e.kind == aekMessage:
    #             body
    
    # template onThinking*(a: Agent, body : untyped) =
    #     a.onEvent = proc(e {.inject.} : AgentEvent) =
    #         if e.kind == aekThinking:
    #             body
    
    # template onCheckpoint*(a: Agent, body : untyped) =
    #     a.onEvent = proc(e {.inject.} : AgentEvent) =
    #         if e.kind == aekCheckpoint:
    #             body
    
    # template onDone*(a: Agent, body : untyped) =
    #     a.onEvent = proc(e {.inject.} : AgentEvent) =
    #         if e.kind == aekDone:
    #             body
    
    # template onStateUpdate*(a: Agent, body : untyped) =
    #     a.onEvent = proc(e {.inject.} : AgentEvent) =
    #         if e.kind == aekStateUpdate:
    #             body
    
