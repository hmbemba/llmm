## Error handling utilities for the Moonshot (Kimi) API
##
## Moonshot's API is largely OpenAI-compatible and returns errors in an
## envelope like: {"error": { ... }}

import
    std/json
    ,std/strutils

type
    KimiErrorKind* = enum
        kekNone
        kekApiError
        kekNetworkError
        kekParseError
        kekUnknown

    KimiError* = object
        kind*    : KimiErrorKind
        message* : string
        code*    : string
        param*   : string
        raw*     : string

proc isApiError*(body: string): bool =
    ## Check if response body contains an API error envelope.
    ## Expected shape: { "error": { ... } }
    try:
        let root = parseJson(body)
        if root.kind != JObject: return false
        if not root.hasKey("error"): return false
        let err = root["error"]
        if err.kind != JObject: return false
        if err.hasKey("message") and err["message"].kind in {JString, JNull}:
            return true
        return true
    except JsonParsingError:
        return false

proc parseApiError*(body: string): KimiError =
    ## Parse an API error from response body
    result = KimiError(kind: kekApiError, raw: body)
    try:
        let json = parseJson(body)
        if json.hasKey("error"):
            let err = json["error"]
            if err.hasKey("message"):
                result.message = err["message"].getStr
            if err.hasKey("type"):
                result.code = err["type"].getStr
            if err.hasKey("param") and err["param"].kind != JNull:
                result.param = err["param"].getStr
    except:
        result.message = body

proc networkError*(msg: string): KimiError =
    KimiError(kind: kekNetworkError, message: msg)

proc parseError*(msg: string, raw = ""): KimiError =
    KimiError(kind: kekParseError, message: msg, raw: raw)

proc `$`*(err: KimiError): string =
    case err.kind
    of kekNone:
        "No error"
    of kekApiError:
        if err.code.len > 0:
            "[" & err.code & "] " & err.message
        else:
            err.message
    of kekNetworkError:
        "Network error: " & err.message
    of kekParseError:
        "Parse error: " & err.message
    of kekUnknown:
        "Unknown error: " & err.message
