## Common types shared between Conversations and Responses APIs
## 
## This module consolidates duplicate definitions like Role, Usage, etc.
## to prevent type mismatches when working with both APIs.

import
    std/options
    ,std/json
    ,std/tables

type
    # -------------------------------------------------------------------------
    # Shared Enums
    # -------------------------------------------------------------------------
    
    ## Role enum - unified for both Conversations and Responses APIs
    Role          * = enum
        rUser       = "user"
        rAssistant  = "assistant"
        rSystem     = "system"
        rDeveloper  = "developer"

    # https://platform.openai.com/docs/guides/conversation-state
    ChatMessage         * = object
        role            * : Role
        content         * : JsonNode   
        # {"role": "user", "content": "knock knock."},

    ## Content type enum for message content blocks
    ContentType         * = enum
        ctInputText       = "input_text"
        ctOutputText      = "output_text"
        ctInputImage      = "input_image"
        ctInputFile       = "input_file"
        ctRefusal         = "refusal"

    ## Status for items and responses
    Status          * = enum
        sInProgress   = "in_progress"
        sCompleted    = "completed"
        sIncomplete   = "incomplete"
        sFailed       = "failed"
        sCancelled    = "cancelled"
        sQueued       = "queued"

    ## Order for listing items
    Order   * = enum
        oAsc  = "asc"
        oDesc = "desc"

    # https://platform.openai.com/docs/guides/tools
    ToolType            * = enum
        ttWebSearch       = "web_search"
        ttFileSearch      = "file_search"
        ttCodeInterpreter = "code_interpreter"
        ttComputerUse     = "computer_use_preview"
        ttFunction        = "function"
        ttMcp             = "mcp"

    ## Service tier options
    ServiceTier* = enum
        stAuto     = "auto"
        stDefault  = "default"
        stFlex     = "flex"
        stPriority = "priority"

    ## Truncation strategy
    TruncationStrategy* = enum
        tsAuto     = "auto"
        tsDisabled = "disabled"

    ## Reasoning effort levels
    ReasoningEffort* = enum
        reLow    = "low"
        reMedium = "medium"
        reHigh   = "high"

    ## Text format types for structured outputs
    TextFormatType* = enum
        tftText       = "text"
        tftJsonObject = "json_object"
        tftJsonSchema = "json_schema"

    # -------------------------------------------------------------------------
    # Shared Data Types
    # -------------------------------------------------------------------------

    ## Token usage details for input tokens
    InputTokensDetails* = object
        cachedTokens*: int

    ## Token usage details for output tokens
    OutputTokensDetails* = object
        reasoningTokens*: int

    ## Token usage statistics - used by both APIs
    Usage* = object
        inputTokens*         : int
        outputTokens*        : int
        totalTokens*         : int
        inputTokensDetails*  : Option[InputTokensDetails]
        outputTokensDetails* : Option[OutputTokensDetails]

    ## Error information
    ApiError* = object
        errorType* : string
        message*   : string

    ## Incomplete response details
    IncompleteDetails* = object
        reason*: string

    ## Reasoning configuration
    ReasoningConfig* = object
        effort*  : Option[string]
        # https://platform.openai.com/docs/api-reference/responses/create#responses_create-reasoning-effort
        # none, minimal, low, medium, high, and xhigh.
        summary* : Option[string] 
        # https://platform.openai.com/docs/api-reference/responses/create#responses_create-reasoning-summary
        # One of auto, concise, or detailed.

    ## Text format configuration for structured outputs
    TextFormat* = object
        `type`* : TextFormatType
        name*   : Option[string]
        schema* : Option[JsonNode]
        strict* : Option[bool]

    ## Text output configuration
    TextConfig* = object
        format*    : Option[TextFormat]
        verbosity* : string  # "low", "medium", "high"

    # -------------------------------------------------------------------------
    # Include Options (shared between APIs with slight differences)
    # -------------------------------------------------------------------------

    ## Include options for API calls
    IncludeOpt* = enum
        ioWebSearchCallSources       = "web_search_call.action.sources"
        ioCodeInterpreterCallOutputs = "code_interpreter_call.outputs"
        ioComputerCallOutputImageUrl = "computer_call_output.output.image_url"
        ioFileSearchCallResults      = "file_search_call.results"
        ioMessageInputImageImageUrl  = "message.input_image.image_url"
        ioMessageOutputTextLogprobs  = "message.output_text.logprobs"
        ioReasoningEncryptedContent  = "reasoning.encrypted_content"

    # -------------------------------------------------------------------------
    # Function Call Type (used by extractors)
    # -------------------------------------------------------------------------

    ## Parsed function call from response output
    FunctionCall* = object
        id*        : string
        name*      : string
        arguments* : JsonNode
        callId*    : string


# -----------------------------------------------------------------------------
# Constructors / Helpers
# -----------------------------------------------------------------------------

proc initTextConfig*(verbosity = "medium"): TextConfig =
    TextConfig(verbosity: verbosity)

proc initTextFormat*(formatType = tftJsonSchema): TextFormat =
    TextFormat(`type`: formatType)

proc jsonSchemaFormat*(
    name: string,
    schema: JsonNode,
    strict = true
): TextFormat =
    ## Create a JSON schema format configuration for structured outputs
    TextFormat(
        `type`: tftJsonSchema,
        name: some(name),
        schema: some(schema),
        strict: some(strict)
    )

proc jsonOutputConfig*(schema: JsonNode, outputName = "my_json"): TextConfig =
    ## Create a JSON output configuration with the given schema
    TextConfig(
        format: some(jsonSchemaFormat(outputName, schema)),
        verbosity: "medium"
    )
