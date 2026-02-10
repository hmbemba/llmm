# =============================================================================
# tick.nim - Core agent execution
# =============================================================================

import std/[
json
,times
,options
,asyncdispatch
,strformat
,strutils
,sugar
,tables
]
import std/[selectors, os, times]

import rz
,ic
,os
import agent
,sessions
,../tools/base
,../../general_helpers
,../../providers/oai/oai_client
,../../providers/oai/common/types
,../../providers/oai/utils/builders
,../../providers/oai/responses/types
,../../providers/oai/responses/api
,../../providers/oai/responses/utils

,./memory/types
,./memory/store
,./memory/tool        
,./memory/integration


type 
    TickResult      * = object
        events      * : seq[AgentEvent]
        text        * : string
        toolCalls   * : seq[FunctionCall]
        toolResults * : seq[JsonNode]
        tokensUsed  * : int
        elapsed     * : Duration
        done        * : bool
        error       * : Option[string]


proc appendToJsonFile*(filepath : string, content : JsonNode)  = 
    if not filepath.fileExists:
        writeFile(filepath, pretty content)
        return 

    let file_as_json = parseJson(readFile(filepath))
    if file_as_json.kind != JArray:
        raise newException(ValueError, fmt"File {filepath} is not a JSON array")
    file_as_json.add content
    writeFile(filepath, pretty file_as_json)


# ---------------------------------------------------------------------------
# Reflection mini-loop
# ---------------------------------------------------------------------------

proc runReflection(a: Agent, lastResponseId: string) {.async.} =
    ## Fire a reflection turn after task completion.
    ## The LLM gets the reflection prompt + only the memory tool.
    ## Any memory tool calls are executed, then we're done.
    ## This is "invisible" — nothing goes into session history.
    
    let 
        memTool     = MemoryTool(a.memoryStore)
        reflectMsgs = buildReflectionMessages()
    
    var reflectOpts = CreateResponseOptions(
        model               : a.model
        ,tools              : some @[%memTool]
        ,previousResponseId : some lastResponseId
        ,input              : some %reflectMsgs
    )
    
    var resp = await a.client.createResponse(reflectOpts)
    if not resp.ok:
        # Reflection failure is non-fatal — just log and move on
        
        icr "Reflection API error", resp.err
        return
    
    # Mini tool loop: handle memory tool calls from reflection
    var loopCount = 0
    const maxReflectionLoops = 3  # Safety cap
    
    while resp.hasFunctionCalls and loopCount < maxReflectionLoops:
        loopCount.inc
        var toolResults: seq[JsonNode] = @[]
        
        for fc in resp.functionCalls:
            # Only execute memory tool calls — ignore anything else
            if fc.name == memTool.name:
                let payload = await memTool.handler(fc.arguments)
                toolResults.add(functionOutput(fc.callId, payload))
            else:
                toolResults.add(functionOutput(fc.callId, 
                    toolError("Only memory tool is available during reflection")))
        
        # Chain and continue
        reflectOpts.previousResponseId = some resp.id
        reflectOpts.input              = some %toolResults
        resp = await a.client.createResponse(reflectOpts)
        
        if not resp.ok:
            
            icr "Reflection loop error", resp.err
            break
    
    # Done — reflection results are silently stored in memory.json
    # Nothing is added to session history or returned to the user.


# ---------------------------------------------------------------------------
# Main chat turn
# ---------------------------------------------------------------------------

proc chatTurn*(
    a             : Agent
    ,userText     : string
    ,useChaining  = false
    ,maxToolCalls = 0
): Future[TickResult] {.async.} =



    # Augment system prompt with relevant memories + memory instructions
    let augmentedSystemPrompt = injectMemoryContext(
        store                 = a.memoryStore
        ,userMessage          = userText
        ,systemPrompt         = a.systemPrompt
        ,maxMemories          = 5
    )

    icb augmentedSystemPrompt

    blok "Ensure agent dirs exist":
        discard dirExistsOrMk a.workspaceDir
        discard dirExistsOrMk a.artifactsDir

    a.numSpawns.inc

    let
        maxTC = max(maxToolCalls, a.policy.maxToolCalls)
        tools : seq[JsonNode] = collect:
            for toolName in a.tools.registry:
                let t = a.tools.tools[toolName]
                if t.isBuiltIn: t.parameters else: %t

    var
        this_tick_result : TickResult
        totalTokensUsed  : tuple[input: int, output: int, combined: int]
        startTime        = now()
        numToolCalls     = 0
        allResponses     : seq[rz.Rz[OpenAIResponse]]
        allReqOpts       : seq[CreateResponseOptions]

    let userMsg = builders.userMessage(userText)

    var req_opts = CreateResponseOptions(
        model           : a.model
        ,tools          : (if tools.len > 0: some tools else: none seq[JsonNode])
        ,instructions   : (if a.instructions.len > 0: some a.instructions else: none string)
    )

    if useChaining and a.session.lastResponseId.isSome:
        req_opts.previousResponseId = a.session.lastResponseId
        req_opts.input              = some %*[userMsg]
    else:
        var req_input = newJArray()
        if augmentedSystemPrompt.len > 0:
            req_input.add builders.systemMessage(augmentedSystemPrompt)

        for m in a.session.messages:
            req_input.add m

        req_input.add userMsg
        req_opts.input = some(req_input)

    allReqOpts.add req_opts
    a.session.messages.add userMsg

    var resp = await a.client.createResponse(req_opts)
    allResponses.add resp

    if not resp.ok:
        discard a.session.messages.pop()
        let apiErrEvent   = a.ErrorEvent(
            errorKind     = fkApiError
            ,errorMessage = resp.err
            ,elapsed      = now() - startTime
        )
        a.emitEvent(apiErrEvent)
        this_tick_result.events.add(apiErrEvent)

        this_tick_result.error   = some(resp.err)
        this_tick_result.elapsed = now() - startTime
        this_tick_result.done    = false

        appendToJsonFile(a.artifactsDir / "events.json"         ,   %this_tick_result.events )
        appendToJsonFile(a.artifactsDir / "all_responses.json"  ,   %allResponses            )
        appendToJsonFile(a.artifactsDir / "all_requests.json"   ,   %allReqOpts              )
        return this_tick_result

    # ===== TOOL LOOP =====
    while true:
        totalTokensUsed.input    += resp.val.usage.get.inputTokens
        totalTokensUsed.output   += resp.val.usage.get.outputTokens
        totalTokensUsed.combined += resp.val.usage.get.totalTokens

        if not resp.hasFunctionCalls: break

        if numToolCalls >= maxTC:
            let
                elapsed       = now() - startTime
                errMsg        = fmt"Exceeded maximum tool calls of {maxTC}"
                maxTCErrEvent = a.ErrorEvent(
                    errorKind         = fkmaxToolCalls
                    ,errorMessage     = errMsg
                    ,elapsed          = elapsed
                    ,tokensUsed       = resp.val.usage.get.totalTokens
                    ,cumulativeTokens = totalTokensUsed.combined
                )
            a.emitEvent(maxTCErrEvent)
            this_tick_result.events.add(maxTCErrEvent)

            this_tick_result.error   = some(errMsg)
            this_tick_result.elapsed = elapsed
            this_tick_result.done    = false

            appendToJsonFile(a.artifactsDir / "events.json"         ,   %this_tick_result.events )
            appendToJsonFile(a.artifactsDir / "all_responses.json"  ,   %allResponses            )
            appendToJsonFile(a.artifactsDir / "all_requests.json"   ,   %allReqOpts              )
            return this_tick_result

        var toolResults: seq[JsonNode] = @[]

        for fc in resp.functionCalls:
            numToolCalls.inc

            let callEvent         = a.ToolCallEvent(
                tokensUsed        = resp.val.usage.get.totalTokens
                ,cumulativeTokens = totalTokensUsed.combined
                ,elapsed          = now() - startTime
                ,callToolName     = fc.name
                ,callToolArgs     = fc.arguments
                ,callToolId       = fc.id
            )
            a.emitEvent(callEvent)
            this_tick_result.events.add(callEvent)
            this_tick_result.toolCalls.add(fc)

            let
                fc_payload            = await a.tools.tools[fc.name].handler(fc.arguments)
                fc_data_back_to_agent = functionOutput(fc.callId, fc_payload)
                toolResultEvent       = a.ToolResultEvent(
                    tokensUsed        = resp.val.usage.get.totalTokens
                    ,cumulativeTokens = totalTokensUsed.combined
                    ,elapsed          = now() - startTime
                    ,resultToolId     = fc.callId
                    ,resultOutput     = fc_payload
                    ,resultOk         = base.tool_call_was_successful(fc_payload)
                )

            a.emitEvent(toolResultEvent)
            this_tick_result.events.add(toolResultEvent)

            toolResults.add(fc_data_back_to_agent)
            this_tick_result.toolResults.add(fc_data_back_to_agent)

            # ===== B: FAILURE / RECOVERY TRACKING =====
            if not base.tool_call_was_successful(fc_payload):
                a.failureTracker.recordFailure(fc.name, base.get_tool_call_error(fc_payload))
            elif a.failureTracker.checkRecovery(fc.name):
                toolResults.add(buildToolRecoveryNudge(fc.name))
                a.failureTracker.clearRecovery(fc.name)

        req_opts.previousResponseId = some resp.id
        req_opts.input              = some %toolResults
        resp                        = await a.client.createResponse(req_opts)
        allReqOpts.add   req_opts
        allResponses.add resp

        if not resp.ok:
            let apiErrEvent = a.ErrorEvent(
                errorKind     = fkApiError
                ,errorMessage = resp.err
                ,elapsed      = now() - startTime
            )
            a.emitEvent(apiErrEvent)
            this_tick_result.events.add(apiErrEvent)

            this_tick_result.error   = some(resp.err)
            this_tick_result.elapsed = now() - startTime
            this_tick_result.done    = false

            appendToJsonFile(a.artifactsDir / "events.json"         ,   %this_tick_result.events )
            appendToJsonFile(a.artifactsDir / "all_responses.json"  ,   %allResponses            )
            appendToJsonFile(a.artifactsDir / "all_requests.json"   ,   %allReqOpts              )
            return this_tick_result

    # Final assistant message
    let 
        text                  = resp.val.extractText()
        msgEvent              = a.MessageEvent(
            tokensUsed        = resp.val.usage.get.totalTokens
            ,cumulativeTokens = totalTokensUsed.combined
            ,elapsed          = now() - startTime
            ,msgText          = text
        )

    a.totalTokensUsed = totalTokensUsed
    a.emitEvent(msgEvent)

    this_tick_result.events.add(msgEvent)
    this_tick_result.text       = text
    this_tick_result.tokensUsed = totalTokensUsed.combined
    this_tick_result.elapsed    = now() - startTime
    this_tick_result.done       = true

    # Persist session state
    a.session.lastResponseId = some(resp.val.id)
    if text.len > 0:
        a.session.messages.add builders.assistantMessage(text)

    appendToJsonFile(a.artifactsDir / "events.json"         ,   %this_tick_result.events )
    appendToJsonFile(a.artifactsDir / "all_responses.json"  ,   %allResponses            )
    appendToJsonFile(a.artifactsDir / "all_requests.json"   ,   %allReqOpts              )
    writeFile(a.artifactsDir / "finalOutput.md",     text)

    # ===== C: POST-TURN REFLECTION =====
    if a.enableReflection: await a.runReflection(resp.val.id)

    return this_tick_result

proc ask*(
    a  : Agent
    ,q : string
    ,maxToolCalls = 0
): Future[string] {.async.} =
    let res = await chatTurn(a,q)
    if res.error.isSome:
        return "Error: " & res.error.get()
    return res.text

proc askInSession*(
    a             : Agent
    ,q            : string
    ,maxToolCalls = 0
    ,useChaining  = true
): Future[string] {.async.} =
    let res = await a.chatTurn(
        userText     = q
        ,useChaining = useChaining
        ,maxToolCalls = maxToolCalls
    )
    if res.error.isSome:
        return "Error: " & res.error.get()
    return res.text

proc chat*(
    a             : Agent
    ,userText     : string
    ,useChaining  = false
    ,maxToolCalls = 0
): Future[string] {.async.} =
    let res           = await a.chatTurn(
        userText      = userText
        ,useChaining  = useChaining
        ,maxToolCalls = maxToolCalls
    )
    if res.error.isSome:
        return "Error: " & res.error.get()
    return res.text

include chat_repl 
