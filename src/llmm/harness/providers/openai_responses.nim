## harness/providers/openai_responses.nim

import std/[json, options, asyncdispatch]

import rz

import ./base
import ../tools/base as tool_base
import ../primitives/multimodal
import ../primitives/mem/memory as harness_memory

import ../../providers/oai/oai_client
import ../../providers/oai/utils/builders as oai_builders
import ../../providers/oai/responses/types
import ../../providers/oai/responses/api
import ../../providers/oai/responses/utils


type
  OpenAIResponsesTurnState* = ref object of TurnState
    opts*: CreateResponseOptions
    lastResponseId*: Option[string]

  OpenAIResponsesProvider* = ref object of LlmProvider
    client*: OpenAIClient

proc newOpenAIResponsesProvider*(client: OpenAIClient, name = "openai"): OpenAIResponsesProvider =
  OpenAIResponsesProvider(kind: pkOpenAIResponses, name: name, client: client)

# -----------------------------------------------------------------------------
# Builders
# -----------------------------------------------------------------------------

method supportsBuiltInTools*(p: OpenAIResponsesProvider): bool {.gcsafe.} = true
method supportsMultimodal*(p: OpenAIResponsesProvider): bool {.gcsafe.} = true

method systemMessage*(p: OpenAIResponsesProvider, content: string): JsonNode {.gcsafe.} =
  oai_builders.systemMessage(content)

method assistantMessage*(p: OpenAIResponsesProvider, content: string): JsonNode {.gcsafe.} =
  oai_builders.assistantMessage(content)

method userMessage*(p: OpenAIResponsesProvider, input: UserInput): JsonNode {.gcsafe.} =
  ## Uses Responses-API compatible multimodal encoding.
  input.toUserMessage()

method buildToolOutput*(p: OpenAIResponsesProvider, call: ToolCall, payload: JsonNode): JsonNode {.gcsafe.} =
  ## Responses API expects a function_call_output item.
  tool_base.functionOutput(call.callId, payload)

# -----------------------------------------------------------------------------
# Request/response mapping
# -----------------------------------------------------------------------------

proc toProviderToolCalls(resp: OpenAIResponse): seq[ToolCall] =
  result = @[]
  for fc in resp.functionCalls:
    result.add ToolCall(
      id: fc.id,
      name: fc.name,
      arguments: fc.arguments,
      callId: fc.callId
    )

proc toProviderUsage(resp: Rz[OpenAIResponse]): base.Usage =
  if resp.ok and resp.val.usage.isSome:
    let u = resp.val.usage.get
    return base.Usage(inputTokens: u.inputTokens, outputTokens: u.outputTokens, totalTokens: u.totalTokens)
  base.Usage()

proc toProviderResponse(resp: Rz[OpenAIResponse], requestJson: JsonNode): ProviderResponse =
  result.requestJson  = requestJson
  result.responseJson = %resp
  if not resp.ok:
    result.ok  = false
    result.err = resp.err
    return

  result.ok        = true
  result.id        = resp.val.id
  result.text      = resp.val.extractText()
  result.toolCalls = toProviderToolCalls(resp.val)
  result.usage     = toProviderUsage(resp)

# -----------------------------------------------------------------------------
# Turn execution
# -----------------------------------------------------------------------------

method startTurn*(
    p: OpenAIResponsesProvider,
    model: string,
    messages: seq[JsonNode],
    tools: seq[JsonNode],
    instructions: string,
    previousTurnId: Option[string]
  ): Future[tuple[state: TurnState, resp: ProviderResponse]] {.async, gcsafe.} =

  var opts = CreateResponseOptions(
    model: model,
    tools: (if tools.len > 0: some tools else: none seq[JsonNode]),
    instructions: (if instructions.len > 0: some instructions else: none string)
  )

  if previousTurnId.isSome:
    opts.previousResponseId = previousTurnId

  opts.input = some %messages

  let reqJson = %opts
  let rzResp = await p.client.createResponse(opts)

  var st = OpenAIResponsesTurnState(opts: opts)
  if rzResp.ok:
    st.lastResponseId = some(rzResp.val.id)

  return (state: st, resp: toProviderResponse(rzResp, reqJson))


method continueTurn*(
    p: OpenAIResponsesProvider,
    state: TurnState,
    toolOutputs: seq[JsonNode]
  ): Future[ProviderResponse] {.async, gcsafe.} =

  let st = OpenAIResponsesTurnState(state)
  if st.lastResponseId.isNone:
    return ProviderResponse(ok: false, err: "OpenAIResponsesTurnState has no lastResponseId")

  st.opts.previousResponseId = st.lastResponseId
  st.opts.input              = some %toolOutputs

  let reqJson = %st.opts
  let rzResp  = await p.client.createResponse(st.opts)

  if rzResp.ok:
    st.lastResponseId = some(rzResp.val.id)

  return toProviderResponse(rzResp, reqJson)


method reflection*(
    p: OpenAIResponsesProvider,
    model: string,
    lastTurnId: string,
    memTool: tool_base.Tool
  ): Future[void] {.async, gcsafe.} =
  ## A small, tool-only loop that lets the agent update its memory store.
  ## Uses Responses API chaining.
  var opts = CreateResponseOptions(
    model: model,
    tools: some @[%memTool],
    previousResponseId: some lastTurnId,
    input: some %harness_memory.buildReflectionMessages()
  )

  var resp = await p.client.createResponse(opts)
  if not resp.ok:
    return

  const maxLoops = 3

  for _ in 0..<maxLoops:
    if not resp.hasFunctionCalls:
      break

    var toolResults: seq[JsonNode] = @[]
    for fc in resp.functionCalls:
      if fc.name == memTool.name:
        try:
          let payload = await memTool.handler(fc.arguments)
          toolResults.add(tool_base.functionOutput(fc.callId, payload))
        except CatchableError as ex:
          toolResults.add(tool_base.functionOutput(fc.callId, tool_base.toolError(ex.msg)))
      else:
        toolResults.add(tool_base.functionOutput(
          fc.callId,
          tool_base.toolError("Only memory tool is available during reflection")
        ))

    opts.previousResponseId = some resp.val.id
    opts.input              = some %toolResults

    resp = await p.client.createResponse(opts)
    if not resp.ok:
      break
