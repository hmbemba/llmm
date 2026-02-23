## multimodal.nim — Multimodal user input types for chatTurn
##
## Allows chatTurn to accept text, images (URL or base64), and files
## in a single user message. Backward-compatible: plain strings are
## automatically wrapped via `textInput()`.
##
## Usage:
##   # Simple text (same as before)
##   await agent.chatTurn("Hello world")
##
##   # Image + text
##   var inp = textInput("What's in this image?")
##   inp.withImage("https://example.com/photo.jpg")
##   await agent.chatTurn(inp)
##
##   # Base64 image
##   var inp = textInput("Describe this screenshot")
##   inp.withImageBase64("image/png", base64Data)
##   await agent.chatTurn(inp)

import std/[
    json
    ,sequtils
    ,strutils
]

type
    InputPartKind * = enum
        ipText
        ipImageUrl
        ipImageBase64
        ipFile

    InputPart * = object
        case kind *: InputPartKind
        of ipText:
            text *: string
        of ipImageUrl:
            url    *: string
            detail *: string  # "auto" | "low" | "high"
        of ipImageBase64:
            mediaType   *: string  # "image/png", "image/jpeg", etc.
            data        *: string  # base64-encoded
            imageDetail *: string  # "auto" | "low" | "high"
        of ipFile:
            fileId   *: string
            filename *: string

    UserInput * = object
        parts *: seq[InputPart]

# ============================================================================
# Constructors
# ============================================================================

proc textInput*(s: string): UserInput =
    ## Wrap a plain string as a UserInput (most common case).
    UserInput(parts: @[InputPart(kind: ipText, text: s)])

proc imageUrlInput*(url: string, detail = "auto"): UserInput =
    ## Create a UserInput with just an image URL.
    UserInput(parts: @[InputPart(kind: ipImageUrl, url: url, detail: detail)])

proc imageBase64Input*(mediaType, data: string, detail = "auto"): UserInput =
    UserInput(parts: @[InputPart(kind: ipImageBase64, mediaType: mediaType, data: data, imageDetail: detail)])

# ============================================================================
# Mutators — chain onto an existing UserInput
# ============================================================================

proc withText*(input: var UserInput, s: string) =
    input.parts.add InputPart(kind: ipText, text: s)

proc withImage*(input: var UserInput, url: string, detail = "auto") =
    input.parts.add InputPart(kind: ipImageUrl, url: url, detail: detail)

proc withImageBase64*(input: var UserInput, mediaType, data: string, detail = "auto") =
    input.parts.add InputPart(kind: ipImageBase64, mediaType: mediaType, data: data, imageDetail: detail)

proc withFile*(input: var UserInput, fileId, filename: string) =
    input.parts.add InputPart(kind: ipFile, fileId: fileId, filename: filename)

# ============================================================================
# Extraction helpers
# ============================================================================

proc plainText*(input: UserInput): string =
    ## Extract concatenated text parts (for logging, memory, db storage).
    input.parts.filterIt(it.kind == ipText).mapIt(it.text).join(" ")

proc isTextOnly*(input: UserInput): bool =
    ## True if all parts are plain text.
    input.parts.allIt(it.kind == ipText)

proc hasImages*(input: UserInput): bool =
    input.parts.anyIt(it.kind in {ipImageUrl, ipImageBase64})

proc hasFiles*(input: UserInput): bool =
    input.parts.anyIt(it.kind == ipFile)

# ============================================================================
# JSON serialization — builds the OpenAI content array
# ============================================================================

proc toContentArray*(input: UserInput): JsonNode =
    ## Convert parts to the OpenAI Responses API content array format.
    result = newJArray()
    for part in input.parts:
        case part.kind
        of ipText:
            result.add %*{
                "type": "input_text"
                ,"text": part.text
            }
        of ipImageUrl:
            result.add %*{
                "type": "input_image"
                ,"image_url": part.url
                ,"detail": part.detail
            }
        of ipImageBase64:
            result.add %*{
                "type": "input_image"
                ,"image": {
                    "type": "base64"
                    ,"media_type": part.mediaType
                    ,"data": part.data
                }
                ,"detail": part.imageDetail
            }
        of ipFile:
            result.add %*{
                "type": "input_file"
                ,"file_id": part.fileId
                ,"filename": part.filename
            }

proc toUserMessage*(input: UserInput): JsonNode =
    ## Build the full {"role": "user", ...} message node.
    ## Uses a plain string content for text-only input (cheaper / simpler),
    ## and the content array for multimodal.
    if input.isTextOnly and input.parts.len == 1:
        %*{"role": "user", "content": input.parts[0].text}
    else:
        %*{"role": "user", "content": toContentArray(input)}

proc `%`*(input: UserInput): JsonNode =
    ## JSON serialization for logging / db persistence.
    result = newJArray()
    for part in input.parts:
        case part.kind
        of ipText:
            result.add %*{"kind": "text", "text": part.text}
        of ipImageUrl:
            result.add %*{"kind": "image_url", "url": part.url, "detail": part.detail}
        of ipImageBase64:
            result.add %*{"kind": "image_base64", "media_type": part.mediaType, "detail": part.imageDetail, "data_len": part.data.len}
        of ipFile:
            result.add %*{"kind": "file", "file_id": part.fileId, "filename": part.filename}