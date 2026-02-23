## Moonshot (Kimi) Chat API - Type definitions
## https://platform.moonshot.ai/docs/api/chat
##
## Moonshot's endpoint is OpenAI-compatible (Chat Completions style).

import
    std/options
    ,std/json

# -----------------------------------------------------------------------------
# Response Types
# -----------------------------------------------------------------------------

type
    ## Token usage (OpenAI-compatible)
    Usage* = object
        promptTokens*     : int
        completionTokens* : int
        totalTokens*      : int

    ## Chat completion response
    ChatCompletion* = object
        id*         : string
        objectType* : string           # e.g. "chat.completion"
        created*    : int64
        model*      : string
        choices*    : seq[JsonNode]
        usage*      : Option[Usage]

# -----------------------------------------------------------------------------
# Request Options
# -----------------------------------------------------------------------------

type
    ## Create chat completion options
    ## POST /chat/completions
    CreateChatCompletionOptions* = object
        model*             : string
        messages*          : seq[JsonNode]
        temperature*       : Option[float]
        top_p*             : Option[float]
        n*                 : Option[int]
        stream*            : Option[bool]
        stop*              : Option[JsonNode]     # string | [string]
        max_tokens*        : Option[int]
        presence_penalty*  : Option[float]
        frequency_penalty* : Option[float]
        tools*             : Option[seq[JsonNode]]
        tool_choice*       : Option[JsonNode]
        response_format*   : Option[JsonNode]
        seed*              : Option[int]
        user*              : Option[string]
        use_search*        : Option[bool]

# -----------------------------------------------------------------------------
# Constructors
# -----------------------------------------------------------------------------

proc initCreateChatCompletionOptions*(
    model: string,
    messages: seq[JsonNode],
    temperature = 1.0,
    max_tokens = 0,
    stream = false
): CreateChatCompletionOptions =
    ## Minimal constructor for POST /chat/completions
    result = CreateChatCompletionOptions(
        model: model,
        messages: messages
    )

    if temperature != 1.0:
        result.temperature = some(temperature)

    if max_tokens > 0:
        result.max_tokens = some(max_tokens)

    if stream:
        result.stream = some(true)
