## OpenAI Responses API - Type definitions
## https://platform.openai.com/docs/api-reference/responses
##
## Uses shared types from common/types.nim where applicable.

import
    std/options
    ,std/json
    ,std/tables

import
    ../common/types as common

export common.Role, common.Status, common.Usage, common.IncludeOpt
export common.TextFormat, common.TextConfig, common.TextFormatType
export common.ReasoningConfig, common.ReasoningEffort
export common.IncompleteDetails, common.ApiError, common.FunctionCall
export common.jsonSchemaFormat, common.jsonOutputConfig

type
    # -------------------------------------------------------------------------
    # Main Response Object
    # -------------------------------------------------------------------------

    ## OpenAI Response object
    ## https://platform.openai.com/docs/api-reference/responses/object
    OpenAIResponse* = object
        id*                 : string
        objectType*         : string    # "response"
        createdAt*          : int64
        status*             : string
        completedAt*        : Option[int64]
        error*              : Option[ApiError]
        incompleteDetails*  : Option[IncompleteDetails]
        instructions*       : Option[string]
        maxOutputTokens*    : Option[int]
        model*              : string
        output*             : seq[JsonNode]
        parallelToolCalls*  : bool
        previousResponseId* : Option[string]
        reasoning*          : Option[ReasoningConfig]
        store*              : bool
        temperature*        : float
        text*               : Option[TextConfig]
        toolChoice*         : Option[JsonNode]
        tools*              : seq[JsonNode]
        topP*               : float
        truncation*         : string
        usage*              : Option[Usage]
        user*               : Option[string]
        metadata*           : Option[Table[string, string]]

    ## Input items list response
    InputItemList* = object
        objectType* : string    # "list"
        data*       : seq[JsonNode]
        firstId*    : string
        lastId*     : string
        hasMore*    : bool

    ## Compacted response
    CompactedResponse* = object
        id*         : string
        objectType* : string    # "response.compaction"
        createdAt*  : int64
        output*     : seq[JsonNode]
        usage*      : Option[Usage]

    ## Delete response
    DeleteResponse* = object
        id*         : string
        objectType* : string    # "response"
        deleted*    : bool

    ## Input tokens response
    InputTokensResponse* = object
        objectType*  : string    # "response.input_tokens"
        inputTokens* : int

    # -------------------------------------------------------------------------
    # Request Options
    # -------------------------------------------------------------------------


    # https://platform.openai.com/docs/api-reference/responses/create#responses_create-include
    IncludeOpts * = enum
        ioWebSearchCallSources        = "web_search_call.action.sources"
        ioCodeInterpreterCallOutputs  = "code_interpreter_call.outputs"
        ioComputerCallOutputImageUrl  = "computer_call_output.output.image_url"
        ioFileSearchCallResults       = "file_search_call.results"
        ioMessageInputImageImageUrl   = "message.input_image.image_url"
        ioMessageOutputTextLogprobs   = "message.output_text.logprobs"
        ioReasoningEncryptedContent   = "reasoning.encrypted_content"
    


    # https://platform.openai.com/docs/api-reference/responses/create
    CreateResponseOptions   * = object
        background          * : Option[bool]             # https://platform.openai.com/docs/guides/background
        
        # https://platform.openai.com/docs/api-reference/responses/create#responses_create-context_management
        #context_management
        
        conversation        * : Option[string]           
        # https://platform.openai.com/docs/api-reference/responses/create#responses_create-conversation
        # https://platform.openai.com/docs/guides/conversation-state
        # conversation="conv_689667905b048191b4740501625afd940c7533ace33a2dab"


        `include`           * : Option[seq[IncludeOpts]] # https://platform.openai.com/docs/api-reference/responses/create#responses_create-include
        input               * : Option[JsonNode]         # https://platform.openai.com/docs/api-reference/responses/create#responses_create-input
        instructions        * : Option[string]           # https://platform.openai.com/docs/api-reference/responses/create#responses_create-instructions
        max_output_tokens     * : Option[int]              # https://platform.openai.com/docs/api-reference/responses/create#responses_create-max_output_tokens
        max_tool_calls        * : Option[int]              # https://platform.openai.com/docs/api-reference/responses/create#responses_create-max_tool_calls
        metadata            * : Option[Table[string, string]]
        model               * : string
        # https://platform.openai.com/docs/api-reference/responses/create#responses_create-model
        # https://platform.openai.com/docs/models
        parallel_tool_calls  * = true # https://platform.openai.com/docs/api-reference/responses/create#responses_create-parallel_tool_calls
        previous_response_id  * : Option[string]
        prompt              * : Option[JsonNode] # Reference to a prompt template and its variables. 
        prompt_cache_key      * : Option[string]
        prompt_cache_retention * : Option[string]
        reasoning           * : Option[ReasoningConfig]
        safety_identifier    * : Option[string]
        service_tier         * = "auto" # auto | default | flex | priority
        store               * = true
        stream              * = false # https://platform.openai.com/docs/api-reference/responses/create#responses_create-stream
        stream_options      * : Option[JsonNode]
        temperature         * : Option[float]
        text                * : Option[TextConfig]
        tool_choice          * : Option[JsonNode] # https://platform.openai.com/docs/api-reference/responses/create#responses_create-tool_choice
        tools               * : Option[seq[JsonNode]]
        top_logprobs         * : Option[int]
        top_p                * : Option[float]
        truncation          * = "disabled" # auto | disabled

    ## Input tokens request options
    InputTokensOptions     * = object
        model              * : string
        input              * : Option[JsonNode]
        instructions       * : Option[string]
        previousResponseId * : Option[string]
        conversation       * : Option[JsonNode]
        parallelToolCalls  * : Option[bool]
        reasoning          * : Option[ReasoningConfig]
        text               * : Option[TextConfig]
        toolChoice         * : Option[JsonNode]
        tools              * : Option[seq[JsonNode]]
        truncation         * : Option[string]


# -----------------------------------------------------------------------------
# Constructors
# -----------------------------------------------------------------------------

proc initCreateResponseOptions*(
    model: string,
    input: JsonNode = nil,
    instructions = "",
    tools: seq[JsonNode] = @[],
    temperature = 1.0,
    store = true
): CreateResponseOptions =
    result = CreateResponseOptions(
        model: model,
        parallel_tool_calls: true,
        service_tier: "auto",
        store: store,
        stream: false,
        truncation: "disabled"
    )
    if input != nil:
        result.input = some(input)
    if instructions.len > 0:
        result.instructions = some(instructions)
    if tools.len > 0:
        result.tools = some(tools)
    if temperature != 1.0:
        result.temperature = some(temperature)
