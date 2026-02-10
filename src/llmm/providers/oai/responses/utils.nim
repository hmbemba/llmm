## Response Extractors and Utilities
##
## Convenience helpers for extracting data from OpenAI responses.
##
## Example:
##   let response = await client.createResponse(options)
##   if response.ok:
##       echo response.text           # Get text directly
##       echo response.tokens         # Get total tokens
##       echo response.functionCalls  # Get any function calls

import
    std/options
    ,std/json
    ,std/strutils
    ,std/sequtils

import
    rz

import
    types
    #,../common/types as common



# -----------------------------------------------------------------------------
# Text Extraction
# -----------------------------------------------------------------------------

proc extractText*(response: OpenAIResponse): string =
    ## Extract the text content from an OpenAI response.
    ## Iterates through output items and concatenates all output_text.
    result = ""
    for item in response.output:
        if item.hasKey("content"):
            for content in item["content"]:
                if content.hasKey("type") and content["type"].getStr == "output_text":
                    if content.hasKey("text"):
                        if result.len > 0:
                            result &= "\n"
                        result &= content["text"].getStr

# -----------------------------------------------------------------------------
# Result Extensions - Access fields directly on Rz[OpenAIResponse]
# -----------------------------------------------------------------------------

proc text*(r: Rz[OpenAIResponse]): string =
    ## Extract text from result, empty on error
    if not r.ok: "" else: r.val.extractText

proc textOr*(r: Rz[OpenAIResponse], default: string): string =
    ## Extract text with fallback
    if not r.ok:
        return default
    let t = r.val.extractText
    if t.len == 0: default else: t

proc id*(r: Rz[OpenAIResponse]): string =
    ## Get response ID, empty on error
    if r.ok: r.val.id else: ""

proc model*(r: Rz[OpenAIResponse]): string =
    ## Get model name, empty on error
    if r.ok: r.val.model else: ""

proc status*(r: Rz[OpenAIResponse]): string =
    ## Get status, empty on error
    if r.ok: r.val.status else: ""

proc tokens*(r: Rz[OpenAIResponse]): int =
    ## Get total tokens used, 0 on error
    if not r.ok: return 0
    if r.val.usage.isSome:
        r.val.usage.get.totalTokens
    else:
        0

proc inputTokens*(r: Rz[OpenAIResponse]): int =
    ## Get input tokens, 0 on error
    if not r.ok: return 0
    if r.val.usage.isSome:
        r.val.usage.get.inputTokens
    else:
        0

proc outputTokens*(r: Rz[OpenAIResponse]): int =
    ## Get output tokens, 0 on error
    if not r.ok: return 0
    if r.val.usage.isSome:
        r.val.usage.get.outputTokens
    else:
        0

# -----------------------------------------------------------------------------
# OpenAIResponse Direct Extractors
# -----------------------------------------------------------------------------

proc getText*(resp: OpenAIResponse): Option[string] =
    ## Get text as Option
    let t = resp.extractText
    if t.len > 0: some(t) else: none(string)

proc getTextLines*(resp: OpenAIResponse): seq[string] =
    ## Get text split into lines
    resp.extractText.splitLines.filterIt(it.len > 0)

proc getJson*(resp: OpenAIResponse): Option[JsonNode] =
    ## Try to parse response text as JSON
    try:
        let t = resp.extractText
        if t.len > 0:
            some(parseJson(t))
        else:
            none(JsonNode)
    except:
        none(JsonNode)

proc getUsage*(resp: OpenAIResponse): tuple[input: int, output: int, total: int] =
    ## Get usage as tuple
    if resp.usage.isSome:
        let u = resp.usage.get
        (u.inputTokens, u.outputTokens, u.totalTokens)
    else:
        (0, 0, 0)

proc isComplete*(resp: OpenAIResponse): bool =
    ## Check if response completed successfully
    resp.status == "completed"

proc isFailed*(resp: OpenAIResponse): bool =
    ## Check if response failed
    resp.status == "failed"

proc isInProgress*(resp: OpenAIResponse): bool =
    ## Check if response is still running
    resp.status == "in_progress" or resp.status == "queued"

proc getError*(resp: OpenAIResponse): Option[string] =
    ## Get error message if any
    if resp.error.isSome:
        some(resp.error.get.message)
    else:
        none(string)

# -----------------------------------------------------------------------------
# Function Call Extractors
# -----------------------------------------------------------------------------

proc functionCalls*(resp: OpenAIResponse): seq[FunctionCall] =
    ## Extract all function calls from response
    result = @[]
    for item in resp.output:
        if item.hasKey("type") and item["type"].getStr == "function_call":
            var fc = FunctionCall(
                name: if item.hasKey("name"): item["name"].getStr else: ""
            )
            if item.hasKey("id"):
                fc.id = item["id"].getStr
            if item.hasKey("call_id"):
                fc.callId = item["call_id"].getStr
            if item.hasKey("arguments"):
                try:
                    fc.arguments = parseJson(item["arguments"].getStr)
                except:
                    fc.arguments = %item["arguments"].getStr
            result.add(fc)

proc functionCalls*(r: Rz[OpenAIResponse]): seq[FunctionCall] =
    ## Extract function calls from result
    if r.ok: r.val.functionCalls else: @[]

proc hasFunctionCalls*(resp: OpenAIResponse): bool =
    ## Check if response has any function calls
    resp.functionCalls.len > 0

proc hasFunctionCalls*(r: Rz[OpenAIResponse]): bool =
    ## Check if result has any function calls
    r.ok and r.val.hasFunctionCalls

proc getFunction*(resp: OpenAIResponse, name: string): Option[FunctionCall] =
    ## Get a specific function call by name
    for fc in resp.functionCalls:
        if fc.name == name:
            return some(fc)
    none(FunctionCall)

# -----------------------------------------------------------------------------
# Web Search Extractors
# -----------------------------------------------------------------------------

type
    WebSearchResult* = object
        title*   : string
        url*     : string
        snippet* : string

proc webSearchResults*(resp: OpenAIResponse): seq[WebSearchResult] =
    ## Extract web search results if any
    result = @[]
    for item in resp.output:
        if item.hasKey("type") and item["type"].getStr == "web_search_call":
            if item.hasKey("results"):
                for res in item["results"]:
                    var wsr = WebSearchResult()
                    if res.hasKey("title"):
                        wsr.title = res["title"].getStr
                    if res.hasKey("url"):
                        wsr.url = res["url"].getStr
                    if res.hasKey("snippet"):
                        wsr.snippet = res["snippet"].getStr
                    result.add(wsr)

proc hasWebSearchResults*(resp: OpenAIResponse): bool =
    ## Check if response has web search results
    resp.webSearchResults.len > 0

# -----------------------------------------------------------------------------
# Output Item Iterators
# -----------------------------------------------------------------------------

iterator outputItems*(resp: OpenAIResponse): JsonNode =
    ## Iterate over all output items
    for item in resp.output:
        yield item

iterator textBlocks*(resp: OpenAIResponse): string =
    ## Iterate over all text content blocks
    for item in resp.output:
        if item.hasKey("content"):
            for content in item["content"]:
                if content.hasKey("type") and content["type"].getStr == "output_text":
                    if content.hasKey("text"):
                        yield content["text"].getStr

# -----------------------------------------------------------------------------
# Annotation Extractors
# -----------------------------------------------------------------------------

type
    Annotation* = object
        annotationType* : string
        text*           : string
        startIndex*     : int
        endIndex*       : int
        url*            : Option[string]
        title*          : Option[string]

proc annotations*(resp: OpenAIResponse): seq[Annotation] =
    ## Extract all annotations from response
    result = @[]
    for item in resp.output:
        if item.hasKey("content"):
            for content in item["content"]:
                if content.hasKey("annotations"):
                    for ann in content["annotations"]:
                        var a = Annotation()
                        if ann.hasKey("type"):
                            a.annotationType = ann["type"].getStr
                        if ann.hasKey("text"):
                            a.text = ann["text"].getStr
                        if ann.hasKey("start_index"):
                            a.startIndex = ann["start_index"].getInt
                        if ann.hasKey("end_index"):
                            a.endIndex = ann["end_index"].getInt
                        if ann.hasKey("url"):
                            a.url = some(ann["url"].getStr)
                        if ann.hasKey("title"):
                            a.title = some(ann["title"].getStr)
                        result.add(a)

proc citations*(resp: OpenAIResponse): seq[Annotation] =
    ## Get only URL citation annotations
    resp.annotations.filterIt(it.annotationType == "url_citation")

# -----------------------------------------------------------------------------
# Quick Checks
# -----------------------------------------------------------------------------

proc hasText*(resp: OpenAIResponse): bool =
    ## Check if response has any text content
    resp.extractText.len > 0

proc hasError*(resp: OpenAIResponse): bool =
    ## Check if response has an error
    resp.error.isSome

proc hasUsage*(resp: OpenAIResponse): bool =
    ## Check if response has usage info
    resp.usage.isSome
