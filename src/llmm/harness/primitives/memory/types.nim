## memory_types.nim — Core memory data types
##
## Defines MemoryEntry (variant object by MemoryKind) and 
## JSON serialization helpers for persistent storage.

import std/[
json
,times
,strutils
,sequtils
,oids
,algorithm
]

type
    MemoryKind* = enum
        mkFact      ## Concrete info: user prefs, env details, file paths, names
        mkLesson    ## What worked/didn't: tool failures, successful patterns, gotchas
        mkSummary   ## Condensed session/task summaries

    MemoryEntry* = object
        id*            : string          ## Unique identifier
        createdAt*     : int64           ## Unix timestamp
        accessedAt*    : int64           ## Last accessed unix timestamp
        accessCount*   : int             ## Times retrieved
        helpfulness*   : float           ## 0.0..1.0 running average
        tags*          : seq[string]     ## Searchable tags
        kind*          : MemoryKind
        content*       : string          ## The actual memory text
        source*        : string          ## What produced this: "reflection", "correction", "tool_failure", "tool_recovery"


proc newMemoryEntry*(
    kind       : MemoryKind
    ,content   : string
    ,tags      : seq[string] = @[]
    ,source    : string = "reflection"
): MemoryEntry =
    let now = epochTime().int64
    MemoryEntry(
        id          : $genOid()
        ,createdAt  : now
        ,accessedAt : now
        ,accessCount: 0
        ,helpfulness: 0.5  # neutral starting score
        ,tags       : tags
        ,kind       : kind
        ,content    : content
        ,source     : source
    )


# ---------------------------------------------------------------------------
# JSON Serialization
# ---------------------------------------------------------------------------

proc `%`*(e: MemoryEntry): JsonNode =
    %*{
        "id"          : e.id
        ,"createdAt"  : e.createdAt
        ,"accessedAt" : e.accessedAt
        ,"accessCount": e.accessCount
        ,"helpfulness": e.helpfulness
        ,"tags"       : e.tags
        ,"kind"       : $e.kind
        ,"content"    : e.content
        ,"source"     : e.source
    }

proc toMemoryEntry*(j: JsonNode): MemoryEntry =
    result.id          = j["id"].getStr()
    result.createdAt   = j["createdAt"].getBiggestInt()
    result.accessedAt  = j["accessedAt"].getBiggestInt()
    result.accessCount = j["accessCount"].getInt()
    result.helpfulness = j["helpfulness"].getFloat()
    result.tags        = j["tags"].getElems().mapIt(it.getStr())
    result.kind        = parseEnum[MemoryKind](j["kind"].getStr())
    result.content     = j["content"].getStr()
    result.source      = j["source"].getStr()


# ---------------------------------------------------------------------------
# Scoring / Retrieval helpers
# ---------------------------------------------------------------------------

proc touchAccess*(e: var MemoryEntry) =
    ## Update access metadata when memory is retrieved
    e.accessedAt = epochTime().int64
    e.accessCount.inc

proc updateHelpfulness*(e: var MemoryEntry, newScore: float) =
    ## Exponential moving average (alpha = 0.3)
    const alpha = 0.3
    e.helpfulness = alpha * newScore + (1.0 - alpha) * e.helpfulness


proc relevanceScore*(e: MemoryEntry, queryTags: seq[string], queryTerms: seq[string]): float =
    ## Simple scoring: tag overlap + content keyword match + recency + helpfulness
    var score = 0.0

    # Tag overlap (strongest signal)
    let eTags = e.tags.mapIt(it.toLowerAscii)
    let qTags = queryTags.mapIt(it.toLowerAscii)
    for qt in qTags:
        if qt in eTags:
            score += 2.0

    # Content keyword match
    let contentLower = e.content.toLowerAscii
    for term in queryTerms:
        if term.toLowerAscii in contentLower:
            score += 1.0

    # Recency boost (decay over ~30 days)
    let ageSeconds = epochTime().int64 - e.accessedAt
    let ageDays    = ageSeconds.float / 86400.0
    score += max(0.0, 1.0 - (ageDays / 30.0))

    # Helpfulness boost
    score += e.helpfulness

    return score


proc sortByRelevance*(entries: var seq[MemoryEntry], queryTags: seq[string], queryTerms: seq[string]) =
    entries.sort(proc(a, b: MemoryEntry): int =
        let sa = relevanceScore(a, queryTags, queryTerms)
        let sb = relevanceScore(b, queryTags, queryTerms)
        cmp(sb, sa)  # descending
    )