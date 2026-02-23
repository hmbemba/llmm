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
  os
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


# ---------------------------------------------------------------------------
# Main chat turn (multimodal)
# ---------------------------------------------------------------------------

proc chatTurn*(
  a: Agent,
  input: UserInput,
  useChaining = false,
  maxToolCalls = 0
): Future[TickResult] {.async.} =

  # Extract plain text for logging, memory injection, and db storage
  let userText = input.plainText()

  icb "=== chatTurn START ===", a.cfg.model, useChaining, maxToolCalls
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

    # Built-in tools (web_search, etc.) are only supported by some providers.
    if t.isBuiltIn and not a.provider.supportsBuiltInTools:
      icy "Skipping built-in tool (provider does not support it)", a.provider.name, t.name
      continue

    tools_sent_to_llm.add (if t.isBuiltIn: t.parameters else: %t)

  icb "Tools registered " & $tools_sent_to_llm.len

  let maxTC = max(maxToolCalls, a.cfg.policy.maxToolCalls)

  var
    res             : TickResult
    startTime       = now()
    numToolCalls    = 0
    totalTokensUsed : tuple[input: int, output: int, combined: int]

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

  proc buildInitialMessages(userMsg: JsonNode, augmentedSystemPrompt: string): seq[JsonNode] =
    # Chaining mode: provider decides; we only do the OpenAI-Responses style
    # optimization (send only new user msg + previousTurnId).
    if useChaining and a.provider.kind == prov.pkOpenAIResponses and a.state.session.lastResponseId.isSome:
      icb "Chaining mode: sending only new user msg"
      return @[userMsg]

    icb "Full context mode: system + history + user msg"
    result = @[]
    if augmentedSystemPrompt.len > 0:
      result.add a.provider.systemMessage(augmentedSystemPrompt)

    for m in a.state.session.messages:
      result.add m

    result.add userMsg

  # Track serialized requests/responses for bulk persist at the end
  var
    allReqOptsJson   : seq[JsonNode]
    allResponsesJson : seq[JsonNode]

  # ----- Build augmented system prompt (memory injection) -----
  let augmentedSystemPrompt = if a.cfg.enableReflection:
    injectMemoryContext(
      store         = a.state.memoryStore,
      systemPrompt  = a.cfg.systemPrompt,
      userMessage   = userText,
      maxMemories   = 5
    )
  else:
    a.cfg.systemPrompt

  icb augmentedSystemPrompt.max_len(200)

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

  var (turnState, resp) = await a.provider.startTurn(
    model          = a.cfg.model,
    messages       = msgs,
    tools          = tools_sent_to_llm,
    instructions   = a.cfg.instructions,
    previousTurnId = prevTurnId
  )
  enforceTimeout()

  allReqOptsJson.add resp.requestJson
  allResponsesJson.add resp.responseJson

  if not resp.ok:
    icr "Initial provider call failed", resp.err
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

        icr "Unknown tool call", tc.name, toolNames

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
        ic "Tool result OK", tc.name
      else:
        icr "Tool result FAILED", tc.name

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
        icy "Failure recorded", tc.name
      elif a.state.failureTracker.checkRecovery(tc.name):
        ic "Recovery detected for tool", tc.name
        when true:
          if a.provider.kind == prov.pkOpenAIResponses:
            toolOutputs.add(buildToolRecoveryNudge(tc.name))
        a.state.failureTracker.clearRecovery(tc.name)

    icb "Continuing provider turn", toolOutputs.len, "tool outputs"

    resp = await a.provider.continueTurn(turnState, toolOutputs)
    enforceTimeout()

    allReqOptsJson.add resp.requestJson
    allResponsesJson.add resp.responseJson

    if not resp.ok:
      icr "Tool loop provider error", resp.err
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
  if a.cfg.enableReflection and responseId.len > 0:
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

  icb "=== chatTurn DONE ===", res.tokensUsed, res.elapsed
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
