## harness/providers/kimi_chat.nim

import std/[json, options, asyncdispatch, strutils]

import rz

import ./base

import ../../providers/kimi/kimi_client
import ../../providers/kimi/utils/builders as kimi_builders
import ../../providers/kimi/chat/types
import ../../providers/kimi/chat/api
import ../../providers/kimi/chat/utils


type
  KimiChatTurnState* = ref object of TurnState
    client*      : KimiClient
    model*       : string
    tools*       : seq[JsonNode]
    instructions*: string
    turnMessages*: seq[JsonNode]   ## system/history/user + toolcall/tool messages

  KimiChatProvider* = ref object of LlmProvider
    client*: KimiClient

proc newKimiChatProvider*(client: KimiClient, name = "kimi"): KimiChatProvider =
  KimiChatProvider(kind: pkKimiChatCompletions, name: name, client: client)

# -----------------------------------------------------------------------------
# Capabilities / builders
# -----------------------------------------------------------------------------

method supportsBuiltInTools*(p: KimiChatProvider): bool {.gcsafe.} = true
method supportsMultimodal*(p: KimiChatProvider): bool {.gcsafe.} = false

method systemMessage*(p: KimiChatProvider, content: string): JsonNode {.gcsafe.} =
  kimi_builders.systemMessage(content)

method developerMessage*(p: KimiChatProvider, content: string): JsonNode {.gcsafe.} =
  ## Kimi doesn't distinguish between system and developer roles,
  ## so we map developer messages to system messages for compatibility.
  ## The static content will still be placed at the beginning for consistency.
  kimi_builders.systemMessage(content)

method assistantMessage*(p: KimiChatProvider, content: string): JsonNode {.gcsafe.} =
  kimi_builders.assistantMessage(content)

method userMessage*(p: KimiChatProvider, input: UserInput): JsonNode {.gcsafe.} =
  ## Text-only in this harness for now.
  if input.hasImages or input.hasFiles:
    raise newException(ValueError, "Kimi provider currently supports text-only UserInput")
  kimi_builders.userMessage(input.plainText())

method buildToolOutput*(p: KimiChatProvider, call: ToolCall, payload: JsonNode): JsonNode {.gcsafe.} =
  ## OpenAI-compatible chat completions: role=tool with tool_call_id.
  ## Moonshot's tool-use docs include a required/expected `name` field.
  ##
  ## IMPORTANT: Moonshot Formula tools often expect the *raw string* output
  ## (including encrypted outputs) to be passed back as tool message content.
  ## If `payload` is already a JSON string node, we pass it through without
  ## JSON-quoting.
  let content =
    if payload != nil and payload.kind == JString:
      payload.getStr
    else:
      $payload
  kimi_builders.toolMessage(tool_call_id = call.callId, name = call.name, content = content)

# -----------------------------------------------------------------------------
# Tool schema normalization
# -----------------------------------------------------------------------------

proc isValidMoonshotFunctionName(name: string): bool =
  ## Moonshot requires: start with a letter; then letters/numbers/_/-.
  ## (This does NOT apply to official tools of type `builtin_function`.)
  ## (We don't throw here; we just avoid sending obviously-invalid names.)
  if name.len == 0: return false
  if not (name[0] in {'a'..'z', 'A'..'Z'}):
    return false
  for c in name:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      discard
    else:
      return false
  true

proc normalizeToolsForKimi(tools: seq[JsonNode]): seq[JsonNode] =
  ## The harness builds tools in the OpenAI *Responses API* shape:
  ##   {"type":"function","name":"x","description":"..","parameters":{...},"strict":true}
  ## Moonshot's chat-completions tool schema expects:
  ##   {"type":"function","function":{"name":"x","description":"..","parameters":{...}}}
  ##
  ## Additionally, Moonshot "official tools" may be declared as:
  ##   {"type":"builtin_function","function":{"name":"..."}}
  ##
  ## Convert when needed and pass-through tools already in Moonshot shapes.
  result = @[]
  for t in tools:
    if t.kind != JObject:
      continue
    if not t.hasKey("type"):
      continue

    let ty = t["type"].getStr

    if ty == "function":
      # If already in the correct shape, keep (after a basic name sanity check).
      if t.hasKey("function") and t["function"].kind == JObject:
        if t["function"].hasKey("name"):
          let nm = t["function"]["name"].getStr
          if not isValidMoonshotFunctionName(nm):
            continue
        result.add t
        continue

      # Convert from Responses-style to ChatCompletions-style.
      if not t.hasKey("name"):
        continue

      let nm = t["name"].getStr
      if not isValidMoonshotFunctionName(nm):
        # Skip invalid names; Moonshot will hard-error.
        continue

      var fn = %*{ "name": nm }
      if t.hasKey("description"):
        fn["description"] = t["description"]
      if t.hasKey("parameters"):
        fn["parameters"] = t["parameters"]

      result.add %*{
        "type": "function",
        "function": fn
      }

    elif ty == "builtin_function":
      # Official tools (implemented server-side). Keep if already in correct shape.
      if t.hasKey("function") and t["function"].kind == JObject:
        result.add t
        continue

      # Allow a shorthand form: {type:"builtin_function", name:"$tool"}
      if t.hasKey("name"):
        result.add %*{
          "type": "builtin_function",
          "function": {"name": t["name"]}
        }
        continue

    else:
      # Unknown tool type; ignore for Moonshot.
      discard

# -----------------------------------------------------------------------------
# Tool call extraction
# -----------------------------------------------------------------------------

proc extractToolCalls(resp: ChatCompletion): seq[ToolCall] =
  ## Tries to parse OpenAI-compatible tool_calls from the first choice.
  result = @[]
  if resp.choices.len == 0: return

  let choice0 = resp.choices[0]
  if choice0.kind != JObject: return
  if not choice0.hasKey("message"): return

  let msg = choice0["message"]
  if msg.kind != JObject: return

  if not msg.hasKey("tool_calls"): return
  let tcs = msg["tool_calls"]
  if tcs.kind != JArray: return

  for tc in tcs:
    if tc.kind != JObject: continue

    var id = if tc.hasKey("id"): tc["id"].getStr else: ""

    # OpenAI style: {type:"function", function:{name,arguments}}
    var name = ""
    var args = newJNull()

    if tc.hasKey("function") and tc["function"].kind == JObject:
      let fn = tc["function"]
      if fn.hasKey("name"): name = fn["name"].getStr
      if fn.hasKey("arguments"):
        let a = fn["arguments"]
        # arguments may be a JSON string or already parsed
        if a.kind == JString:
          try:
            args = parseJson(a.getStr)
          except CatchableError:
            args = %a.getStr
        else:
          args = a
    elif tc.hasKey("name"):
      name = tc["name"].getStr
      if tc.hasKey("arguments"):
        args = tc["arguments"]

    let callId = (if id.len > 0: id else: name)
    result.add ToolCall(id: callId, name: name, arguments: args, callId: callId)

proc toProviderUsage(rzResp: Rz[ChatCompletion]): base.Usage =
  if rzResp.ok and rzResp.val.usage.isSome:
    let u = rzResp.val.usage.get
    return base.Usage(
      inputTokens: u.promptTokens,
      outputTokens: u.completionTokens,
      totalTokens: u.totalTokens,
      cachedTokens: 0  # Kimi does not support prompt caching
    )
  base.Usage()

proc toProviderResponse(rzResp: Rz[ChatCompletion], requestJson: JsonNode): ProviderResponse =
  result.requestJson  = requestJson
  result.responseJson = %rzResp
  if not rzResp.ok:
    result.ok  = false
    result.err = rzResp.err
    return

  result.ok        = true
  result.id        = rzResp.val.id
  result.text      = rzResp.val.extractText()
  result.toolCalls = extractToolCalls(rzResp.val)
  result.usage     = toProviderUsage(rzResp)

# -----------------------------------------------------------------------------
# Turn execution
# -----------------------------------------------------------------------------

proc buildOptions(st: KimiChatTurnState): CreateChatCompletionOptions =
  let normTools = normalizeToolsForKimi(st.tools)
  CreateChatCompletionOptions(
    model: st.model,
    messages: st.turnMessages,
    tools: (if normTools.len > 0: some normTools else: none seq[JsonNode])
  )

proc maybeAppendAssistantMessage(st: KimiChatTurnState, rzResp: Rz[ChatCompletion]) =
  ## If the model produced tool_calls, we MUST append the assistant message
  ## containing tool_calls to the turnMessages for the follow-up call.
  if not rzResp.ok: return
  if rzResp.val.choices.len == 0: return
  let choice0 = rzResp.val.choices[0]
  if choice0.kind != JObject: return
  if not choice0.hasKey("message"): return
  let msg = choice0["message"]
  if msg.kind == JNull: return
  st.turnMessages.add msg

method startTurn*(
    p: KimiChatProvider,
    model: string,
    messages: seq[JsonNode],
    tools: seq[JsonNode],
    instructions: string,
    previousTurnId: Option[string]
  ): Future[tuple[state: TurnState, resp: ProviderResponse]] {.async, gcsafe.} =

  discard previousTurnId # no chaining concept

  var st = KimiChatTurnState(
    client: p.client,
    model: model,
    tools: tools,
    instructions: instructions,
    turnMessages: messages
  )

  let opts = st.buildOptions()
  let reqJson = %opts
  let rzResp = await p.client.createChatCompletion(opts)

  st.maybeAppendAssistantMessage(rzResp)

  return (state: st, resp: toProviderResponse(rzResp, reqJson))


method continueTurn*(
    p: KimiChatProvider,
    state: TurnState,
    toolOutputs: seq[JsonNode]
  ): Future[ProviderResponse] {.async, gcsafe.} =

  let st = KimiChatTurnState(state)

  for m in toolOutputs:
    st.turnMessages.add m

  let opts = st.buildOptions()
  let reqJson = %opts
  let rzResp = await p.client.createChatCompletion(opts)

  st.maybeAppendAssistantMessage(rzResp)

  return toProviderResponse(rzResp, reqJson)
