## OpenAI Conversations API
## https://platform.openai.com/docs/api-reference/conversations
##
## Provides stateful conversation management with message history.

import
    std/asyncdispatch
    ,std/httpclient
    ,std/json
    ,std/options
    ,std/strformat
    ,std/strutils
    ,std/sequtils
    ,std/tables

import
    jsony
    ,rz

import
    types
    ,../oai_client
    ,../common/errors
    ,../../../general_helpers

export types

# -----------------------------------------------------------------------------
# Internal Helpers
# -----------------------------------------------------------------------------

proc buildIncludeQuery(includes: seq[IncludeOpt]): seq[(string, string)] =
    result = @[]
    for inc in includes:
        result.add(("include", $inc))

# =============================================================================
# CONVERSATIONS API
# =============================================================================

# -----------------------------------------------------------------------------
# Create Conversation
# -----------------------------------------------------------------------------

proc createConversationRaw*(
    client: OpenAIClient,
    options: CreateConversationOptions = CreateConversationOptions()
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/conversations/create
    ## Create a conversation - returns raw JSON string
    result = await client.post("/conversations", toOptJson(options))

proc createConversation*(
    client: OpenAIClient,
    options: CreateConversationOptions = CreateConversationOptions()
): Future[Rz[Conversation]] {.async.} =
    ## Create a conversation with typed response
    var reqBody: string
    try:
        reqBody = await createConversationRaw(client, options)
        if isApiError(reqBody):
            return rz.err[Conversation](reqBody)
    except CatchableError as e:
        return rz.err[Conversation](e.msg)
    
    let asObj = catch reqBody.asObj(Conversation):
        return rz.err[Conversation](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)

# -----------------------------------------------------------------------------
# Retrieve Conversation
# -----------------------------------------------------------------------------

proc getConversationRaw*(
    client: OpenAIClient,
    conversationId: string
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/conversations/retrieve
    ## Get a conversation by ID - returns raw JSON string
    result = await client.get(&"/conversations/{conversationId}")

proc getConversation*(
    client: OpenAIClient,
    conversationId: string
): Future[Rz[Conversation]] {.async.} =
    ## Get a conversation by ID - typed response
    var reqBody: string
    try:
        reqBody = await getConversationRaw(client, conversationId)
        if isApiError(reqBody):
            return rz.err[Conversation](reqBody)
    except CatchableError as e:
        return rz.err[Conversation](e.msg)
    
    let asObj = catch reqBody.asObj(Conversation):
        return rz.err[Conversation](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)

# -----------------------------------------------------------------------------
# Update Conversation
# -----------------------------------------------------------------------------

proc updateConversationRaw*(
    client: OpenAIClient,
    conversationId: string,
    options: UpdateConversationOptions
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/conversations/update
    ## Update a conversation's metadata - returns raw JSON string
    result = await client.post(&"/conversations/{conversationId}", toOptJson(options))

proc updateConversation*(
    client: OpenAIClient,
    conversationId: string,
    options: UpdateConversationOptions
): Future[Rz[Conversation]] {.async.} =
    ## Update a conversation's metadata - typed response
    var reqBody: string
    try:
        reqBody = await updateConversationRaw(client, conversationId, options)
        if isApiError(reqBody):
            return rz.err[Conversation](reqBody)
    except CatchableError as e:
        return rz.err[Conversation](e.msg)
    
    let asObj = catch reqBody.asObj(Conversation):
        return rz.err[Conversation](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)

proc updateConversation*(
    client: OpenAIClient,
    conversationId: string,
    metadata: Table[string, string]
): Future[Rz[Conversation]] {.async.} =
    ## Convenience overload with just metadata
    result = await updateConversation(
        client,
        conversationId,
        UpdateConversationOptions(metadata: metadata)
    )

# -----------------------------------------------------------------------------
# Delete Conversation
# -----------------------------------------------------------------------------

proc deleteConversationRaw*(
    client: OpenAIClient,
    conversationId: string
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/conversations/delete
    ## Delete a conversation - returns raw JSON string
    result = await client.delete(&"/conversations/{conversationId}")

proc deleteConversation*(
    client: OpenAIClient,
    conversationId: string
): Future[Rz[DeletedConversation]] {.async.} =
    ## Delete a conversation - typed response
    var reqBody: string
    try:
        reqBody = await deleteConversationRaw(client, conversationId)
        if isApiError(reqBody):
            return rz.err[DeletedConversation](reqBody)
    except CatchableError as e:
        return rz.err[DeletedConversation](e.msg)
    
    let asObj = catch reqBody.asObj(DeletedConversation):
        return rz.err[DeletedConversation](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)

# =============================================================================
# CONVERSATION ITEMS API
# =============================================================================

# -----------------------------------------------------------------------------
# List Items
# -----------------------------------------------------------------------------

proc listItemsRaw*(
    client: OpenAIClient,
    conversationId: string,
    options: ListItemsOptions = ListItemsOptions()
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/conversations/list-items
    ## List all items for a conversation - returns raw JSON string
    var query: seq[(string, string)] = @[]
    
    if options.after.isSome:
        query.add(("after", options.after.get))
    
    if options.`include`.isSome:
        for inc in options.`include`.get:
            query.add(("include", $inc))
    
    if options.limit.isSome:
        query.add(("limit", $options.limit.get))
    
    if options.order.isSome:
        query.add(("order", $options.order.get))
    
    result = await client.get(&"/conversations/{conversationId}/items", query)

proc listItems*(
    client: OpenAIClient,
    conversationId: string,
    options: ListItemsOptions = ListItemsOptions()
): Future[Rz[ConversationItemList]] {.async.} =
    ## List all items for a conversation - typed response
    var reqBody: string
    try:
        reqBody = await listItemsRaw(client, conversationId, options)
        if isApiError(reqBody):
            return rz.err[ConversationItemList](reqBody)
    except CatchableError as e:
        return rz.err[ConversationItemList](e.msg)
    
    let asObj = catch reqBody.asObj(ConversationItemList):
        return rz.err[ConversationItemList](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)

proc listItems*(
    client: OpenAIClient,
    conversationId: string,
    limit: int,
    order = oDesc
): Future[Rz[ConversationItemList]] {.async.} =
    ## Convenience overload with limit and order
    result = await listItems(
        client,
        conversationId,
        ListItemsOptions(limit: some(limit), order: some(order))
    )

# -----------------------------------------------------------------------------
# Create Items
# -----------------------------------------------------------------------------

proc createItemsRaw*(
    client: OpenAIClient,
    conversationId: string,
    options: CreateItemsOptions
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/conversations/create-items
    ## Create items in a conversation - returns raw JSON string
    var query: seq[(string, string)] = @[]
    
    if options.`include`.isSome:
        for inc in options.`include`.get:
            query.add(("include", $inc))
    
    let body = %*{"items": options.items}
    result = await client.post(&"/conversations/{conversationId}/items", body, query)

proc createItems*(
    client: OpenAIClient,
    conversationId: string,
    options: CreateItemsOptions
): Future[Rz[ConversationItemList]] {.async.} =
    ## Create items in a conversation - typed response
    var reqBody: string
    try:
        reqBody = await createItemsRaw(client, conversationId, options)
        if isApiError(reqBody):
            return rz.err[ConversationItemList](reqBody)
    except CatchableError as e:
        return rz.err[ConversationItemList](e.msg)
    
    let asObj = catch reqBody.asObj(ConversationItemList):
        return rz.err[ConversationItemList](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)

proc createItems*(
    client: OpenAIClient,
    conversationId: string,
    items: seq[JsonNode]
): Future[Rz[ConversationItemList]] {.async.} =
    ## Convenience overload with just items
    result = await createItems(
        client,
        conversationId,
        CreateItemsOptions(items: items)
    )

proc addItem*(
    client: OpenAIClient,
    conversationId: string,
    item: JsonNode
): Future[Rz[ConversationItemList]] {.async.} =
    ## Single item convenience
    result = await createItems(client, conversationId, @[item])

# -----------------------------------------------------------------------------
# Get Item
# -----------------------------------------------------------------------------

proc getItemRaw*(
    client: OpenAIClient,
    conversationId: string,
    itemId: string,
    options: GetItemOptions = GetItemOptions()
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/conversations/get-item
    ## Get a single item from a conversation - returns raw JSON string
    var query: seq[(string, string)] = @[]
    
    if options.`include`.isSome and options.`include`.get.len > 0:
        query = buildIncludeQuery(options.`include`.get)
    
    result = await client.get(&"/conversations/{conversationId}/items/{itemId}", query)

proc getItem*(
    client: OpenAIClient,
    conversationId: string,
    itemId: string,
    options: GetItemOptions = GetItemOptions()
): Future[Rz[JsonNode]] {.async.} =
    ## Get a single item from a conversation - returns JsonNode
    var reqBody: string
    try:
        reqBody = await getItemRaw(client, conversationId, itemId, options)
        if isApiError(reqBody):
            return rz.err[JsonNode](reqBody)
    except CatchableError as e:
        return rz.err[JsonNode](e.msg)
    
    try:
        let parsed = parseJson(reqBody)
        return rz.ok(parsed)
    except:
        return rz.err[JsonNode](&"Error parsing response: {reqBody}")

# -----------------------------------------------------------------------------
# Delete Item
# -----------------------------------------------------------------------------

proc deleteItemRaw*(
    client: OpenAIClient,
    conversationId: string,
    itemId: string
): Future[string] {.async.} =
    ## https://platform.openai.com/docs/api-reference/conversations/delete-item
    ## Delete an item from a conversation - returns raw JSON string
    result = await client.delete(&"/conversations/{conversationId}/items/{itemId}")

proc deleteItem*(
    client: OpenAIClient,
    conversationId: string,
    itemId: string
): Future[Rz[Conversation]] {.async.} =
    ## Delete an item from a conversation - returns updated conversation
    var reqBody: string
    try:
        reqBody = await deleteItemRaw(client, conversationId, itemId)
        if isApiError(reqBody):
            return rz.err[Conversation](reqBody)
    except CatchableError as e:
        return rz.err[Conversation](e.msg)
    
    let asObj = catch reqBody.asObj(Conversation):
        return rz.err[Conversation](&"Error parsing response. \nResponse -> {reqBody}\nError -> {it.err}")
    
    return rz.ok(asObj)


# =============================================================================
# Main Module Examples
# =============================================================================

when isMainModule:
    import
        mynimlib/[utils, keys]
        ,ic
        ,asyncdispatch
        ,../utils/builders

    let 
        client = newOpenAIClient(apiKey = keys.open_ai_api_key)
        convoId = "conv_698510be1c488190b39789962ff386b6021c7ec8fea3fee3"

    # nim r -d:ic -d:ssl -d:ex.create ./src/llmm/providers/oai/conversations/api.nim
    when defined(ex.create):
        icb waitFor client.createConversationRaw(CreateConversationOptions(
            metadata: some({"topic": "demo2"}.toTable),
            items: some(@[userMessage("Hello!")])
        ))

    # nim r -d:ic -d:ssl -d:ex.get ./src/llmm/providers/oai/conversations/api.nim
    when defined(ex.get):
        icb waitFor client.getConversation(convoId)

    # nim r -d:ic -d:ssl -d:ex.listitems ./src/llmm/providers/oai/conversations/api.nim
    when defined(ex.listitems):
        icb waitFor client.listItems(convoId, limit = 10)

    # Clean up
    client.close()
