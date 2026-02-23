## knowledge_tool.nim — LLM-facing knowledge/RAG tool
##
## Thin wrapper: tool definition + handler that delegates to KnowledgeStore.
## Same factory pattern as MemoryTool.
##
## Commands:
##   search        — semantic search over indexed documents
##   ingest        — index a file into the knowledge base
##   list_sources  — show what's been indexed
##   remove_source — delete a document and its chunks

import std/[
    json
    ,asyncdispatch
    ,strutils
    ,sequtils
    ,strformat
    ,options
]

import ic
import ../../tools/base
import ./knowledge
import ../../../embeddings


proc KnowledgeTool*(store: KnowledgeStore): Tool =
    ## Factory proc — captures the KnowledgeStore in the closure.
    let ks = store

    icb "KnowledgeTool factory initialized"

    Tool(
        name        : "knowledge"
        ,description: """Search and manage an indexed knowledge base of documents. Use this to find information from PDFs, text files, and other documents that have been ingested.

Commands:
- search: Semantic search across all indexed documents. Returns the most relevant chunks.
- ingest: Index a new file into the knowledge base (text, markdown, code files).
- list_sources: Show all indexed documents with their chunk counts.
- remove_source: Remove a document and all its chunks from the index."""

        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "command": {
                    "type"       : "string"
                    ,"enum"      : ["search", "ingest", "list_sources", "remove_source"]
                    ,"description": "The knowledge operation to perform"
                }
                ,"query": {
                    "type"       : "string"
                    ,"description": "Search query for 'search' command. Describe what you're looking for in natural language."
                }
                ,"k": {
                    "type"       : "integer"
                    ,"description": "Number of results to return for 'search'. Default 5, max 20."
                }
                ,"file_path": {
                    "type"       : "string"
                    ,"description": "Path to file to ingest. Required for 'ingest' command."
                }
                ,"title": {
                    "type"       : "string"
                    ,"description": "Optional title for the document being ingested."
                }
                ,"text": {
                    "type"       : "string"
                    ,"description": "Raw text to ingest directly (alternative to file_path for 'ingest')."
                }
                ,"document_id": {
                    "type"       : "integer"
                    ,"description": "Document ID for 'remove_source' command."
                }
            }
            ,"required": ["command"]
        }

        ,handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
            icb "knowledge tool handler invoked", $args

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
            icb "knowledge command " & command

            case command

            # ---------------------------------------------------------
            # SEARCH
            # ---------------------------------------------------------
            of "search":
                let query = parsedArgs.getOrDefault("query").getStr("")
                if query.len == 0:
                    icr "search: missing query"
                    return toolError("'query' is required for search command")

                let k = min(
                    parsedArgs.getOrDefault("k").getInt(5)
                    ,20
                )

                ic "Searching knowledge base", query, k

                try:
                    let results = await ks.search(query, k)

                    if results.len == 0:
                        icy "No matching knowledge found", query
                        return toolSuccess(%*{
                            "results": newJArray()
                            ,"count" : 0
                            ,"query" : query
                        }, message = "No matching documents found for this query.")

                    var arr = newJArray()
                    for r in results:
                        arr.add %*{
                            "chunk_id"   : r.chunkId
                            ,"document"  : r.title
                            ,"page"      : r.pageNo
                            ,"content"   : r.content
                            ,"distance"  : r.distance
                            ,"source"    : r.sourcePath
                        }

                    ic "Returning", results.len, "results"
                    return toolSuccess(%*{
                        "results": arr
                        ,"count" : results.len
                        ,"query" : query
                    }, message = &"Found {results.len} relevant chunks")

                except CatchableError as e:
                    icr "Search failed", e.msg
                    return toolError("Knowledge search failed: " & e.msg)

            # ---------------------------------------------------------
            # INGEST
            # ---------------------------------------------------------
            of "ingest":
                let filePath = parsedArgs.getOrDefault("file_path").getStr("")
                let rawText  = parsedArgs.getOrDefault("text").getStr("")
                let title    = parsedArgs.getOrDefault("title").getStr("")

                if filePath.len == 0 and rawText.len == 0:
                    icr "ingest: no file_path or text"
                    return toolError("Either 'file_path' or 'text' is required for ingest command")

                try:
                    var chunkCount: int

                    if rawText.len > 0:
                        # Ingest raw text
                        let docTitle = if title.len > 0: title else: "Untitled text"
                        ic "Ingesting raw text", docTitle, rawText.len, "chars"
                        chunkCount = await ks.ingestText(
                            text       = rawText
                            ,title     = docTitle
                            ,sourceType = "text"
                        )
                    else:
                        # Ingest file
                        ic "Ingesting file", filePath
                        chunkCount = await ks.ingestFile(
                            path  = filePath
                            ,title = title
                        )

                    let totalDocs   = ks.documentCount()
                    let totalChunks = ks.chunkCount()

                    return toolSuccess(%*{
                        "chunks_created" : chunkCount
                        ,"total_documents": totalDocs
                        ,"total_chunks"   : totalChunks
                    }, message = &"Ingested {chunkCount} chunks. Knowledge base: {totalDocs} docs, {totalChunks} total chunks.")

                except CatchableError as e:
                    icr "Ingestion failed", e.msg
                    return toolError("Ingestion failed: " & e.msg)

            # ---------------------------------------------------------
            # LIST_SOURCES
            # ---------------------------------------------------------
            of "list_sources":
                let docs = ks.listDocuments(limit = 50)

                var arr = newJArray()
                for d in docs:
                    arr.add %*{
                        "id"         : d.id
                        ,"title"     : d.title
                        ,"type"      : d.sourceType
                        ,"path"      : d.sourcePath
                        ,"chunks"    : d.chunkCount
                        ,"created_at": d.createdAt
                    }

                ic "Listed", docs.len, "documents"
                return toolSuccess(%*{
                    "documents"    : arr
                    ,"count"       : docs.len
                    ,"total_chunks": ks.chunkCount()
                })

            # ---------------------------------------------------------
            # REMOVE_SOURCE
            # ---------------------------------------------------------
            of "remove_source":
                let docId = parsedArgs.getOrDefault("document_id").getInt(0)
                if docId == 0:
                    icr "remove_source: missing document_id"
                    return toolError("'document_id' is required for remove_source command")

                ic "Removing document", docId

                let ok = ks.deleteDocument(docId)
                if ok:
                    ic "Document removed", docId
                    return toolSuccess(%*{
                        "removed_id"   : docId
                        ,"total_documents": ks.documentCount()
                        ,"total_chunks"  : ks.chunkCount()
                    }, message = "Document and its chunks have been removed.")
                else:
                    icr "Document not found", docId
                    return toolError("Document not found with id: " & $docId)

            else:
                icr "Unknown knowledge command", command
                return toolError(
                    "Unknown command: " & command &
                    ". Use: search, ingest, list_sources, remove_source"
                )
    )