## memory_store.nim — Persistent memory storage
##
## Manages reading/writing memory.json in the agent's artifacts directory.
## Provides CRUD operations and search functionality.

import std/[
    json
    ,os
    ,strutils
    ,sequtils
    ,algorithm
    ,times
]

import types

type
    MemoryStore   * = ref object
        filepath  * : string              ## Path to memory.json
        entries   * : seq[MemoryEntry]    ## In-memory cache
        dirty     * : bool                ## Needs flush to disk


# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

proc newMemoryStore*(filepath: string): MemoryStore =
    result       = MemoryStore(
        filepath : filepath
        ,entries : @[]
        ,dirty   : false
    )
    if fileExists(filepath):
        let raw = parseJson(readFile(filepath))
        if raw.kind == JArray:
            for item in raw:
                result.entries.add(toMemoryEntry(item))


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

proc flush*(store: MemoryStore) =
    ## Write current entries to disk
    let arr = newJArray()
    for e in store.entries:
        arr.add(%e)
    
    # Ensure parent dir exists
    let dir = store.filepath.parentDir
    if dir.len > 0 and not dirExists(dir):
        createDir(dir)
    
    writeFile(store.filepath, pretty(arr))
    store.dirty = false


proc flushIfDirty*(store: MemoryStore) =
    if store.dirty:
        store.flush()


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------

proc store*(s: MemoryStore, entry: MemoryEntry): MemoryEntry =
    ## Add a new memory entry
    var e = entry
    s.entries.add(e)
    s.dirty = true
    s.flush()
    return e

proc store*(
    s        : MemoryStore
    ,kind    : MemoryKind
    ,content : string
    ,tags    : seq[string] = @[]
    ,source  : string = "reflection"
): MemoryEntry =
    let entry = newMemoryEntry(kind = kind, content = content, tags = tags, source = source)
    return s.store(entry)


proc recall*(
    s          : MemoryStore
    ,query     : string = ""
    ,tags      : seq[string] = @[]
    ,kind      : MemoryKind = mkFact  
    ,filterKind: bool = false
    ,limit     : int = 5
): seq[MemoryEntry] =
    ## Search memories by query terms, tags, and optionally kind
    var candidates = s.entries
    
    # Filter by kind if requested
    if filterKind:
        candidates = candidates.filterIt(it.kind == kind)
    
    # Score and sort
    let queryTerms = query.splitWhitespace()
    candidates.sortByRelevance(tags, queryTerms)
    
    # Take top N and mark as accessed
    let n = min(limit, candidates.len)
    result = candidates[0 ..< n]
    
    # Update access metadata on the actual stored entries
    for r in result:
        for i, e in s.entries:
            if e.id == r.id:
                s.entries[i].touchAccess()
                s.dirty = true
                break
    
    s.flushIfDirty()


proc update*(s: MemoryStore, memoryId: string, helpfulness: float = -1.0, newTags: seq[string] = @[]): bool =
    ## Update an existing memory's helpfulness score and/or tags
    for i, e in s.entries:
        if e.id == memoryId:
            if helpfulness >= 0.0:
                s.entries[i].updateHelpfulness(helpfulness)
            if newTags.len > 0:
                s.entries[i].tags = newTags
            s.dirty = true
            s.flush()
            return true
    return false


proc delete*(s: MemoryStore, memoryId: string): bool =
    for i, e in s.entries:
        if e.id == memoryId:
            s.entries.delete(i)
            s.dirty = true
            s.flush()
            return true
    return false


proc list*(s: MemoryStore, kind: MemoryKind = mkFact, filterKind: bool = false, limit: int = 20): seq[MemoryEntry] =
    var candidates = s.entries
    if filterKind:
        candidates = candidates.filterIt(it.kind == kind)
    
    # Sort by recency
    candidates.sort(proc(a, b: MemoryEntry): int = cmp(b.accessedAt, a.accessedAt))
    
    let n = min(limit, candidates.len)
    return candidates[0 ..< n]


# ---------------------------------------------------------------------------
# Bulk operations (for maintenance/consolidation)
# ---------------------------------------------------------------------------

proc pruneLowValue*(s: MemoryStore, minHelpfulness: float = 0.2, minAccessCount: int = 0): int =
    ## Remove memories below helpfulness threshold that have been accessed at least once
    ## Returns count of pruned entries
    let before = s.entries.len
    s.entries = s.entries.filterIt(
        it.accessCount == 0 or  # never tested, keep
        it.helpfulness >= minHelpfulness or 
        it.accessCount < minAccessCount
    )
    result = before - s.entries.len
    if result > 0:
        s.dirty = true
        s.flush()


proc count*(s: MemoryStore): int = s.entries.len