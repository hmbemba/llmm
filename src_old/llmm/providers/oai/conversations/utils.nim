## Conversation Extractors and Utilities
##
## Convenience helpers for extracting data from conversation items.
##
## Example:
##   let items = await client.listItems("conv_123")
##   if items.ok:
##       for msg in items.val.messages:
##           echo msg.extractText

import
    std/options
    ,std/json
    ,std/strutils
    ,std/sequtils
    ,std/tables

import
    rz

import
    types
    ,../utils/common    


# -----------------------------------------------------------------------------
# Result Extensions - Access fields directly on Rz[Conversation]
# -----------------------------------------------------------------------------

proc id*(r: Rz[Conversation]): string =
    ## Get conversation ID, empty on error
    if r.ok: r.val.id else: ""

proc metadata*(r: Rz[Conversation]): Table[string, string] =
    ## Get metadata, empty table on error
    if not r.ok:
        return initTable[string, string]()
    if r.val.metadata.isSome:
        r.val.metadata.get
    else:
        initTable[string, string]()

proc createdAt*(r: Rz[Conversation]): int64 =
    ## Get creation timestamp, 0 on error
    if r.ok: r.val.createdAt else: 0

# -----------------------------------------------------------------------------
# ConversationItemList Extensions
# -----------------------------------------------------------------------------

proc items*(r: Rz[ConversationItemList]): seq[JsonNode] =
    ## Get all items from result
    if r.ok: r.val.data else: @[]

proc count*(r: Rz[ConversationItemList]): int =
    ## Get count of items
    if r.ok: r.val.data.len else: 0

proc hasMore*(r: Rz[ConversationItemList]): bool =
    ## Check if more items available
    if r.ok: r.val.hasMore else: false

proc firstId*(r: Rz[ConversationItemList]): string =
    ## Get first item ID for pagination
    if r.ok: r.val.firstId else: ""

proc lastId*(r: Rz[ConversationItemList]): string =
    ## Get last item ID for pagination
    if r.ok: r.val.lastId else: ""

# -----------------------------------------------------------------------------
# Item List Extractors
# -----------------------------------------------------------------------------

proc messages*(list: ConversationItemList): seq[JsonNode] =
    ## Extract only message items
    result = @[]
    for item in list.data:
        if item.hasKey("type") and item["type"].getStr == "message":
            result.add(item)

proc userMessages*(list: ConversationItemList): seq[JsonNode] =
    ## Extract only user messages
    result = @[]
    for item in list.data:
        if item.hasKey("type") and item["type"].getStr == "message":
            if item.hasKey("role") and item["role"].getStr == "user":
                result.add(item)

proc assistantMessages*(list: ConversationItemList): seq[JsonNode] =
    ## Extract only assistant messages
    result = @[]
    for item in list.data:
        if item.hasKey("type") and item["type"].getStr == "message":
            if item.hasKey("role") and item["role"].getStr == "assistant":
                result.add(item)

proc toolCalls*(list: ConversationItemList): seq[JsonNode] =
    ## Extract all tool call items
    result = @[]
    for item in list.data:
        if item.hasKey("type"):
            let itemType = item["type"].getStr
            if itemType.endsWith("_tool_call") or itemType.endsWith("_call"):
                result.add(item)

# -----------------------------------------------------------------------------
# Single Item Extractors
# -----------------------------------------------------------------------------

proc getRole*(item: JsonNode): string =
    ## Get role from a message item
    if item.hasKey("role"):
        item["role"].getStr
    else:
        ""

proc getStatus*(item: JsonNode): string =
    ## Get status from an item
    if item.hasKey("status"):
        item["status"].getStr
    else:
        ""

proc getId*(item: JsonNode): string =
    ## Get ID from an item
    if item.hasKey("id"):
        item["id"].getStr
    else:
        ""

proc getType*(item: JsonNode): string =
    ## Get type from an item
    if item.hasKey("type"):
        item["type"].getStr
    else:
        ""

proc isMessage*(item: JsonNode): bool =
    ## Check if item is a message
    item.getType == "message"

proc isUserMessage*(item: JsonNode): bool =
    ## Check if item is a user message
    item.isMessage and item.getRole == "user"

proc isAssistantMessage*(item: JsonNode): bool =
    ## Check if item is an assistant message
    item.isMessage and item.getRole == "assistant"

proc isCompleted*(item: JsonNode): bool =
    ## Check if item status is completed
    item.getStatus == "completed"

# -----------------------------------------------------------------------------
# Iterators
# -----------------------------------------------------------------------------

iterator allItems*(list: ConversationItemList): JsonNode =
    ## Iterate over all items
    for item in list.data:
        yield item

iterator allMessages*(list: ConversationItemList): JsonNode =
    ## Iterate over message items only
    for item in list.data:
        if item.isMessage:
            yield item

iterator allTexts*(list: ConversationItemList): string =
    ## Iterate over text content from all messages
    for item in list.data:
        if item.isMessage:
            let text = item.extractText
            if text.len > 0:
                yield text

# -----------------------------------------------------------------------------
# Conversation History Helpers
# -----------------------------------------------------------------------------

proc toInputItems*(list: ConversationItemList): seq[JsonNode] =
    ## Convert conversation items to input format for Responses API.
    ## Useful for continuing a conversation with the Responses API.
    result = @[]
    for item in list.data:
        # Messages can be passed directly
        if item.isMessage:
            result.add(item)
        # Tool calls and outputs can also be included
        elif item.hasKey("type"):
            result.add(item)

proc getLastAssistantMessage*(list: ConversationItemList): Option[JsonNode] =
    ## Get the most recent assistant message
    for i in countdown(list.data.len - 1, 0):
        let item = list.data[i]
        if item.isAssistantMessage:
            return some(item)
    none(JsonNode)

proc getLastUserMessage*(list: ConversationItemList): Option[JsonNode] =
    ## Get the most recent user message
    for i in countdown(list.data.len - 1, 0):
        let item = list.data[i]
        if item.isUserMessage:
            return some(item)
    none(JsonNode)
