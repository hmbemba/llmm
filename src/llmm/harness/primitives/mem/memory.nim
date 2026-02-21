## memory.nim — Persistent agent memory backed by SQLite (via debby)
##
## Consolidates: types, store, scoring, integration, prompts
## Storage: SQLite database using debby ORM
##
## NOTE: MemoryStore now accepts an external Db handle from AgentStore
## rather than opening its own database. This enables a single unified db.
##
## Usage:
##   let agentStore = newAgentStore("path/to/agent.db")
##   let ms = newMemoryStore(agentStore.db)
##   let entry = ms.store(mkFact, "User prefers tabs over spaces", @["preferences"], "user_preference")
##   let results = ms.recall(query = "tabs spaces", limit = 5)

import std/[
json
,times
,strutils
,sequtils
,oids
,algorithm
,strformat
,tables
,sets
,options
]

import debby/sqlite
import ic
import ../../../debby_utils

# ============================================================================
# Types
# ============================================================================

type
    MemoryKind * = enum
        mkFact    ## Concrete info: user prefs, env details, file paths, names
        mkLesson  ## What worked/didn't: tool failures, successful patterns, gotchas
        mkSummary ## Condensed session/task summaries

    MemoryEntry * = ref object
        id          * : int           ## debby auto-increment PK
        uid         * : string        ## OID-based identifier (what the LLM sees)
        createdAt   * : int64         ## Unix timestamp
        accessedAt  * : int64         ## Last accessed unix timestamp
        accessCount * : int           ## Times retrieved
        helpfulness * : float         ## 0.0..1.0 running average
        tags        * : seq[string]   ## Searchable tags (stored as JSON by debby)
        kind        * : string        ## "mkFact", "mkLesson", "mkSummary" (stored as string for debby)
        content     * : string        ## The actual memory text
        source      * : string        ## What produced this: "reflection", "correction", etc.

    MemoryStore * = ref object
        db * : Db                     ## Shared database handle (owned by AgentStore)

# ============================================================================
# MemoryKind helpers
# ============================================================================

proc toMemoryKind*(s: string): MemoryKind =
    case s
    of "mkFact", "fact"      : mkFact
    of "mkLesson", "lesson"  : mkLesson
    of "mkSummary", "summary": mkSummary
    else                      : mkFact

proc toDbString*(k: MemoryKind): string =
    case k
    of mkFact   : "mkFact"
    of mkLesson : "mkLesson"
    of mkSummary: "mkSummary"

proc kindLabel*(k: MemoryKind): string =
    case k
    of mkFact   : "FACT"
    of mkLesson : "LESSON"
    of mkSummary: "SUMMARY"

proc memoryKind*(e: MemoryEntry): MemoryKind =
    toMemoryKind(e.kind)

# ============================================================================
# MemoryEntry JSON (for tool responses / LLM-facing serialization)
# ============================================================================

proc `%`*(e: MemoryEntry): JsonNode =
    %*{
        "id"          : e.uid
        ,"kind"       : e.kind
        ,"content"    : e.content
        ,"tags"       : e.tags
        ,"helpfulness": e.helpfulness
        ,"accessCount": e.accessCount
        ,"source"     : e.source
        ,"createdAt"  : e.createdAt
        ,"accessedAt" : e.accessedAt
    }

# ============================================================================
# Initialization
# ============================================================================

proc newMemoryStore*(db: Db): MemoryStore =
    ## Create a MemoryStore using a shared Db handle.
    ## The caller (AgentStore) owns the database connection.
    icb "=== Initializing MemoryStore (shared Db) ==="
    result = MemoryStore(db: db)
    result.db.initTable MemoryEntry

    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_memory_entry_uid
        ON memory_entry (uid);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_memory_entry_kind
        ON memory_entry (kind);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_memory_entry_access_count
        ON memory_entry (access_count);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_memory_entry_helpfulness
        ON memory_entry (helpfulness);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_memory_entry_accessed_at
        ON memory_entry (accessed_at);
    """

    let count = result.db.query("SELECT count(*) as c FROM memory_entry")[0][0].parseInt
    ic "MemoryStore ready", count, "entries"

# ============================================================================
# CRUD
# ============================================================================

proc store*(s: MemoryStore, kind: MemoryKind, content: string, tags: seq[string] = @[], source: string = "reflection"): MemoryEntry =
    icb "store()", kind, content.len, "chars", tags, source
    let now = epochTime().int64
    var entry = MemoryEntry(
        uid         : $genOid()
        ,createdAt  : now
        ,accessedAt : now
        ,accessCount: 0
        ,helpfulness: 0.5
        ,tags       : tags
        ,kind       : toDbString(kind)
        ,content    : content
        ,source     : source
    )
    s.db.insert(entry)
    ic "Stored new entry", entry.id, entry.uid, entry.kind
    return entry

proc store*(s: MemoryStore, entry: MemoryEntry): MemoryEntry =
    ## Insert a pre-built entry. Assigns uid if empty.
    var e = entry
    if e.uid.len == 0:
        e.uid = $genOid()
    if e.createdAt == 0:
        let now = epochTime().int64
        e.createdAt = now
        e.accessedAt = now
    s.db.insert(e)
    ic "Stored entry", e.id, e.uid
    return e


proc getByUid*(s: MemoryStore, uid: string): MemoryEntry =
    ## Get a single entry by its LLM-facing uid. Raises if not found.
    let results = s.db.filter(MemoryEntry, it.uid == uid)
    if results.len == 0:
        raise newException(KeyError, "Memory not found: " & uid)
    return results[0]

proc findByUid*(s: MemoryStore, uid: string): Option[MemoryEntry] =
    ## Get a single entry by uid, or none.
    let results = s.db.filter(MemoryEntry, it.uid == uid)
    if results.len > 0: some(results[0]) else: none(MemoryEntry)


proc update*(s: MemoryStore, uid: string, helpfulness: float = -1.0, newTags: seq[string] = @[]): bool =
    icb "update()", uid, helpfulness, newTags
    let opt = s.findByUid(uid)
    if opt.isNone:
        icr "update: memory not found", uid
        return false

    var entry = opt.get
    if helpfulness >= 0.0:
        # Exponential moving average (alpha = 0.3)
        const alpha = 0.3
        let old = entry.helpfulness
        entry.helpfulness = alpha * helpfulness + (1.0 - alpha) * entry.helpfulness
        ic "Helpfulness updated", uid, old, "->", entry.helpfulness
    if newTags.len > 0:
        entry.tags = newTags
        ic "Tags updated", uid, newTags

    s.db.update(entry)
    return true


proc delete*(s: MemoryStore, uid: string): bool =
    icb "delete()", uid
    let opt = s.findByUid(uid)
    if opt.isNone:
        icr "delete: memory not found", uid
        return false
    s.db.delete(opt.get)
    ic "Deleted memory", uid
    return true


proc touchAccess*(s: MemoryStore, entry: MemoryEntry) =
    ## Update access metadata when memory is retrieved.
    var e = entry
    e.accessedAt = epochTime().int64
    e.accessCount = e.accessCount + 1
    s.db.update(e)
    ic "Touched", e.uid, "access count now", e.accessCount

proc count*(s: MemoryStore): int =
    s.db.query("SELECT count(*) as c FROM memory_entry")[0][0].parseInt

# ============================================================================
# Retrieval / Recall
# ============================================================================

proc list*(s: MemoryStore, kind: MemoryKind = mkFact, filterKind: bool = false, limit: int = 20): seq[MemoryEntry] =
    icb "list()", filterKind, kind, limit
    if filterKind:
        let kindStr = toDbString(kind)
        result = s.db.query(MemoryEntry,
            "SELECT * FROM memory_entry WHERE kind = ? ORDER BY accessed_at DESC LIMIT ?",
            kindStr, limit)
    else:
        result = s.db.query(MemoryEntry,
            "SELECT * FROM memory_entry ORDER BY accessed_at DESC LIMIT ?",
            limit)
    ic "list returning", result.len


proc topKMemories*(s: MemoryStore, k: int): seq[MemoryEntry] =
    ## Returns up to k best entries by access count and helpfulness.
    icb "topKMemories()", k
    result = s.db.query(MemoryEntry,
        "SELECT * FROM memory_entry ORDER BY access_count DESC, helpfulness DESC LIMIT ?",
        k)
    ic "topK returning", result.len


proc recall*(
    s           : MemoryStore
    ,query      : string = ""
    ,tags       : seq[string] = @[]
    ,kind       : MemoryKind = mkFact
    ,filterKind : bool = false
    ,limit      : int = 5
): seq[MemoryEntry] =
    ## Search memories by query terms, tags, and optionally kind.
    ## Uses SQL LIKE for content matching and in-memory tag scoring for ranking.
    icb "recall()", query, tags, filterKind, kind, limit

    # Fetch a broad candidate set from SQLite, then score/rank in Nim
    let fetchLimit = min(limit * 10, 200)
    var candidates: seq[MemoryEntry]

    if filterKind:
        let kindStr = toDbString(kind)
        candidates = s.db.query(MemoryEntry,
            "SELECT * FROM memory_entry WHERE kind = ? ORDER BY access_count DESC LIMIT ?",
            kindStr, fetchLimit)
    else:
        candidates = s.db.query(MemoryEntry,
            "SELECT * FROM memory_entry ORDER BY access_count DESC LIMIT ?",
            fetchLimit)

    # Score candidates in Nim for fine-grained relevance
    let queryTerms = query.splitWhitespace()

    type Scored = tuple[entry: MemoryEntry, score: float]
    var scored: seq[Scored]

    for e in candidates:
        if filterKind and e.kind != toDbString(kind):
            continue

        var score = 0.0

        # Tag overlap (strongest signal)
        let eTags = e.tags.mapIt(it.toLowerAscii)
        let qTags = tags.mapIt(it.toLowerAscii)
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
        let ageDays = ageSeconds.float / 86400.0
        score += max(0.0, 1.0 - (ageDays / 30.0))

        # Helpfulness boost
        score += e.helpfulness

        scored.add (entry: e, score: score)

    # Sort descending by score
    scored.sort(proc(a, b: Scored): int = cmp(b.score, a.score))

    # Take top N and touch access
    let n = min(limit, scored.len)
    for i in 0 ..< n:
        result.add scored[i].entry
        s.touchAccess(scored[i].entry)

    ic "recall returning", result.len

# ============================================================================
# Bulk operations
# ============================================================================

proc pruneLowValue*(s: MemoryStore, minHelpfulness: float = 0.2, minAccessCount: int = 0): int =
    icb "pruneLowValue()", minHelpfulness, minAccessCount
    let toDelete = s.db.query(MemoryEntry,
        "SELECT * FROM memory_entry WHERE access_count > 0 AND helpfulness < ? AND access_count >= ?",
        minHelpfulness, minAccessCount)

    for e in toDelete:
        s.db.delete(e)

    result = toDelete.len
    if result > 0:
        icy "Pruned", result, "low-value memories"
    ic "Store now has", s.count(), "entries"

# ============================================================================
# Formatting (for context injection)
# ============================================================================

proc formatMemoriesForContext*(memories: seq[MemoryEntry]): string =
    if memories.len == 0: return ""

    var lines: seq[string] = @[]
    lines.add "## Relevant Memories from Past Sessions\n"

    for m in memories:
        let kLabel = m.memoryKind.kindLabel
        let tagStr = if m.tags.len > 0: " [" & m.tags.join(", ") & "]" else: ""
        lines.add &"- **{kLabel}**{tagStr}: {m.content}"

    lines.add ""
    return lines.join("\n")


proc formatMemoriesAsJson*(memories: seq[MemoryEntry]): JsonNode =
    result = newJArray()
    for m in memories:
        result.add(%*{
            "id"      : m.uid
            ,"kind"   : m.kind
            ,"content": m.content
            ,"tags"   : m.tags
        })

# ============================================================================
# Prompts
# ============================================================================

const MemorySystemPrompt* = """
## Memory System

You have access to a persistent memory system via the `memory` tool. Use it to build up useful knowledge across conversations.

### When to STORE memories:
- **Facts**: User preferences, environment details, file paths, project structure, names, conventions
- **Lessons**: Tool call patterns that worked or failed, debugging insights, gotchas discovered
- **Summaries**: Condensed notes about what was accomplished in a session

### When to RECALL memories:
- At the start of a new task, if you think past context would help
- When you encounter something familiar — check if you've seen it before
- When the user references past work or decisions

### Source tags for context:
- `reflection`: End-of-task insight
- `correction`: User corrected you on something
- `tool_failure`: A tool call failed — what went wrong
- `tool_recovery`: A tool call succeeded after a failure — what you did differently
- `user_preference`: User expressed a preference
- `environment`: Something learned about the runtime environment

### Guidelines:
- Do NOT store trivial or obvious information
- Do NOT store exact conversation transcripts
- DO store things that would save time if you encountered the same situation again
- Keep memory content concise — 1-3 sentences max
- Use descriptive tags for easy retrieval later
"""

const ReflectionPrompt* = """
Task completed. Before finishing, reflect on this session:

1. Did you learn any **facts** worth remembering? (user preferences, file paths, project details)
2. Did you discover any **lessons**? (patterns that worked, gotchas, tool quirks)
3. Should you store a brief **summary** of what was accomplished?

If yes to any, use the `memory` tool with command "store" to save them. If nothing is worth storing, that's fine — skip it.
"""

proc toolFailureReflectionPrompt*(toolName: string, errorMsg: string): string =
    &"""
The tool call to `{toolName}` failed with: {errorMsg}

After you resolve this, consider storing a lesson about what went wrong using the `memory` tool:
- command: "store"
- kind: "lesson"
- source: "tool_failure"
- Include: what you tried, why it failed, and what to try instead
"""

proc toolRecoveryReflectionPrompt*(toolName: string): string =
    &"""
You successfully recovered from a previous `{toolName}` failure. Consider storing a lesson about the recovery:
- command: "store"
- kind: "lesson"
- source: "tool_recovery"
- Include: what initially failed, what you changed, and the pattern that worked
"""

# ============================================================================
# Integration hooks (for agent tick loop)
# ============================================================================

type
    ToolFailureTracker * = object
        failedTools   * : HashSet[string]
        failureErrors * : Table[string, string]

proc newToolFailureTracker*(): ToolFailureTracker =
    ToolFailureTracker(
        failedTools   : initHashSet[string]()
        ,failureErrors: initTable[string, string]()
    )

proc recordFailure*(tracker: var ToolFailureTracker, toolName: string, error: string) =
    tracker.failedTools.incl(toolName)
    tracker.failureErrors[toolName] = error

proc checkRecovery*(tracker: var ToolFailureTracker, toolName: string): bool =
    toolName in tracker.failedTools

proc clearRecovery*(tracker: var ToolFailureTracker, toolName: string) =
    tracker.failedTools.excl(toolName)
    tracker.failureErrors.del(toolName)


proc injectMemoryContext*(
    store        : MemoryStore
    ,systemPrompt: string
    ,userMessage : string
    ,maxMemories : int = 5
): string =
    ## Searches memory for top entries and prepends to system prompt.
    ## Returns the augmented system prompt.
    if store.count() == 0:
        icb "No memories found, skipping injection"
        return systemPrompt & "\n\n" & MemorySystemPrompt

    let
        memories    = store.topKMemories(maxMemories)
        memoryBlock = formatMemoriesForContext(memories)

    if memoryBlock.len > 0:
        return systemPrompt & "\n\n" & MemorySystemPrompt & "\n" & memoryBlock

    return systemPrompt & "\n\n" & MemorySystemPrompt


proc buildToolFailureNudge*(toolName: string, errorMsg: string): JsonNode =
    %*{
        "type"   : "message"
        ,"role"  : "developer"
        ,"content": toolFailureReflectionPrompt(toolName, errorMsg)
    }

proc buildToolRecoveryNudge*(toolName: string): JsonNode =
    %*{
        "type"   : "message"
        ,"role"  : "developer"
        ,"content": toolRecoveryReflectionPrompt(toolName)
    }

proc buildReflectionMessages*(): seq[JsonNode] =
    @[%*{
        "type"   : "message"
        ,"role"  : "developer"
        ,"content": ReflectionPrompt
    }]