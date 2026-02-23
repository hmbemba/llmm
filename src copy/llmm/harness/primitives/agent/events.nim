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
            #,numSpawn         : a.numSpawns
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
        a                 : Agent
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
    # proc newEventDispatcher*(): EventDispatcher = EventDispatcher(
    #     handlers: initTable[AgentEventKind, seq[EventHandler]]()
    #     ,globalHandlers: @[]
    # )

    proc on*(d: var EventDispatcher, kind: AgentEventKind, handler: EventHandler) =
        d.handlers.mgetOrPut(kind, @[]).add(handler)

    proc onAny*(d: var EventDispatcher, handler: EventHandler) =
        d.globalHandlers.add(handler)

    proc emit*(d: EventDispatcher, event: AgentEvent) =
        # Fire kind-specific handlers
        if d.handlers.hasKey(event.kind):
            for h in d.handlers[event.kind]:
                h(event)
        # Fire global handlers
        for h in d.globalHandlers:
            h(event)

    proc clear*(d: var EventDispatcher, kind: AgentEventKind) =
        d.handlers.del(kind)

    proc clearAll*(d: var EventDispatcher) =
        d.handlers.clear()
        d.globalHandlers.setLen(0)


    # Convenience templates for the nice DSL
    template onErr*(a: Agent, body: untyped) =
        a.state.events.on(aekError, proc(e {.inject.}: AgentEvent) = body)

    template onToolCall*(a: Agent, body: untyped) =
        a.state.events.on(aekToolCall, proc(e {.inject.}: AgentEvent) = body)

    template onToolResult*(a: Agent, body: untyped) =
        a.state.events.on(aekToolResult, proc(e {.inject.}: AgentEvent) = body)

    template onMessage*(a: Agent, body: untyped) =
        a.state.events.on(aekMessage, proc(e {.inject.}: AgentEvent) = body)

    template onThinking*(a: Agent, body: untyped) =
        a.state.events.on(aekThinking, proc(e {.inject.}: AgentEvent) = body)

    template onCheckpoint*(a: Agent, body: untyped) =
        a.state.events.on(aekCheckpoint, proc(e {.inject.}: AgentEvent) = body)

discard """
var coder = newAgent(...)

# Log all errors to stderr
coder.onErr:
    stderr.writeLine "ERROR: " & e.errorMessage

# ALSO send errors to a webhook (doesn't clobber the above)
coder.onErr:
    asyncCheck sendWebhook("agent-errors", e.errorMessage)

# Track tool usage
coder.onToolCall:
    echo "⚡ Calling: " & e.callToolName

# Show assistant output
coder.onMessage:
    echo e.msgText

# Global logger that fires on everything
coder.events.onAny proc(e: AgentEvent) =
    appendToJsonFile("event_log.jsonl", %e)
"""