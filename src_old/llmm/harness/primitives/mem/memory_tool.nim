## memory/tool.nim — LLM-facing memory tool
##
## Thin wrapper: just the tool definition + handler that delegates to MemoryStore.
## Import the parent memory module for all actual logic.

import std/[
    json
    ,asyncdispatch
    ,strutils
    ,sequtils
    ,strformat
]

import ic
import ../../tools/base
import ./memory


proc MemoryTool*(store: MemoryStore): Tool =
    ## Factory proc — captures the MemoryStore in the closure.
    let s = store

    icb "MemoryTool factory initialized"

    Tool(
        name        : "memory"
        ,description: """Persistent memory system. Use this to store and retrieve information across conversations.

Commands:
- store: Save a new memory (fact, lesson, or summary)
- recall: Search memories by query and/or tags
- update: Update helpfulness score of a memory after using it
- list: List recent memories, optionally filtered by kind"""

        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "command": {
                    "type"       : "string"
                    ,"enum"      : ["store", "recall", "update", "list"]
                    ,"description": "The memory operation to perform"
                }
                ,"kind": {
                    "type"       : "string"
                    ,"enum"      : ["fact", "lesson", "summary"]
                    ,"description": "Memory category. Required for 'store'. Optional filter for 'recall' and 'list'."
                }
                ,"content": {
                    "type"       : "string"
                    ,"description": "The memory text to store. Required for 'store'."
                }
                ,"tags": {
                    "type"       : "array"
                    ,"items"     : {"type": "string"}
                    ,"description": "Tags for categorization (store) or filtering (recall)."
                }
                ,"source": {
                    "type"       : "string"
                    ,"enum"      : ["reflection", "correction", "tool_failure", "tool_recovery", "user_preference", "environment"]
                    ,"description": "What triggered this memory. Used with 'store'."
                }
                ,"query": {
                    "type"       : "string"
                    ,"description": "Search query for 'recall'. Matches against content and tags."
                }
                ,"memory_id": {
                    "type"       : "string"
                    ,"description": "ID of memory to update. Required for 'update'."
                }
                ,"helpfulness": {
                    "type"       : "number"
                    ,"description": "Helpfulness rating 0.0-1.0. Used with 'update'."
                }
                ,"limit": {
                    "type"       : "integer"
                    ,"description": "Max results to return. Default 5 for recall, 20 for list."
                }
            }
            ,"required": ["command"]
        }

        ,handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
            icb "memory tool handler invoked", $args

            # Guard: args might be a JSON string that needs parsing
            var parsedArgs = args
            if args.kind == JString:
                try:
                    parsedArgs = parseJson(args.getStr())
                    icy "Args were string-wrapped JSON, re-parsed"
                except:
                    icr "Invalid JSON arguments", $args
                    return toolError("Invalid JSON arguments: " & $args)

            if parsedArgs.kind != JObject:
                icr "Expected JObject, got", $parsedArgs.kind
                return toolError("Expected JSON object for arguments, got: " & $parsedArgs.kind)

            let command = parsedArgs["command"].getStr()
            icb "memory command " & command

            case command

            # ---------------------------------------------------------
            # STORE
            # ---------------------------------------------------------
            of "store":
                let content = parsedArgs.getOrDefault("content").getStr("")
                if content.len == 0:
                    icr "store: missing content"
                    return toolError("'content' is required for store command")

                let kindStr = parsedArgs.getOrDefault("kind").getStr("fact")
                let kind    = toMemoryKind(kindStr)
                let tags    = if parsedArgs.hasKey("tags"):
                        parsedArgs["tags"].getElems().mapIt(it.getStr())
                    else: @[]
                let source = parsedArgs.getOrDefault("source").getStr("reflection")

                ic kindStr, content, tags, source

                let entry = s.store(
                    kind    = kind
                    ,content = content
                    ,tags    = tags
                    ,source  = source
                )

                ic "Stored memory", entry.uid, entry.content
                return toolSuccess(%*{
                    "memory_id": entry.uid
                    ,"stored"  : entry.content
                }, message = "Memory stored successfully")

            # ---------------------------------------------------------
            # RECALL
            # ---------------------------------------------------------
            of "recall":
                let query = parsedArgs.getOrDefault("query").getStr("")
                let tags  = if parsedArgs.hasKey("tags"):
                        parsedArgs["tags"].getElems().mapIt(it.getStr())
                    else: @[]
                let limit = parsedArgs.getOrDefault("limit").getInt(5)

                ic query, tags, limit

                var filterKind = false
                var kind = mkFact
                if parsedArgs.hasKey("kind"):
                    filterKind = true
                    kind = toMemoryKind(parsedArgs["kind"].getStr("fact"))
                    ic "recall filtering by kind", $kind

                let results = s.recall(
                    query      = query
                    ,tags       = tags
                    ,kind       = kind
                    ,filterKind = filterKind
                    ,limit      = limit
                )

                ic "recall results", results.len

                if results.len == 0:
                    icy "No matching memories found", query
                    return toolSuccess(%*{"memories": newJArray(), "count": 0}
                        ,message = "No matching memories found")

                var arr = newJArray()
                for m in results:
                    arr.add(%*{
                        "id"          : m.uid
                        ,"kind"       : m.kind
                        ,"content"    : m.content
                        ,"tags"       : m.tags
                        ,"helpfulness": m.helpfulness
                        ,"source"     : m.source
                    })

                ic "Returning memories", results.len
                return toolSuccess(%*{
                    "memories": arr
                    ,"count"  : results.len
                }, message = &"Found {results.len} memories")

            # ---------------------------------------------------------
            # UPDATE
            # ---------------------------------------------------------
            of "update":
                let memId = parsedArgs.getOrDefault("memory_id").getStr("")
                if memId.len == 0:
                    icr "update: missing memory_id"
                    return toolError("'memory_id' is required for update command")

                let helpfulness = parsedArgs.getOrDefault("helpfulness").getFloat(-1.0)
                let newTags     = if parsedArgs.hasKey("tags"):
                        parsedArgs["tags"].getElems().mapIt(it.getStr())
                    else: @[]

                ic memId, helpfulness, newTags

                let ok = s.update(memId, helpfulness, newTags)
                if ok:
                    ic "Memory updated", memId
                    return toolSuccess(message = "Memory updated")
                else:
                    icr "Memory not found", memId
                    return toolError("Memory not found with id: " & memId)

            # ---------------------------------------------------------
            # LIST
            # ---------------------------------------------------------
            of "list":
                let limit = parsedArgs.getOrDefault("limit").getInt(20)

                var filterKind = false
                var kind = mkFact
                if parsedArgs.hasKey("kind"):
                    filterKind = true
                    kind = toMemoryKind(parsedArgs["kind"].getStr("fact"))
                    ic "list filtering by kind", $kind

                ic "Listing memories", limit, filterKind

                let results = s.list(kind = kind, filterKind = filterKind, limit = limit)
                var arr = newJArray()
                for m in results:
                    arr.add(%*{
                        "id"          : m.uid
                        ,"kind"       : m.kind
                        ,"content"    : m.content
                        ,"tags"       : m.tags
                        ,"helpfulness": m.helpfulness
                        ,"accessCount": m.accessCount
                        ,"source"     : m.source
                    })

                ic "Listed", results.len, "of", s.count(), "total"
                return toolSuccess(%*{
                    "memories"     : arr
                    ,"count"       : results.len
                    ,"total_stored": s.count()
                })

            else:
                icr "Unknown memory command", command
                return toolError("Unknown command: " & command & ". Use: store, recall, update, list")
    )