## OpenAI Responses API
## https://platform.openai.com/docs/api-reference/responses
##
## Provides stateless completion API for text generation.

import
    std/asyncdispatch
    ,std/httpclient
    ,std/json
    ,std/options
    ,std/strformat
    ,std/strutils
    ,std/sequtils
    ,std/tables

import
    jsony
    ,rz
    ,ic

import
    types
    ,../oai_client
    ,../common/errors
    ,../../../general_helpers

export types

# -----------------------------------------------------------------------------
# Create Response
# -----------------------------------------------------------------------------

proc createResponseRaw*(
    client : OpenAIClient,
    options: CreateResponseOptions
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/responses/create
    ## Creates a model response - returns raw JSON string
    let opts = toOptJson(options)
    #icb opts
    result = await client.post("/responses", opts)

proc createResponse*(
    client: OpenAIClient,
    options: CreateResponseOptions
): Future[Rz[OpenAIResponse]] {.async.} =
    ## Creates a model response with typed response object
    var reqBody: string
    try:
        reqBody = await createResponseRaw(client, options)
        if isApiError(reqBody):
            return rz.err[OpenAIResponse](reqBody)
    except CatchableError as e:
        return rz.err[OpenAIResponse](e.msg)
    
    let asObj = catch reqBody.asObj(OpenAIResponse):
        return rz.err[OpenAIResponse](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)

# -----------------------------------------------------------------------------
# Get Response
# -----------------------------------------------------------------------------

proc getResponseRaw*(
    client: OpenAIClient,
    responseId: string,
    includes: seq[IncludeOpt] = @[]
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/responses/get
    ## Retrieves a model response with the given ID - returns raw JSON string
    var query: seq[(string, string)] = @[]
    for inc in includes:
        query.add(("include", $inc))
    
    result = await client.get(&"/responses/{responseId}", query)

proc getResponse*(
    client: OpenAIClient,
    responseId: string,
    includes: seq[IncludeOpt] = @[]
): Future[Rz[OpenAIResponse]] {.async.} =
    ## Retrieves a model response with the given ID - typed response
    var reqBody: string
    try:
        reqBody = await getResponseRaw(client, responseId, includes)
        if isApiError(reqBody):
            return rz.err[OpenAIResponse](reqBody)
    except CatchableError as e:
        return rz.err[OpenAIResponse](e.msg)
    
    let asObj = catch reqBody.asObj(OpenAIResponse):
        return rz.err[OpenAIResponse](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)

# -----------------------------------------------------------------------------
# Get Input Token Counts
# -----------------------------------------------------------------------------

proc getInputTokensRaw*(
    client: OpenAIClient,
    options: InputTokensOptions
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/responses/input-tokens
    ## Returns input token counts of the request - returns raw JSON string
    result = await client.post("/responses/input_tokens", toOptJson(options))


# =============================================================================
# Main Module Examples
# =============================================================================

when isMainModule:
    import
        mynimlib/[utils, keys]
        ,ic
        ,asyncdispatch
        ,../utils/builders

    let client = newOpenAIClient(apiKey = keys.open_ai_api_key)
    const model = "gpt-4o-mini"

    # nim r -d:ic -d:ssl -d:ex.crr ./src/llmm/providers/oai/responses/api.nim
    when defined(ex.crr):
        icb waitFor client.createResponseRaw(CreateResponseOptions(
            model: model,
            input: some(%"Hello, what is the capital of France?")
        ))

    # nim r -d:ic -d:ssl -d:ex.cr ./src/llmm/providers/oai/responses/api.nim
    when defined(ex.cr):
        let r = catch waitFor client.createResponse(CreateResponseOptions(
            model: model,
            input: some(%"Hello, what is the capital of France?")
        )):
            icr it.err
            quit 1
        ic r

    # nim r -d:ic -d:ssl -d:ex.crr.img ./src/llmm/providers/oai/responses/api.nim
    when defined(ex.crr.img):
        icb waitFor client.createResponseRaw(CreateResponseOptions(
            model: model,
            input: some(%[
                systemMessage("You are a pirate assistant. Answer like a pirate."),
                imageUrlInput(
                    "https://i.ytimg.com/vi/5530I_pYjbo/maxresdefault.jpg",
                    prompt = "Describe this image in detail."
                )
            ])
        ))

    # Clean up
    client.close()
