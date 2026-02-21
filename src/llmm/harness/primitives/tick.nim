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
,sequtils
,os
]

import rz
,ic
,agent
,sessions
,store
,multimodal
,../tools/base
,../../general_helpers
,../../providers/oai/oai_client
,../../providers/oai/common/types
,../../providers/oai/utils/builders
,../../providers/oai/responses/types
,../../providers/oai/responses/api
,../../providers/oai/responses/utils

import ./mem/[
memory
,memory_tool
]    


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


# ---------------------------------------------------------------------------
# Reflection mini-loop
# ---------------------------------------------------------------------------

proc runReflection(a: Agent, lastResponseId: string) {.async.} =
    try:
        icb "Starting reflection loop", lastResponseId

        # Guard: memory store must exist
        if a.state.memoryStore.isNil:
            icr "Reflection skipped: memoryStore is nil"
            return

        let
            memTool     = MemoryTool(a.state.memoryStore)
            reflectMsgs = buildReflectionMessages()

        var opts = CreateResponseOptions(
            model               : a.cfg.model
            ,tools              : some @[%memTool]
            ,previousResponseId : some lastResponseId
            ,input              : some %reflectMsgs
        )

        var resp = await a.client.createResponse(opts)
        if not resp.ok:
            icr "Reflection API error", resp.err
            return

        const maxLoops = 3

        for i in 0..<maxLoops:
            if not resp.hasFunctionCalls:
                icb "Reflection done (no more function calls)", i
                break

            var toolResults: seq[JsonNode] = @[]

            for fc in resp.functionCalls:
                if fc.name == memTool.name:
                    icb "Reflection calling memory tool", fc.name, fc.arguments
                    try:
                        let payload = await memTool.handler(fc.arguments)
                        ic payload
                        toolResults.add(functionOutput(fc.callId, payload))
                    except CatchableError as ex:
                        icr "Memory tool handler error", ex.msg
                        toolResults.add(functionOutput(fc.callId, toolError(ex.msg)))
                else:
                    icy "Reflection rejected non-memory tool", fc.name
                    toolResults.add(functionOutput(
                        fc.callId
                        ,toolError("Only memory tool is available during reflection")
                    ))

            opts.previousResponseId = some resp.id
            opts.input              = some %toolResults

            resp = await a.client.createResponse(opts)
            if not resp.ok:
                icr "Reflection loop error", resp.err
                break

        icb "Reflection complete"

    except CatchableError as ex:
        icr "Reflection failed (non-fatal)", ex.msg
    except Exception as ex:
        icr "Reflection fatal error (swallowed)", ex.msg

# ---------------------------------------------------------------------------
# Main chat turn (multimodal)
# ---------------------------------------------------------------------------

proc chatTurn*(
    a             : Agent
    ,input        : UserInput
    ,useChaining  = false
    ,maxToolCalls = 0
): Future[TickResult] {.async.} =

    # Extract plain text for logging, memory injection, and db storage
    let userText = input.plainText()

    icb "=== chatTurn START ===", a.cfg.model, useChaining, maxToolCalls
    ic userText
    if input.hasImages: ic "Input contains images"
    if input.hasFiles:  ic "Input contains files"

    # Ensure workspace dir exists (tools may write files there)
    # Does nothing if the directory already exists
    createDir a.cfg.workspaceDir

    # Grab the unified store handle
    let db = a.state.agentStore

    # Tools payload for the API
    let tools_sent_to_llm: seq[JsonNode] = collect:
        for toolName in a.cfg.tools.keys:
            if a.cfg.enableReflection == false and toolName == "memory":
                icy "Memory tool disabled for this turn due to reflection being disabled"
                continue
            let t = a.cfg.tools[toolName]
            if t.isBuiltIn: t.parameters else: %t

    icb "Tools registered " & $tools_sent_to_llm.len

    let maxTC = max(maxToolCalls, a.cfg.policy.maxToolCalls)

    ic maxTC

    var
        res             : TickResult
        startTime       = now()
        numToolCalls    = 0
        totalTokensUsed : tuple[input: int, output: int, combined: int]

    # ----- Local helpers (keep the main loop readable) -----

    proc elapsedNow(): Duration = now() - startTime

    proc persistArtifacts(events: seq[AgentEvent], reqOpts: seq[JsonNode], responses: seq[JsonNode]) =
        ## Persist events, requests, and responses to the unified db.
        ic "Persisting artifacts to db", events.len
        for ev in events:
            db.insertEvent($ev.kind, %ev)
        for req in reqOpts:
            db.insertRequest(req)
        for resp in responses:
            db.insertResponse(resp)

    proc emitEvent(ev: AgentEvent) =
        a.state.events.emit(ev)
        res.events.add(ev)

    # Track serialized requests/responses for bulk persist at the end
    var
        allReqOptsJson  : seq[JsonNode]
        allResponsesJson: seq[JsonNode]

    template finishWithError(
        kind         : FailureKind
        ,msg         : string
        ,tokensNow   = 0
        ,recoverable = false
    ) =
        icr "FINISH WITH ERROR", kind, msg, recoverable
        let ev = a.ErrorEvent(
            errorKind         = kind
            ,errorMessage     = msg
            ,elapsed          = elapsedNow()
            ,tokensUsed       = tokensNow
            ,cumulativeTokens = totalTokensUsed.combined
            ,errorRecoverable = recoverable
        )
        emitEvent(ev)
        res.error   = some(msg)
        res.elapsed = elapsedNow()
        res.done    = false
        persistArtifacts(res.events, allReqOptsJson, allResponsesJson)

        # Write error entry to chat history db
        db.insertChatEntry(
            role       = "error"
            ,content   = msg
            ,tokensUsed = totalTokensUsed.combined
            ,elapsed   = elapsedNow()
            ,model     = a.cfg.model
            ,done      = false
        )

        return res

    template enforceTimeout(tokensNow: int = 0) =
        if a.cfg.policy.timeout > initDuration(seconds = 0):
            let e = elapsedNow()
            if e > a.cfg.policy.timeout:
                let msg = "Agent timed out after " & $a.cfg.policy.timeout & ". Elapsed: " & $e & "."
                icy "TIMEOUT", msg
                finishWithError(
                    fkTimeout
                    ,msg
                    ,tokensNow
                    ,recoverable = true
                )

    proc usageOrWarn(resp: rz.Rz[OpenAIResponse]): Usage =
        ## Always return *some* usage (default = zeros).
        if resp.ok and resp.val.usage.isSome:
            let u = resp.val.usage.get
            ic u.inputTokens, u.outputTokens, u.totalTokens
            return u

        icy "API response missing usage information"
        let ev = a.ErrorEvent(
            errorKind         = fkApiError
            ,errorMessage     = "API response missing usage information"
            ,elapsed          = elapsedNow()
            ,tokensUsed       = 0
            ,cumulativeTokens = totalTokensUsed.combined
            ,errorRecoverable = true
        )
        emitEvent(ev)
        result = default(Usage)

    proc buildInitialInput(userMsg: JsonNode, augmentedSystemPrompt: string): JsonNode =
        if useChaining and a.state.session.lastResponseId.isSome:
            icb "Chaining mode: sending only new user msg"
            return %*[userMsg]

        icb "Full context mode: system + history + user msg"
        result = newJArray()
        if augmentedSystemPrompt.len > 0:
            result.add builders.systemMessage(augmentedSystemPrompt)

        ic a.state.session.messages.len
        for m in a.state.session.messages:
            result.add m

        result.add userMsg
        return result

    # ----- Build augmented system prompt (memory injection) -----
    icy a.cfg.enableReflection
    let augmentedSystemPrompt = if a.cfg.enableReflection:
        injectMemoryContext(
            store         = a.state.memoryStore
            ,systemPrompt = a.cfg.systemPrompt
            ,userMessage  = userText
            ,maxMemories  = 5
        )
    else:
        a.cfg.systemPrompt

    icb augmentedSystemPrompt.max_len(200)

    # ----- Write user entry to chat history db -----

    db.insertChatEntry(
        role     = "user"
        ,content = userText
        ,model   = a.cfg.model
    )

    # ----- Build first request -----
    # Use multimodal-aware message builder
    let userMsg = input.toUserMessage()

    var reqOpts = CreateResponseOptions(
        model         : a.cfg.model
        ,tools        : (if tools_sent_to_llm.len > 0  : some tools_sent_to_llm  else : none seq[JsonNode])
        ,instructions : (if a.cfg.instructions.len > 0 : some a.cfg.instructions else : none string)
    )

    if useChaining and a.state.session.lastResponseId.isSome:
        reqOpts.previousResponseId = a.state.session.lastResponseId
        icb "Chaining with previous response", a.state.session.lastResponseId.get

    reqOpts.input = some buildInitialInput(userMsg, augmentedSystemPrompt)

    allReqOptsJson.add %reqOpts
    a.state.session.messages.add userMsg

    icb "Sending initial API request"
    var resp = await a.client.createResponse(reqOpts)
    enforceTimeout()

    allResponsesJson.add %resp

    if not resp.ok:
        icr "Initial API call failed", resp.err
        discard a.state.session.messages.pop()
        finishWithError(fkApiError, resp.err)

    ic "Initial response OK", resp.val.id

    # -----------------------------------------------------------------------
    # TOOL LOOP
    # -----------------------------------------------------------------------

    icb "=== Entering tool loop ==="

    while true:
        enforceTimeout()

        let usage = usageOrWarn(resp)

        totalTokensUsed.input    += usage.inputTokens
        totalTokensUsed.output   += usage.outputTokens
        totalTokensUsed.combined += usage.totalTokens

        ic totalTokensUsed

        if not resp.hasFunctionCalls:
            icb "No function calls — exiting tool loop"
            break

        if numToolCalls >= maxTC:
            icy "Max tool calls exceeded", numToolCalls, maxTC
            finishWithError(
                fkmaxToolCalls
                ,fmt"Exceeded maximum tool calls of {maxTC}"
                ,tokensNow = usage.totalTokens
            )

        var toolResults: seq[JsonNode] = @[]

        for fc in resp.functionCalls:
            # Unknown tool => recoverable: log + return toolError payload to model
            if not a.cfg.tools.hasKey(fc.name):
                let 
                    toolNames = tools_sent_to_llm.mapIt(it["name"].getStr).join(", ")
                    msg       = fmt"Agent attempted to call unknown tool: {fc.name}"

                icr "Unknown tool call", fc.name, toolNames

                let ev = a.ErrorEvent(
                    errorKind         = fkUnknownTool
                    ,errorMessage     = msg
                    ,elapsed          = elapsedNow()
                    ,tokensUsed       = usage.totalTokens
                    ,cumulativeTokens = totalTokensUsed.combined
                    ,errorRecoverable = true
                )
                emitEvent(ev)

                let payload = functionOutput(
                    fc.callId
                    ,toolError("Unknown tool: " & fc.name & ". Available: " & toolNames)
                )
                toolResults.add(payload)
                res.toolResults.add(payload)
                continue

            # Known tool call
            numToolCalls.inc

            icb "Tool call", numToolCalls, fc.name, fc.arguments

            let callEvent = a.ToolCallEvent(
                tokensUsed        = usage.totalTokens
                ,cumulativeTokens = totalTokensUsed.combined
                ,elapsed          = elapsedNow()
                ,callToolName     = fc.name
                ,callToolArgs     = fc.arguments
                ,callToolId       = fc.id
            )
            emitEvent(callEvent)
            res.toolCalls.add(fc)

            enforceTimeout(usage.totalTokens)

            let toolPayload = await a.cfg.tools[fc.name].handler(fc.arguments)

            let callOk = base.tool_call_was_successful(toolPayload)
            if callOk:
                ic "Tool result OK", fc.name, toolPayload
            else:
                icr "Tool result FAILED", fc.name, toolPayload

            let resultEvent       = a.ToolResultEvent(
                tokensUsed        = usage.totalTokens
                ,cumulativeTokens = totalTokensUsed.combined
                ,elapsed          = elapsedNow()
                ,resultToolId     = fc.callId
                ,resultOutput     = toolPayload
                ,resultOk         = callOk
            )
            emitEvent(resultEvent)

            let backToModel = functionOutput(fc.callId, toolPayload)
            toolResults.add(backToModel)
            res.toolResults.add(backToModel)

            # Failure / recovery tracking
            if not callOk:
                a.state.failureTracker.recordFailure(fc.name, base.get_tool_call_error(toolPayload))
                icy "Failure recorded", fc.name
            elif a.state.failureTracker.checkRecovery(fc.name):
                ic "Recovery detected for tool", fc.name
                toolResults.add(buildToolRecoveryNudge(fc.name))
                a.state.failureTracker.clearRecovery(fc.name)

        # Continue the response chain with tool outputs
        reqOpts.previousResponseId = some resp.val.id
        reqOpts.input              = some %toolResults

        icb "Continuing response chain", toolResults.len, "tool results"

        resp = await a.client.createResponse(reqOpts)
        enforceTimeout()

        allReqOptsJson.add(%reqOpts)
        allResponsesJson.add(%resp)

        if not resp.ok:
            icr "Tool loop API error", resp.err
            finishWithError(fkApiError, resp.err)

    # -----------------------------------------------------------------------
    # FINAL ASSISTANT MESSAGE
    # -----------------------------------------------------------------------

    icb "=== Finalizing response ==="

    let text = resp.val.extractText()

    ic text.len

    let msgEvent = a.MessageEvent(
        tokensUsed        = resp.val.usage.get.totalTokens
        ,cumulativeTokens = totalTokensUsed.combined
        ,elapsed          = elapsedNow()
        ,msgText          = text
    )

    a.state.totalTokensUsed = totalTokensUsed
    emitEvent(msgEvent)

    res.text       = text
    res.tokensUsed = totalTokensUsed.combined
    res.elapsed    = elapsedNow()
    res.done       = true

    ic res.tokensUsed, res.elapsed, res.done

    # Persist session state
    a.state.session.lastResponseId = some(resp.val.id)
    if text.len > 0:
        a.state.session.messages.add builders.assistantMessage(text)

    # Persist all artifacts to the unified db
    persistArtifacts(res.events, allReqOptsJson, allResponsesJson)

    # Write finalOutput.md to workspace dir
    writeFile(a.cfg.workspaceDir / "finalOutput.md", text)

    # Write assistant entry to chat history db (full turn record)
    db.insertChatEntry(
        role         = "assistant"
        ,content     = text
        ,toolCalls   = res.toolCalls.mapIt(%it)
        ,toolResults = res.toolResults
        ,tokensUsed  = totalTokensUsed.combined
        ,elapsed     = elapsedNow()
        ,model       = a.cfg.model
        ,responseId  = resp.val.id
        ,done        = true
    )

    # Post-turn reflection (never fails the turn)
    if a.cfg.enableReflection:
        icb "Starting post-turn reflection"
        try:
            await runReflection(a, resp.val.id)
        except CatchableError as ex:
            icr "Post-turn reflection failed (non-fatal)", ex.msg

    icb "=== chatTurn DONE ===", res.tokensUsed, res.elapsed
    return res


# ---------------------------------------------------------------------------
# Backward-compatible string overload
# ---------------------------------------------------------------------------

proc chatTurn*(
    a             : Agent
    ,userText     : string
    ,useChaining  = false
    ,maxToolCalls = 0
): Future[TickResult] {.async.} =
    ## Convenience overload: wraps a plain string into UserInput.
    return await a.chatTurn(
        input         = multimodal.textInput(userText)
        ,useChaining  = useChaining
        ,maxToolCalls = maxToolCalls
    )


proc ask*(
    a  : Agent
    ,q : string
    ,maxToolCalls = 0
): Future[string] {.async.} =
    ic "ask()", q
    let r = await chatTurn(a, q, maxToolCalls = maxToolCalls)
    if r.error.isSome:
        icr "ask() error", r.error.get()
        return "Error: " & r.error.get()
    ic "ask() done", r.text.len
    r.text

proc ask*(
    a     : Agent
    ,input : UserInput
    ,maxToolCalls = 0
): Future[string] {.async.} =
    ## Multimodal ask — accepts UserInput with images/files.
    ic "ask(multimodal)", input.plainText
    let r = await chatTurn(a, input, maxToolCalls = maxToolCalls)
    if r.error.isSome:
        icr "ask() error", r.error.get()
        return "Error: " & r.error.get()
    ic "ask() done", r.text.len
    r.text


proc chat*(
    a             : Agent
    ,userText     : string
    ,useChaining  = false
    ,maxToolCalls = 0
): Future[string] {.async.} =
    ic "chat()", userText, useChaining, maxToolCalls
    let r = await a.chatTurn(
        userText      = userText
        ,useChaining  = useChaining
        ,maxToolCalls = maxToolCalls
    )
    if r.error.isSome:
        icr "chat() error", r.error.get()
        return "Error: " & r.error.get()
    ic "chat() done", r.text.len
    r.text

proc chat*(
    a             : Agent
    ,input        : UserInput
    ,useChaining  = false
    ,maxToolCalls = 0
): Future[string] {.async.} =
    ## Multimodal chat — accepts UserInput with images/files.
    ic "chat(multimodal)", input.plainText, useChaining, maxToolCalls
    let r = await a.chatTurn(
        input         = input
        ,useChaining  = useChaining
        ,maxToolCalls = maxToolCalls
    )
    if r.error.isSome:
        icr "chat() error", r.error.get()
        return "Error: " & r.error.get()
    ic "chat() done", r.text.len
    r.text


include chat_repl_classic