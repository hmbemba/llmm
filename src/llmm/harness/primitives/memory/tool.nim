## memory_tool.nim — LLM-facing memory tool
##
## A single tool with a `command` field: store, recall, update, list
## Follows the same pattern as HITLTool.

import std/[
json
,asyncdispatch
,strutils
,sequtils
,strformat
]

import ../../tools/base
,types
,store


proc MemoryTool*(store: MemoryStore): Tool =
    ## Factory proc — captures the MemoryStore in the closure.
    let s = store

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
            let command = args["command"].getStr()

            case command
            # ---------------------------------------------------------
            # STORE
            # ---------------------------------------------------------
            of "store":
                let content = args.getOrDefault("content").getStr("")
                if content.len == 0:
                    return toolError("'content' is required for store command")

                let kindStr = args.getOrDefault("kind").getStr("fact")
                let kind = case kindStr
                    of "fact"   : mkFact
                    of "lesson" : mkLesson
                    of "summary": mkSummary
                    else        : mkFact

                let tags = if args.hasKey("tags"):
                        args["tags"].getElems().mapIt(it.getStr())
                    else: @[]

                let source = args.getOrDefault("source").getStr("reflection")

                let entry = s.store(
                    kind    = kind
                    ,content = content
                    ,tags    = tags
                    ,source  = source
                )

                return toolSuccess(%*{
                    "memory_id": entry.id
                    ,"stored"  : entry.content
                }, message = "Memory stored successfully")

            # ---------------------------------------------------------
            # RECALL
            # ---------------------------------------------------------
            of "recall":
                let query = args.getOrDefault("query").getStr("")
                let tags  = if args.hasKey("tags"):
                        args["tags"].getElems().mapIt(it.getStr())
                    else: @[]
                let limit = args.getOrDefault("limit").getInt(5)

                var filterKind = false
                var kind = mkFact
                if args.hasKey("kind"):
                    filterKind = true
                    let kindStr = args["kind"].getStr("fact")
                    kind = case kindStr
                        of "fact"   : mkFact
                        of "lesson" : mkLesson
                        of "summary": mkSummary
                        else        : mkFact

                let results = s.recall(
                    query      = query
                    ,tags      = tags
                    ,kind      = kind
                    ,filterKind = filterKind
                    ,limit     = limit
                )

                if results.len == 0:
                    return toolSuccess(%*{"memories": newJArray(), "count": 0}
                        ,message = "No matching memories found")

                var arr = newJArray()
                for m in results:
                    arr.add(%*{
                        "id"          : m.id
                        ,"kind"       : $m.kind
                        ,"content"    : m.content
                        ,"tags"       : m.tags
                        ,"helpfulness": m.helpfulness
                        ,"source"     : m.source
                    })

                return toolSuccess(%*{
                    "memories": arr
                    ,"count"  : results.len
                }, message = &"Found {results.len} memories")

            # ---------------------------------------------------------
            # UPDATE
            # ---------------------------------------------------------
            of "update":
                let memId = args.getOrDefault("memory_id").getStr("")
                if memId.len == 0:
                    return toolError("'memory_id' is required for update command")

                let helpfulness = args.getOrDefault("helpfulness").getFloat(-1.0)
                let newTags     = if args.hasKey("tags"):
                        args["tags"].getElems().mapIt(it.getStr())
                    else: @[]

                let ok = s.update(memId, helpfulness, newTags)
                if ok:
                    return toolSuccess(message = "Memory updated")
                else:
                    return toolError("Memory not found with id: " & memId)

            # ---------------------------------------------------------
            # LIST
            # ---------------------------------------------------------
            of "list":
                let limit = args.getOrDefault("limit").getInt(20)

                var filterKind = false
                var kind = mkFact
                if args.hasKey("kind"):
                    filterKind = true
                    let kindStr = args["kind"].getStr("fact")
                    kind = case kindStr
                        of "fact"   : mkFact
                        of "lesson" : mkLesson
                        of "summary": mkSummary
                        else        : mkFact

                let results = s.list(kind = kind, filterKind = filterKind, limit = limit)
                var arr = newJArray()
                for m in results:
                    arr.add(%*{
                        "id"          : m.id
                        ,"kind"       : $m.kind
                        ,"content"    : m.content
                        ,"tags"       : m.tags
                        ,"helpfulness": m.helpfulness
                        ,"accessCount": m.accessCount
                        ,"source"     : m.source
                    })

                return toolSuccess(%*{
                    "memories"    : arr
                    ,"count"      : results.len
                    ,"total_stored": s.count()
                })

            else:
                return toolError("Unknown command: " & command & ". Use: store, recall, update, list")
    )