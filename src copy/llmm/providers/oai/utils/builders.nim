## Content Builders for OpenAI API
##
## Provides ergonomic constructors for creating message content,
## including text, images, files, and tool outputs.
##
## Example:
##   let msg = userMessage("What is 2+2?")
##   let imgMsg = userMessage(%[
##       textInput("Describe this image"),
##       imageUrlInput("https://example.com/image.png")
##   ])

import
    std/json
    ,std/base64
    ,std/mimetypes

# =============================================================================
# TEXT INPUTS
# =============================================================================

proc textInput*(text: string): JsonNode =
    ## Create a text input content block
    ## https://platform.openai.com/docs/api-reference/responses/create#responses_create-input-input_item_list-input_message-content-input_item_content_list-input_text
    %*{
        "type": "input_text",
        "text": text
    }

# =============================================================================
# MESSAGE CONSTRUCTORS
# =============================================================================

proc userMessage*(content: JsonNode): JsonNode =
    ## Create a user message with JSON content
    %*{
        "type": "message",
        "role": "user",
        "content": content
    }

proc userMessage*(content: string): JsonNode =
    ## Create a user message with text content
    userMessage(%content)

proc systemMessage*(content: JsonNode): JsonNode =
    ## Create a system/developer message with JSON content
    %*{
        "type": "message",
        "role": "developer",
        "content": content
    }

proc systemMessage*(content: string): JsonNode =
    ## Create a system/developer message with text content
    systemMessage(%content)

proc developerMessage*(content: JsonNode): JsonNode =
    ## Create a developer message with JSON content (alias for systemMessage)
    %*{
        "type": "message",
        "role": "developer",
        "content": content
    }

proc developerMessage*(content: string): JsonNode =
    ## Create a developer message with text content
    developerMessage(%content)

proc assistantMessage*(content: JsonNode): JsonNode =
    ## Create an assistant message with JSON content
    %*{
        "type": "message",
        "role": "assistant",
        "content": content
    }

proc assistantMessage*(content: string): JsonNode =
    ## Create an assistant message with text content
    assistantMessage(%content)

# =============================================================================
# IMAGE INPUTS
# =============================================================================

proc imageUrlInput*(
    url: string,
    detail = "auto"
): JsonNode =
    ## Create an image URL input content block
    ## detail: "high", "low", or "auto"
    ## https://platform.openai.com/docs/api-reference/responses/create#responses_create-input-input_item_list-input_message-content-input_item_content_list-input_image
    %*{
        "type": "input_image",
        "image_url": url,
        "detail": detail
    }

proc imageUrlInput*(
    url: string,
    prompt: string,
    detail = "auto"
): JsonNode =
    ## Create a user message with an image URL and prompt
    var content = newJArray()
    content.add(textInput(prompt))
    content.add(%*{
        "type": "input_image",
        "image_url": url,
        "detail": detail
    })
    userMessage(content)

proc imageBase64Input*(
    base64Data: string,
    mediaType = "image/png"
): JsonNode =
    ## Create a base64 image input content block
    %*{
        "type": "input_image",
        "source": {
            "type": "base64",
            "media_type": mediaType,
            "data": base64Data
        }
    }

proc imageFileInput*(filePath: string, mediaType = ""): JsonNode =
    ## Create an image file input content block from a local file
    var 
        m = newMimetypes()
        fileData = encode(readFile(filePath))
        mediaTypeFinal = if mediaType.len > 0: mediaType else: m.getMimetype(filePath)
    imageBase64Input(fileData, mediaTypeFinal)

# =============================================================================
# FILE INPUTS
# =============================================================================

proc localFileInput*(
    filePath: string,
    fileName = ""
): JsonNode =
    ## Create a file input content block from a local file
    var fileData = encode(readFile(filePath))
    result = %*{
        "type": "input_file",
        "file_data": fileData
    }
    if fileName.len > 0:
        result["filename"] = %fileName

proc fileUrlInput*(
    fileUrl: string,
    fileName = ""
): JsonNode =
    ## Create a file input content block from a URL (must be a PDF)
    result = %*{
        "type": "input_file",
        "file_url": fileUrl
    }
    if fileName.len > 0:
        result["filename"] = %fileName

# =============================================================================
# ITEM REFERENCES
# =============================================================================

proc itemReference*(id: string): JsonNode =
    ## Create an item reference to include existing items
    ## https://platform.openai.com/docs/api-reference/conversations/create-items
    %*{
        "type": "item_reference",
        "id": id
    }

# =============================================================================
# TOOL CALL OUTPUTS
# =============================================================================

proc functionCallOutput*(callId: string, output: string): JsonNode =
    ## Create a function tool call output item
    %*{
        "type": "function_call_output",
        "call_id": callId,
        "output": output
    }

proc customToolCallOutput*(callId: string, output: string): JsonNode =
    ## Create a custom tool call output item
    %*{
        "type": "custom_tool_call_output",
        "call_id": callId,
        "output": output
    }
