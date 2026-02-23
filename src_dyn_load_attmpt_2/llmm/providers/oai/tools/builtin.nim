## Built-in Tools for OpenAI API
##
## Provides tool configurations for web search, file search,
## code interpreter, and computer use.
##
## https://platform.openai.com/docs/guides/tools

import std/json
,../../../harness/tools/base

# https://platform.openai.com/docs/guides/tools-connectors-mcp
# TODO
proc oaiMcpToolJson*(): JsonNode = %*{
    "type": "mcp",
}


# https://platform.openai.com/docs/guides/tools-shell
proc oaiShellToolJson*(): JsonNode =
    ## Create a shell tool configuration
    %*{"type": "shell"}
proc oaiShellTool*(): Tool = BuiltInTool oaiShellToolJson()


# https://platform.openai.com/docs/guides/tools-apply-patch
proc oaiApplyPatchToolJson*(): JsonNode = %*{
        "type": "apply_patch",
    }
proc oaiApplyPatchTool*(): Tool = BuiltInTool oaiApplyPatchToolJson()

proc oaiWebSearchToolJson*(searchContextSize = ""): JsonNode =
    ## Create a web search tool configuration
    ## searchContextSize can be "low", "medium", or "high"
    ## https://platform.openai.com/docs/guides/tools-web-search
    result = %*{"type": "web_search"}
    if searchContextSize.len > 0:
        result["search_context_size"] = %searchContextSize

proc oaiWebSearchTool*(searchContextSize = ""): Tool = BuiltInTool oaiWebSearchToolJson(searchContextSize)

# =============================================================================
# FILE SEARCH
# =============================================================================

# https://platform.openai.com/docs/guides/tools-file-search
proc oaiFileSearchTool*(vectorStoreIds: seq[string]): JsonNode = %*{
        "type": "file_search",
        "vector_store_ids": vectorStoreIds,
    }

# https://platform.openai.com/docs/guides/tools-image-generation
proc oaiImageGenerationJson*(): JsonNode = %*{"type": "image_generation"}
proc oaiImageGenerationTool*(): Tool = BuiltInTool oaiImageGenerationJson()

# https://platform.openai.com/docs/guides/tools-code-interpreter
proc oaiCodeInterpreterTool*(): JsonNode =
    ## Create a code interpreter tool configuration
    %*{"type": "code_interpreter_20250305"}

# https://platform.openai.com/docs/guides/tools-computer-use
proc oaiComputerUseTool*(
    displayWidth = 1024,
    displayHeight = 768,
    environment = "browser"
): JsonNode =
    ## Create a computer use tool configuration.
    ##
    ## Parameters:
    ## - displayWidth: Width of the display in pixels (default: 1024)
    ## - displayHeight: Height of the display in pixels (default: 768)
    ## - environment: The environment type - "browser", "mac", "windows", or "ubuntu"
    ##
    ## IMPORTANT NOTES:
    ## - The model MUST be "computer-use-preview"
    ## - truncation MUST be set to "auto" in CreateResponseOptions
    ## - This is a BETA feature
    ##
    ## Example:
    ##   var opts = initCreateResponseOptions(model = "computer-use-preview")
    ##   opts.truncation = "auto"
    ##   opts.tools = some(@[computerUseTool(1024, 768, "browser")])
    %*{
        "type": "computer_use_preview",
        "display_width": displayWidth,
        "display_height": displayHeight,
        "environment": environment
    }

proc oaiComputerCallOutput*(
    callId: string,
    screenshotBase64: string,
    acknowledgedSafetyCheckIds: seq[string] = @[]
): JsonNode =
    ## Create a computer_call_output item to send back to the model
    ## after executing an action and capturing a screenshot.
    ##
    ## Parameters:
    ## - callId: The call_id from the computer_call response item
    ## - screenshotBase64: Base64 encoded screenshot (PNG format recommended)
    ## - acknowledgedSafetyCheckIds: IDs of safety checks you've acknowledged
    ##
    ## Example:
    ##   let output = computerCallOutput(
    ##       callId = "call_abc123",
    ##       screenshotBase64 = encode(readFile("screenshot.png"))
    ##   )
    ##   opts.input = some(%*[output])
    result = %*{
        "type": "computer_call_output",
        "call_id": callId,
        "output": {
            "type": "input_image",
            "image_url": "data:image/png;base64," & screenshotBase64
        }
    }
    
    if acknowledgedSafetyCheckIds.len > 0:
        var checks = newJArray()
        for id in acknowledgedSafetyCheckIds:
            checks.add(%*{"id": id})
        result["acknowledged_safety_checks"] = checks
