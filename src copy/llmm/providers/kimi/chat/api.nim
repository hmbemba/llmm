## Moonshot (Kimi) Chat API
## https://platform.moonshot.ai/docs/api/chat
##
## Provides stateless chat completion API compatible with OpenAI's
## /v1/chat/completions.

import
    std/asyncdispatch
    ,std/json
    ,std/options
    ,std/strformat

import
    jsony
    ,rz

import
    types
    ,../kimi_client
    ,../common/errors
    ,../../../general_helpers

export types

# -----------------------------------------------------------------------------
# Create Chat Completion
# -----------------------------------------------------------------------------

proc createChatCompletionRaw*(
    client: KimiClient,
    options: CreateChatCompletionOptions
): Future[string] {.async.} =
    ## Creates a chat completion - returns raw JSON string
    ##
    ## NOTE: If `stream=true`, Moonshot will return an SSE stream. This
    ## proc will still return a string, but it may contain the full event
    ## stream rather than a single JSON object.
    result = await client.post("/chat/completions", toOptJson(options))

proc createChatCompletion*(
    client: KimiClient,
    options: CreateChatCompletionOptions
): Future[Rz[ChatCompletion]] {.async.} =
    ## Creates a chat completion - returns typed response object
    var reqBody: string
    try:
        reqBody = await createChatCompletionRaw(client, options)
        if isApiError(reqBody):
            return rz.err[ChatCompletion](reqBody)
    except CatchableError as e:
        return rz.err[ChatCompletion](e.msg)

    let asObj = catch reqBody.asObj(ChatCompletion):
        return rz.err[ChatCompletion](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")

    return rz.ok(asObj)

# =============================================================================
# Main Module Example
# =============================================================================

when isMainModule:
    import
        std/os
        ,ic
        ,../utils/builders

    let apiKey = getEnv("MOONSHOT_API_KEY")
    if apiKey.len == 0:
        quit "Please set MOONSHOT_API_KEY env var to run this example."

    let client = newKimiClient(apiKey = apiKey)
    const model = "moonshot-v1-8k"

    # nim r -d:ssl -d:ic ./src/llmm/providers/kimi/chat/api.nim
    icb waitFor client.createChatCompletionRaw(initCreateChatCompletionOptions(
        model = model,
        messages = @[userMessage("Hello! Please say 'pong'.")],
        temperature = 0.0
    ))
