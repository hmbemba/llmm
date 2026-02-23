## harness/providers/base.nim
## Provider-agnostic interface used by the harness (tick/agent).
##
## Goal: keep the harness free of OpenAI/Kimi/Anthropic/Gemini specifics.

import std/[json, options, asyncdispatch]

import ../primitives/multimodal
import ../tools/base as tool_base

export multimodal # re-export UserInput helpers/types

# -----------------------------------------------------------------------------
# Common types (provider-agnostic)
# -----------------------------------------------------------------------------

type
  ProviderKind* = enum
    pkOpenAIResponses
    pkKimiChatCompletions

  Usage* = object
    inputTokens* : int
    outputTokens*: int
    totalTokens* : int

  ToolCall* = object
    ## Provider-agnostic tool call.
    ## `callId` is the identifier you must echo back with the tool output.
    id*       : string
    name*     : string
    arguments*: JsonNode
    callId*   : string

  ProviderResponse* = object
    ok*          : bool
    id*          : string
    text*        : string
    toolCalls*   : seq[ToolCall]
    usage*       : Usage
    err*         : string
    requestJson* : JsonNode
    responseJson*: JsonNode

  TurnState* = ref object of RootObj

  LlmProvider* = ref object of RootObj
    kind* : ProviderKind
    name* : string

# -----------------------------------------------------------------------------
# JSON helpers (for DB persistence)
# -----------------------------------------------------------------------------

proc `%`*(u: Usage): JsonNode =
  %*{
    "input_tokens": u.inputTokens,
    "output_tokens": u.outputTokens,
    "total_tokens": u.totalTokens
  }

proc `%`*(tc: ToolCall): JsonNode =
  %*{
    "id": tc.id,
    "name": tc.name,
    "arguments": tc.arguments,
    "call_id": tc.callId
  }

# -----------------------------------------------------------------------------
# Provider interface
# -----------------------------------------------------------------------------

method supportsBuiltInTools*(p: LlmProvider): bool {.base, gcsafe.} =
  ## Built-in tools = non-function tools like web_search, file_search, etc.
  ## Default: false (most OpenAI-compatible chat providers only support function tools).
  false

method supportsMultimodal*(p: LlmProvider): bool {.base, gcsafe.} =
  ## Whether `userMessage(UserInput)` can encode images/files.
  false

method systemMessage*(p: LlmProvider, content: string): JsonNode {.base, gcsafe.} =
  raise newException(ValueError, "systemMessage not implemented for provider: " & p.name)

method assistantMessage*(p: LlmProvider, content: string): JsonNode {.base, gcsafe.} =
  raise newException(ValueError, "assistantMessage not implemented for provider: " & p.name)

method userMessage*(p: LlmProvider, input: UserInput): JsonNode {.base, gcsafe.} =
  raise newException(ValueError, "userMessage not implemented for provider: " & p.name)

method buildToolOutput*(p: LlmProvider, call: ToolCall, payload: JsonNode): JsonNode {.base, gcsafe.} =
  ## Build the provider-specific message/item that returns tool output.
  raise newException(ValueError, "buildToolOutput not implemented for provider: " & p.name)

method startTurn*(
    p: LlmProvider,
    model: string,
    messages: seq[JsonNode],
    tools: seq[JsonNode],
    instructions: string,
    previousTurnId: Option[string]
  ): Future[tuple[state: TurnState, resp: ProviderResponse]] {.base, async, gcsafe.} =
  raise newException(ValueError, "startTurn not implemented for provider: " & p.name)

method continueTurn*(
    p: LlmProvider,
    state: TurnState,
    toolOutputs: seq[JsonNode]
  ): Future[ProviderResponse] {.base, async, gcsafe.} =
  raise newException(ValueError, "continueTurn not implemented for provider: " & p.name)

method reflection*(
    p: LlmProvider,
    model: string,
    lastTurnId: string,
    memTool: tool_base.Tool
  ): Future[void] {.base, async, gcsafe.} =
  ## Optional post-turn reflection loop. Default: no-op.
  discard
