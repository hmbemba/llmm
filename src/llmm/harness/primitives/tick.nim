# =============================================================================
# tick.nim - Core agent execution (provider-agnostic)
# =============================================================================

import std/[
  json,
  times,
  options,
  asyncdispatch,
  strformat,
  strutils,
  sugar,
  tables,
  sequtils,
  os,
  random
]

import rz
import ic

import agent
import sessions
import store
import multimodal
import ../tools/base
import ../../general_helpers

import ../providers/base as prov

import ./mem/[memory, memory_tool]


type
  TickResult* = object
    events*     : seq[AgentEvent]
    text*       : string
    toolCalls*  : seq[prov.ToolCall]
    toolResults*: seq[JsonNode]
    tokensUsed* : int
    elapsed*    : Duration
    done*       : bool
    error*      : Option[string]

  RetryConfig* = object
    maxRetries*     : int
    baseDelayMs*    : int
    maxDelayMs*     : int
    retryableErrors*: seq[string]  ## Substrings that indicate retryable errors

const DefaultRetryConfig = RetryConfig(
  maxRetries: 3,
  baseDelayMs: 1000,
  maxDelayMs: 30000,
  retryableErrors: @[
    "connection was closed",
    "connection reset",
    "timeout",
    "temporarily unavailable",
    "rate limit",
    "too many requests",
    "server error",
    "service unavailable",
    "gateway",
    "eof"
  ]
)

proc isRetryableError(msg: string, cfg: RetryConfig = DefaultRetryConfig): bool =
  ## Check if an error message indicates a retryable transient failure.
  let lowerMsg = msg.toLowerAscii()
  for pattern in cfg.retryableErrors:
    if pattern in lowerMsg:
      return true
  return false

proc calculateBackoff(attempt: int, cfg: RetryConfig = DefaultRetryConfig): int {.gcsafe.} =
  ## Calculate exponential backoff delay in milliseconds with jitter.
  ## attempt is 0-indexed (0 = first retry)
  {.gcsafe.}:
    randomize()  # Initialize random seed (safe to call multiple times)
  let base = cfg.baseDelayMs * (1 shl attempt)  # 2^attempt multiplier
  let jitter = rand(0..500)  # Add up to 500ms random jitter
  result = min(base + jitter, cfg.maxDelayMs)

proc withRetry*[T](
  operation: proc(): Future[T] {.async, gcsafe.},
  operationName: string,
  cfg: RetryConfig = DefaultRetryConfig
): Future[tuple[success: bool, result: T, lastError: string]] {.async, gcsafe.} =
  ## Execute an async operation with exponential backoff retry logic.
  var lastError = ""
  
  for attempt in 0..cfg.maxRetries:
    try:
      let res = await operation()
      return (true, res, "")
    except CatchableError as e:
      lastError = e.msg
      let isRetryable = isRetryableError(lastError, cfg)
      
      if attempt < cfg.maxRetries and isRetryable:
        let delayMs = calculateBackoff(attempt, cfg)
        icy &"{operationName} failed (attempt {attempt + 1}/{cfg.maxRetries + 1}): {lastError}"
        icy &"Retrying in {delayMs}ms..."
        await sleepAsync(delayMs)
      else:
        if not isRetryable:
          icy &"{operationName} failed with non-retryable error: {lastError}"
        else:
          icy &"{operationName} failed after {cfg.maxRetries + 1} attempts"
        break
  
  return (false, default(T), lastError)


# ---------------------------------------------------------------------------
# Main chat turn (multimodal)
# ---------------------------------------------------------------------------

proc chatTurn*(
  a: Agent,
  input: UserInput,
  useChaining = false,
  maxToolCalls = 0
): Future[TickResult] {.async, gcsafe.} =

  # Extract plain text for logging, memory injection, and db storage
  let userText = input.plainText()

  let maxTC = max(maxToolCalls, a.cfg.policy.maxToolCalls)
  icb "=== chatTurn START ===", a.cfg.name, a.cfg.model, "maxTC:", maxTC, "chaining:", useChaining
  ic userText
  if input.hasImages: ic "Input contains images"
  if input.hasFiles:  ic "Input contains files"

  if a.provider.isNil:
    raise newException(ValueError, "Agent.provider is nil. Did you call agent.new()? (or set provider manually)")

  # Ensure workspace dir exists (tools may write files there)
  createDir a.cfg.workspaceDir

  # Grab the unified store handle and current session id
  let db = a.state.agentStore
  let sessionId = a.state.session.id

  # Tools payload for the provider
  var tools_sent_to_llm: seq[JsonNode] = @[]
  for toolName in a.cfg.tools.keys:
    if a.cfg.enableReflection == false and toolName == "memory":
      icy "Memory tool disabled for this turn due to reflection being disabled"
      continue

    let t = a.cfg.tools[toolName]

    # Skip disabled tools (runtime toggle via /tools enable/disable)
    if not t.isEnabled:
      continue

    # Built-in tools (web_search, etc.) are only supported by some providers.
    if t.isBuiltIn and not a.provider.supportsBuiltInTools:
      icy "Skipping built-in tool (provider does not support it)", a.provider.name, t.name
      continue

    tools_sent_to_llm.add (if t.isBuiltIn: t.parameters else: %t)

  icb "Tools registered " & $tools_sent_to_llm.len

  var
    res             : TickResult
    startTime       = now()
    numToolCalls    = 0
    totalTokensUsed : tuple[input: int, output: int, combined: int, cached: int]

  # ----- Local helpers -----

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

  template finishWithError(
    kind: FailureKind,
    msg: string,
    tokensNow = 0,
    recoverable = false
  ) =
    icr "FINISH WITH ERROR", kind, msg, recoverable
    let ev = a.ErrorEvent(
      errorKind         = kind,
      errorMessage      = msg,
      elapsed           = elapsedNow(),
      tokensUsed        = tokensNow,
      cumulativeTokens  = totalTokensUsed.combined,
      errorRecoverable  = recoverable
    )
    emitEvent(ev)
    res.error   = some(msg)
    res.elapsed = elapsedNow()
    res.done    = false
    persistArtifacts(res.events, allReqOptsJson, allResponsesJson)

    # Write error entry to chat history db
    db.insertChatEntry(
      role        = "error",
      content     = msg,
      sessionId   = sessionId,
      tokensUsed  = totalTokensUsed.combined,
      elapsed     = elapsedNow(),
      model       = a.cfg.model
    )

    return res

  template enforceTimeout(tokensNow: int = 0) =
    if a.cfg.policy.timeout > initDuration(seconds = 0):
      let e = elapsedNow()
      if e > a.cfg.policy.timeout:
        let msg = "Agent timed out after " & $a.cfg.policy.timeout & ". Elapsed: " & $e & "."
        icy "TIMEOUT", msg
        finishWithError(
          fkTimeout,
          msg,
          tokensNow,
          recoverable = true
        )

  proc usageOrWarn(u: prov.Usage) =
    if u.totalTokens == 0 and (u.inputTokens == 0 and u.outputTokens == 0):
      icy "Provider response missing usage information"
      let ev = a.ErrorEvent(
        errorKind         = fkApiError,
        errorMessage      = "Provider response missing usage information",
        elapsed           = elapsedNow(),
        tokensUsed        = 0,
        cumulativeTokens  = totalTokensUsed.combined,
        errorRecoverable  = true
      )
      emitEvent(ev)

  proc estimateTokens(msgs: seq[JsonNode]): int =
    ## Rough estimation of token count (4 chars ≈ 1 token on average)
    var totalChars = 0
    for m in msgs:
      if m.hasKey("content"):
        totalChars += m["content"].getStr.len
    return totalChars div 4
  
  proc buildStaticMessages(augmentedSystemPrompt: string): seq[JsonNode] =
    ## Build static messages that should be cached across turns.
    ## These are placed first to maximize cacheable prefix.
    ## Order: system prompt -> persona -> tool definitions -> static context
    result = @[]
    
    # 1. System message (augmented with memory if enabled)
    if augmentedSystemPrompt.len > 0:
      result.add a.provider.systemMessage(augmentedSystemPrompt)
    
    # 2. Persona content (static role description)
    if a.cfg.personaContent.len > 0:
      result.add a.provider.developerMessage("## Persona\n\n" & a.cfg.personaContent)
    
    # 3. Tool definitions as developer message (large static content)
    if a.cfg.tools.len > 0:
      var toolsList: seq[Tool] = @[]
      for toolName in a.cfg.tools.keys:
        let t = a.cfg.tools[toolName]
        # Skip disabled tools (runtime toggle) and built-in tools (handled separately by API)
        if not t.isEnabled or t.isBuiltIn:
          continue
        toolsList.add(t)
      
      if toolsList.len > 0:
        let toolsJson = getToolDefinitionsJson(toolsList)
        let toolsMsg = "## Available Tools\n\nYou have access to the following tools:\n\n" & $toolsJson
        result.add a.provider.developerMessage(toolsMsg)
    
    # 4. Static context (knowledge, guidelines, etc.)
    if a.cfg.staticContext.len > 0:
      result.add a.provider.developerMessage("## Context\n\n" & a.cfg.staticContext)
    
    if result.len > 0:
      icb "=== Cache Structure ==="
      icb "  Static messages: " &  $result.len
      icb "  Static tokens: ~"  &  $estimateTokens(result) & " (estimated)"
  
  proc buildInitialMessages(userMsg: JsonNode, augmentedSystemPrompt: string): seq[JsonNode] =
    # Chaining mode: provider decides; we only do the OpenAI-Responses style
    # optimization (send only new user msg + previousTurnId).
    if useChaining and a.provider.kind == prov.pkOpenAIResponses and a.state.session.lastResponseId.isSome:
      icb "Chaining mode: sending only new user msg"
      return @[userMsg]

    icb "Full context mode: building cache-optimized prompt structure"
    result = @[]
    
    # Phase 3: Static content first for caching
    let staticMsgs = buildStaticMessages(augmentedSystemPrompt)
    for m in staticMsgs:
      result.add m
    
    # Dynamic content after static (conversation history)
    icb "  History messages: ", a.state.session.messages.len
    for m in a.state.session.messages:
      result.add m

    # Current user message at the end
    result.add userMsg

  # Track serialized requests/responses for bulk persist at the end
  var
    allReqOptsJson   : seq[JsonNode]
    allResponsesJson : seq[JsonNode]

  # ----- Build augmented system prompt (memory injection) -----
  # Check if memory tool is enabled at runtime (user may have disabled it via /tools disable)
  let memoryToolEnabled = a.cfg.tools.hasKey("memory") and a.cfg.tools["memory"].isEnabled
  
  let augmentedSystemPrompt =
    if a.cfg.enableReflection and not a.state.memoryStore.isNil:
      injectMemoryContext(
        store              = a.state.memoryStore,
        systemPrompt       = a.cfg.systemPrompt,
        userMessage        = userText,
        maxMemories        = 5,
        includeSystemPrompt= memoryToolEnabled  # Only include MemorySystemPrompt if tool is enabled
      )
    else:
      if a.cfg.enableReflection and a.state.memoryStore.isNil:
        icy "Memory injection skipped: memoryStore is nil (lightweight agent?)"
      a.cfg.systemPrompt

  icb augmentedSystemPrompt #.max_len(200)

  # ----- Write user entry to chat history db -----
  db.insertChatEntry(
    role       = "user",
    content    = userText,
    sessionId  = sessionId,
    model      = a.cfg.model
  )

  # ----- Build user message (provider-specific) -----
  let userMsg = a.provider.userMessage(input)

  # ----- Build first request -----
  let msgs = buildInitialMessages(userMsg, augmentedSystemPrompt)

  let prevTurnId = if useChaining and a.provider.kind == prov.pkOpenAIResponses:
    a.state.session.lastResponseId
  else:
    none(string)

  # Persist the user message in the *session history* (not provider's tool-loop state)
  a.state.session.messages.add userMsg

  icb "Sending initial provider request"

  # Retry wrapper for the initial provider call
  let startTurnResult = await withRetry(
    operation = proc(): Future[tuple[state: prov.TurnState, resp: prov.ProviderResponse]] {.async.} =
      result = await a.provider.startTurn(
        model          = a.cfg.model,
        messages       = msgs,
        tools          = tools_sent_to_llm,
        instructions   = a.cfg.instructions,
        previousTurnId = prevTurnId
      )
    ,
    operationName = "startTurn"
  )
  enforceTimeout()

  var turnState: prov.TurnState
  var resp: prov.ProviderResponse
  
  if startTurnResult.success:
    turnState = startTurnResult.result.state
    resp = startTurnResult.result.resp
  else:
    icr "Initial provider call failed after retries", startTurnResult.lastError
    discard a.state.session.messages.pop()
    finishWithError(fkApiError, startTurnResult.lastError)

  allReqOptsJson.add resp.requestJson
  allResponsesJson.add resp.responseJson

  if not resp.ok:
    icr "Initial provider call returned error", resp.err
    discard a.state.session.messages.pop()
    finishWithError(fkApiError, resp.err)

  ic "Initial response OK", resp.id

  # -----------------------------------------------------------------------
  # TOOL LOOP
  # -----------------------------------------------------------------------

  icb "=== Entering tool loop ==="

  while true:
    enforceTimeout()

    usageOrWarn(resp.usage)

    totalTokensUsed.input    += resp.usage.inputTokens
    totalTokensUsed.output   += resp.usage.outputTokens
    totalTokensUsed.combined += resp.usage.totalTokens
    totalTokensUsed.cached   += resp.usage.cachedTokens

    if resp.toolCalls.len == 0:
      icb "No tool calls — exiting tool loop"
      break

    if numToolCalls >= maxTC:
      icy "Max tool calls exceeded", numToolCalls, maxTC
      finishWithError(
        fkmaxToolCalls,
        fmt"Exceeded maximum tool calls of {maxTC}",
        tokensNow = resp.usage.totalTokens
      )

    var toolOutputs: seq[JsonNode] = @[]

    for tc in resp.toolCalls:
      # Unknown tool => recoverable: log + return toolError payload to model
      if not a.cfg.tools.hasKey(tc.name):
        let toolNames = tools_sent_to_llm
          .filterIt(it.kind == JObject and it.hasKey("name"))
          .mapIt(it["name"].getStr)
          .join(", ")

        let msg = fmt"Agent attempted to call unknown tool: {tc.name}"

        icr "Unknown tool call " & tc.name & " Available tools: " & toolNames

        let ev = a.ErrorEvent(
          errorKind         = fkUnknownTool,
          errorMessage      = msg,
          elapsed           = elapsedNow(),
          tokensUsed        = resp.usage.totalTokens,
          cumulativeTokens  = totalTokensUsed.combined,
          errorRecoverable  = true
        )
        emitEvent(ev)

        let payload = a.provider.buildToolOutput(
          tc,
          toolError("Unknown tool: " & tc.name & ". Available: " & toolNames)
        )
        toolOutputs.add(payload)
        res.toolResults.add(payload)
        continue

      # Known tool call
      numToolCalls.inc

      icb "Tool call", numToolCalls, tc.name, tc.arguments

      let callEvent = a.ToolCallEvent(
        tokensUsed        = resp.usage.totalTokens,
        cumulativeTokens  = totalTokensUsed.combined,
        elapsed           = elapsedNow(),
        callToolName      = tc.name,
        callToolArgs      = tc.arguments,
        callToolId        = tc.id
      )
      emitEvent(callEvent)
      res.toolCalls.add(tc)

      enforceTimeout(resp.usage.totalTokens)

      let toolPayload = await a.cfg.tools[tc.name].handler(tc.arguments)

      let callOk = tool_call_was_successful(toolPayload)
      if callOk:
        ic "Tool result OK " & tc.name
      else:
        icr "Tool result FAILED " & tc.name
        icr toolPayload

      let resultEvent = a.ToolResultEvent(
        tokensUsed        = resp.usage.totalTokens,
        cumulativeTokens  = totalTokensUsed.combined,
        elapsed           = elapsedNow(),
        resultToolId      = tc.callId,
        resultOutput      = toolPayload,
        resultOk          = callOk
      )
      emitEvent(resultEvent)

      let backToModel = a.provider.buildToolOutput(tc, toolPayload)
      toolOutputs.add(backToModel)
      res.toolResults.add(backToModel)

      # Failure / recovery tracking (OpenAI-only nudges for now)
      if not callOk:
        a.state.failureTracker.recordFailure(tc.name, get_tool_call_error(toolPayload))
        icy "Failure recorded " & tc.name
      elif a.state.failureTracker.checkRecovery(tc.name):
        ic "Recovery detected for tool " & tc.name
        when true:
          if a.provider.kind == prov.pkOpenAIResponses:
            toolOutputs.add(buildToolRecoveryNudge(tc.name))
        a.state.failureTracker.clearRecovery(tc.name)

    icb "Continuing provider turn " & $toolOutputs.len & " tool outputs"

    # Retry wrapper for continueTurn
    let continueTurnResult = await withRetry(
      operation = proc(): Future[prov.ProviderResponse] {.async.} =
        result = await a.provider.continueTurn(turnState, toolOutputs)
      ,
      operationName = "continueTurn"
    )
    enforceTimeout()

    if continueTurnResult.success:
      resp = continueTurnResult.result
    else:
      icr "Tool loop provider error after retries: " & continueTurnResult.lastError
      finishWithError(fkApiError, continueTurnResult.lastError)

    allReqOptsJson.add resp.requestJson
    allResponsesJson.add resp.responseJson

    if not resp.ok:
      icr "Tool loop provider error " & resp.err
      finishWithError(fkApiError, resp.err)

  # -----------------------------------------------------------------------
  # FINAL ASSISTANT MESSAGE
  # -----------------------------------------------------------------------

  icb "=== Finalizing response ==="

  let text = resp.text
  let responseId = resp.id

  let msgEvent = a.MessageEvent(
    tokensUsed        = resp.usage.totalTokens,
    cumulativeTokens  = totalTokensUsed.combined,
    elapsed           = elapsedNow(),
    msgText           = text
  )

  a.state.totalTokensUsed = totalTokensUsed
  emitEvent(msgEvent)

  res.text       = text
  res.tokensUsed = totalTokensUsed.combined
  res.elapsed    = elapsedNow()
  res.done       = true

  # Persist session state
  if responseId.len > 0:
    a.state.session.lastResponseId = some(responseId)

  if text.len > 0:
    a.state.session.messages.add a.provider.assistantMessage(text)

  # Persist all artifacts to the unified db
  persistArtifacts(res.events, allReqOptsJson, allResponsesJson)

  # Write finalOutput.md to workspace dir
  writeFile(a.cfg.workspaceDir / "finalOutput.md", text)

  # Write assistant entry to chat history db (full turn record)
  db.insertChatEntry(
    role         = "assistant",
    content      = text,
    sessionId    = sessionId,
    toolCalls    = res.toolCalls.mapIt(%it),
    toolResults  = res.toolResults,
    tokensUsed   = totalTokensUsed.combined,
    elapsed      = elapsedNow(),
    model        = a.cfg.model,
    responseId   = responseId,
    done         = true
  )

  # Post-turn reflection (never fails the turn)
  if a.cfg.enableReflection and responseId.len > 0 and not a.state.memoryStore.isNil:
    icb "Starting post-turn reflection"
    try:
      let memTool = MemoryTool(a.state.memoryStore)
      await a.provider.reflection(
        model      = a.cfg.model,
        lastTurnId = responseId,
        memTool    = memTool
      )
    except CatchableError as ex:
      icr "Post-turn reflection failed (non-fatal)", ex.msg

  # Calculate and log cache statistics
  let cacheHitRate = if totalTokensUsed.combined > 0: 
    (totalTokensUsed.cached * 100) div totalTokensUsed.combined 
  else: 0
  
  icb "=== chatTurn DONE === " & $res.tokensUsed & " tokens used, " & $res.elapsed & " elapsed"
  #if totalTokensUsed.cached > 0:
  icb "  Cached tokens: " & $totalTokensUsed.cached & " (" & $cacheHitRate & "% cache hit rate)"
  return res


# ---------------------------------------------------------------------------
# Backward-compatible string overload
# ---------------------------------------------------------------------------

proc chatTurn*(
  a: Agent,
  userText: string,
  useChaining = false,
  maxToolCalls = 0
): Future[TickResult] {.async.} =
  ## Convenience overload: wraps a plain string into UserInput.
  return await a.chatTurn(
    input        = multimodal.textInput(userText),
    useChaining  = useChaining,
    maxToolCalls = maxToolCalls
  )


proc ask*(
  a: Agent,
  q: string,
  maxToolCalls = 0
): Future[string] {.async.} =
  ic "ask()", q
  let r = await chatTurn(a, q, maxToolCalls = maxToolCalls)
  if r.error.isSome:
    icr "ask() error", r.error.get()
    return "Error: " & r.error.get()
  r.text

proc ask*(
  a: Agent,
  input: UserInput,
  maxToolCalls = 0
): Future[string] {.async.} =
  ## Multimodal ask — accepts UserInput with images/files.
  ic "ask(multimodal)", input.plainText
  let r = await chatTurn(a, input, maxToolCalls = maxToolCalls)
  if r.error.isSome:
    icr "ask() error", r.error.get()
    return "Error: " & r.error.get()
  r.text


proc chat*(
  a: Agent,
  userText: string,
  useChaining = false,
  maxToolCalls = 0
): Future[string] {.async.} =
  let r = await a.chatTurn(
    userText      = userText,
    useChaining   = useChaining,
    maxToolCalls  = maxToolCalls
  )
  if r.error.isSome:
    return "Error: " & r.error.get()
  r.text

proc chat*(
  a: Agent,
  input: UserInput,
  useChaining = false,
  maxToolCalls = 0
): Future[string] {.async.} =
  ## Multimodal chat — accepts UserInput with images/files.
  let r = await a.chatTurn(
    input         = input,
    useChaining   = useChaining,
    maxToolCalls  = maxToolCalls
  )
  if r.error.isSome:
    return "Error: " & r.error.get()
  r.text


include chat_repl_classic
