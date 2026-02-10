## OpenAI Conversations API - Type definitions
## https://platform.openai.com/docs/api-reference/conversations
##
## Uses shared types from common/types.nim where applicable.

import
    std/options
    ,std/json
    ,std/tables

import
    ../common/types as common

export common.Role, common.Status, common.Order, common.Usage, common.IncludeOpt

type
    # -------------------------------------------------------------------------
    # Core Objects
    # -------------------------------------------------------------------------

    ## Conversation object
    ## https://platform.openai.com/docs/api-reference/conversations/object
    Conversation* = object
        id*         : string
        objectType* : string    # "conversation"
        createdAt*  : int64
        metadata*   : Option[Table[string, string]]

    ## Deleted conversation response
    DeletedConversation* = object
        id*         : string
        objectType* : string    # "conversation.deleted"
        deleted*    : bool

    # -------------------------------------------------------------------------
    # Item Types
    # -------------------------------------------------------------------------

    ## Item list response
    ## https://platform.openai.com/docs/api-reference/conversations/list-items-object
    ConversationItemList* = object
        objectType* : string    # "list"
        data*       : seq[JsonNode]
        firstId*    : string
        lastId*     : string
        hasMore*    : bool

    # -------------------------------------------------------------------------
    # Request Options
    # -------------------------------------------------------------------------

    ## https://platform.openai.com/docs/api-reference/conversations/create
    CreateConversationOptions* = object
        items*    : Option[seq[JsonNode]]
        metadata* : Option[Table[string, string]]

    ## https://platform.openai.com/docs/api-reference/conversations/update
    UpdateConversationOptions* = object
        metadata*: Table[string, string]

    ## https://platform.openai.com/docs/api-reference/conversations/list-items
    ListItemsOptions* = object
        after*     : Option[string]
        `include`* : Option[seq[IncludeOpt]]
        limit*     : Option[int]      # 1-100, default 20
        order*     : Option[Order]

    ## https://platform.openai.com/docs/api-reference/conversations/create-items
    CreateItemsOptions* = object
        items*     : seq[JsonNode]
        `include`* : Option[seq[IncludeOpt]]

    ## https://platform.openai.com/docs/api-reference/conversations/get-item
    GetItemOptions* = object
        `include`*: Option[seq[IncludeOpt]]


# -----------------------------------------------------------------------------
# Constructors
# -----------------------------------------------------------------------------

proc initCreateConversationOptions*(
    items: seq[JsonNode] = @[],
    metadata: Table[string, string] = initTable[string, string]()
): CreateConversationOptions =
    result = CreateConversationOptions()
    if items.len > 0:
        result.items = some(items)
    if metadata.len > 0:
        result.metadata = some(metadata)

proc initListItemsOptions*(
    after = "",
    includes: seq[IncludeOpt] = @[],
    limit = 0,
    order = oDesc
): ListItemsOptions =
    result = ListItemsOptions()
    if after.len > 0:
        result.after = some(after)
    if includes.len > 0:
        result.`include` = some(includes)
    if limit > 0:
        result.limit = some(limit)
    result.order = some(order)

proc initCreateItemsOptions*(
    items: seq[JsonNode],
    includes: seq[IncludeOpt] = @[]
): CreateItemsOptions =
    result = CreateItemsOptions(items: items)
    if includes.len > 0:
        result.`include` = some(includes)
