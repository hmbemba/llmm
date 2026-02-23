## Moonshot (Kimi) Chat API - Extractors and Utilities
##
## Convenience helpers for extracting data from chat completions.

import
    std/options
    ,std/json

import
    rz

import
    types

# -----------------------------------------------------------------------------
# Text Extraction
# -----------------------------------------------------------------------------

proc extractText*(resp: ChatCompletion): string =
    ## Extract assistant text from the first choice (if present).
    ##
    ## OpenAI-compatible response shape:
    ##   choices[0].message.content
    if resp.choices.len == 0:
        return ""

    let c0 = resp.choices[0]
    if not c0.hasKey("message"):
        return ""

    let msg = c0["message"]
    if not msg.hasKey("content"):
        return ""

    let content = msg["content"]
    case content.kind
    of JString:
        return content.getStr
    else:
        # Some servers may return non-string content (arrays/objects).
        return $content

# -----------------------------------------------------------------------------
# Result Extensions - Access fields directly on Rz[ChatCompletion]
# -----------------------------------------------------------------------------

proc text*(r: Rz[ChatCompletion]): string =
    if not r.ok: "" else: r.val.extractText

proc id*(r: Rz[ChatCompletion]): string =
    if r.ok: r.val.id else: ""

proc model*(r: Rz[ChatCompletion]): string =
    if r.ok: r.val.model else: ""

proc tokens*(r: Rz[ChatCompletion]): int =
    if not r.ok: return 0
    if r.val.usage.isSome:
        r.val.usage.get.totalTokens
    else:
        0

proc promptTokens*(r: Rz[ChatCompletion]): int =
    if not r.ok: return 0
    if r.val.usage.isSome:
        r.val.usage.get.promptTokens
    else:
        0

proc completionTokens*(r: Rz[ChatCompletion]): int =
    if not r.ok: return 0
    if r.val.usage.isSome:
        r.val.usage.get.completionTokens
    else:
        0
