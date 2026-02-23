## Error handling utilities for OpenAI API
##
## Provides centralized error detection and parsing.

import
    std/json
    ,std/strutils

type
    OaiErrorKind* = enum
        oekNone
        oekApiError
        oekNetworkError
        oekParseError
        oekUnknown

    OaiError* = object
        kind*    : OaiErrorKind
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
        # Optional: require at least "message" to reduce false positives
        if err.hasKey("message") and err["message"].kind in {JString, JNull}:
            return true
        # or: if you accept any error object:
        return true
    except JsonParsingError:
        return false

proc parseApiError*(body: string): OaiError =
    ## Parse an API error from response body
    result = OaiError(kind: oekApiError, raw: body)
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

proc networkError*(msg: string): OaiError =
    OaiError(kind: oekNetworkError, message: msg)

proc parseError*(msg: string, raw = ""): OaiError =
    OaiError(kind: oekParseError, message: msg, raw: raw)

proc `$`*(err: OaiError): string =
    case err.kind
    of oekNone:
        "No error"
    of oekApiError:
        if err.code.len > 0:
            "[" & err.code & "] " & err.message
        else:
            err.message
    of oekNetworkError:
        "Network error: " & err.message
    of oekParseError:
        "Parse error: " & err.message
    of oekUnknown:
        "Unknown error: " & err.message
