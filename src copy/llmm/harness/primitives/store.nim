## store.nim — Unified SQLite storage for agent artifacts
##
## Single database backing: memories, chat history, events, requests, responses, sessions.
## Replaces all JSONL / JSON file persistence with structured SQLite tables.
##
## Usage:
##   let store = newAgentStore("path/to/agent.db")
##   store.insertChatEntry(...)
##   store.insertEvent(...)
##   let ms = store.memoryStore  # access the MemoryStore wrapper

import std/[
json
,times
,strutils
,sequtils
,oids
,strformat
,options
]

import debby/sqlite
import ic
import ../../debby_utils

# ============================================================================
# Table types
# ============================================================================

type
    SessionRow      * = ref object
        id          * : int           ## debby auto-increment PK
        sessionId   * : string        ## OID-based session identifier
        name        * : string        ## Human-readable session name
        createdAt   * : string        ## ISO datetime string
        lastActiveAt* : string        ## ISO datetime string (updated on each message)
        metadataJson* : string        ## JSON blob for arbitrary metadata
        archived    * : bool          ## Soft-delete / archive flag

    ChatHistoryRow  * = ref object
        id          * : int           ## debby auto-increment PK
        sessionId   * : string        ## FK -> SessionRow.sessionId (defaults to "default")
        ts          * : string        ## ISO datetime string
        role        * : string        ## "user" | "assistant" | "error"
        content     * : string        ## message text (FTS candidate)
        toolCalls   * : string        ## JSON-encoded seq[JsonNode]
        toolResults * : string        ## JSON-encoded seq[JsonNode]
        tokensUsed  * : int
        elapsedMs   * : int64
        model       * : string
        responseId  * : string
        done        * : bool

    AgentEventRow * = ref object
        id        * : int             ## debby auto-increment PK
        ts * : string          ## ISO datetime string
        kind      * : string          ## AgentEventKind as string
        payload   * : string          ## Full event serialized as JSON

    ApiRequestRow * = ref object
        id        * : int             ## debby auto-increment PK
        ts * : string          ## ISO datetime string
        payload   * : string          ## Full request options as JSON

    ApiResponseRow * = ref object
        id        * : int             ## debby auto-increment PK
        ts * : string          ## ISO datetime string
        payload   * : string          ## Full response as JSON

# ============================================================================
# AgentStore — unified handle
# ============================================================================

type
    AgentStore * = ref object
        db     * : Db
        dbPath * : string

# ============================================================================
# Initialization
# ============================================================================


proc newAgentStore*(dbPath: string): AgentStore =
    icb "=== Initializing AgentStore (SQLite) ===", dbPath
    result     = AgentStore(
        dbPath : dbPath
        ,db    : openDatabase(dbPath)
    )

    # Create all tables
    result.db.initTable SessionRow
    result.db.initTable ChatHistoryRow
    result.db.initTable AgentEventRow
    result.db.initTable ApiRequestRow
    result.db.initTable ApiResponseRow

    # ---------------------------------------------------------------------------
    # Schema migration: add session_id column to chat_history_row if missing
    # ---------------------------------------------------------------------------
    block migrateChatHistorySessionId:
        var hasSessionId = false
        for row in result.db.query("PRAGMA table_info(chat_history_row);"):
            if row.len >= 2 and row[1] == "session_id":
                hasSessionId = true
                break
        if not hasSessionId:
            icy "Migrating chat_history_row: adding session_id column"
            discard result.db.query(
                "ALTER TABLE chat_history_row ADD COLUMN session_id TEXT NOT NULL DEFAULT 'default';"
            )

    # Indexes for sessions
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_session_row_session_id
        ON session_row (session_id);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_session_row_last_active
        ON session_row (last_active_at);
    """

    # Indexes for chat history
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_chat_history_role
        ON chat_history_row (role);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_chat_history_ts
        ON chat_history_row (ts);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_chat_history_model
        ON chat_history_row (model);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_chat_history_session_id
        ON chat_history_row (session_id);
    """

    # Indexes for events
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_agent_event_kind
        ON agent_event_row (kind);
    """
    discard result.db.query """
        CREATE INDEX IF NOT EXISTS idx_agent_event_ts
        ON agent_event_row (ts);
    """

    ic "AgentStore ready"

# ============================================================================
# Sessions
# ============================================================================

proc createSession*(s: AgentStore, sessionId: string, name: string, metadata: JsonNode = %*{}): SessionRow =
    ## Insert a new session row into the database.
    icb "createSession", sessionId, name
    let nowStr = $now().utc
    var row = SessionRow(
        sessionId    : sessionId
        ,name        : name
        ,createdAt   : nowStr
        ,lastActiveAt: nowStr
        ,metadataJson: $metadata
        ,archived    : false
    )
    s.db.insert(row)
    ic "Session created", row.id, sessionId, name
    return row

proc getSession*(s: AgentStore, sessionId: string): Option[SessionRow] =
    ## Find a session by its sessionId.
    let results = s.db.filter(SessionRow, it.sessionId == sessionId)
    if results.len > 0: some(results[0]) else: none(SessionRow)

proc getSessionByName*(s: AgentStore, name: string): Option[SessionRow] =
    ## Find a session by its human-readable name (case-insensitive).
    let rows = s.db.query(SessionRow,
        "SELECT * FROM session_row WHERE LOWER(name) = LOWER(?) AND archived = 0 LIMIT 1;",
        name)
    if rows.len > 0: some(rows[0]) else: none(SessionRow)

proc findSession*(s: AgentStore, idOrName: string): Option[SessionRow] =
    ## Find a session by sessionId first, then fall back to name lookup.
    let byId = s.getSession(idOrName)
    if byId.isSome: return byId
    return s.getSessionByName(idOrName)

proc listSessions*(s: AgentStore, includeArchived: bool = false, limit: int = 50): seq[SessionRow] =
    ## List sessions ordered by most recently active.
    if includeArchived:
        s.db.query(SessionRow,
            "SELECT * FROM session_row ORDER BY last_active_at DESC LIMIT ?;",
            limit)
    else:
        s.db.query(SessionRow,
            "SELECT * FROM session_row WHERE archived = 0 ORDER BY last_active_at DESC LIMIT ?;",
            limit)

proc renameSession*(s: AgentStore, sessionId: string, newName: string): bool =
    ## Rename a session. Returns false if not found.
    icb "renameSession", sessionId, newName
    let opt = s.getSession(sessionId)
    if opt.isNone:
        icr "renameSession: not found", sessionId
        return false
    var row = opt.get
    row.name = newName
    s.db.update(row)
    ic "Session renamed", sessionId, newName
    return true

proc archiveSession*(s: AgentStore, sessionId: string): bool =
    ## Soft-delete a session by setting archived = true. Returns false if not found.
    icb "archiveSession", sessionId
    let opt = s.getSession(sessionId)
    if opt.isNone:
        icr "archiveSession: not found", sessionId
        return false
    var row = opt.get
    row.archived = true
    s.db.update(row)
    ic "Session archived", sessionId
    return true

proc deleteSession*(s: AgentStore, sessionId: string, deleteMessages: bool = false): bool =
    ## Delete a session. Optionally delete all associated chat messages.
    icb "deleteSession", sessionId, deleteMessages
    let opt = s.getSession(sessionId)
    if opt.isNone:
        icr "deleteSession: not found", sessionId
        return false
    if deleteMessages:
        discard s.db.query(
            "DELETE FROM chat_history_row WHERE session_id = ?;",
            sessionId)
        ic "Deleted chat messages for session", sessionId
    s.db.delete(opt.get)
    ic "Session deleted", sessionId
    return true

proc touchSession*(s: AgentStore, sessionId: string) =
    ## Update the lastActiveAt timestamp for a session.
    let opt = s.getSession(sessionId)
    if opt.isSome:
        var row = opt.get
        row.lastActiveAt = $now().utc
        s.db.update(row)

proc sessionMessageCount*(s: AgentStore, sessionId: string): int =
    ## Count messages in a specific session.
    s.db.query(
        "SELECT count(*) as c FROM chat_history_row WHERE session_id = ?;",
        sessionId
    )[0][0].parseInt

proc ensureSessionExists*(s: AgentStore, sessionId: string, name: string): SessionRow =
    ## Get or create a session row. Used during agent init to ensure
    ## the active session is tracked in the database.
    let existing = s.getSession(sessionId)
    if existing.isSome:
        return existing.get
    return s.createSession(sessionId, name)

# ============================================================================
# Chat History
# ============================================================================

proc insertChatEntry*(s: AgentStore
    ,role        : string
    ,content     : string
    ,sessionId   : string = "default"
    ,toolCalls   : seq[JsonNode] = @[]
    ,toolResults : seq[JsonNode] = @[]
    ,tokensUsed  : int = 0
    ,elapsed     : Duration = default(Duration)
    ,model       : string = ""
    ,responseId  : string = ""
    ,done        : bool = true
) =
    ic "insertChatEntry", role, content.len, sessionId
    var row = ChatHistoryRow(
        sessionId   : sessionId
        ,ts         : $now().utc
        ,role       : role
        ,content    : content
        ,toolCalls  : $(%toolCalls)
        ,toolResults: $(%toolResults)
        ,tokensUsed : tokensUsed
        ,elapsedMs  : elapsed.inMilliseconds
        ,model      : model
        ,responseId : responseId
        ,done       : done
    )
    s.db.insert(row)

    # Touch session lastActiveAt
    s.touchSession(sessionId)

proc getChatHistory*(s: AgentStore, limit: int = 50): seq[ChatHistoryRow] =
    ## Get chat history across ALL sessions (backward compatible).
    s.db.query(ChatHistoryRow,
        "SELECT * FROM chat_history_row ORDER BY id DESC LIMIT ?",
        limit)

proc getSessionChatHistory*(s: AgentStore, sessionId: string, limit: int = 50): seq[ChatHistoryRow] =
    ## Get chat history for a specific session.
    s.db.query(ChatHistoryRow,
        "SELECT * FROM chat_history_row WHERE session_id = ? ORDER BY id DESC LIMIT ?",
        sessionId, limit)

proc getChatHistoryByRole*(s: AgentStore, role: string, limit: int = 50): seq[ChatHistoryRow] =
    s.db.query(ChatHistoryRow,
        "SELECT * FROM chat_history_row WHERE role = ? ORDER BY id DESC LIMIT ?",
        role, limit)

proc getSessionChatHistoryByRole*(s: AgentStore, sessionId: string, role: string, limit: int = 50): seq[ChatHistoryRow] =
    s.db.query(ChatHistoryRow,
        "SELECT * FROM chat_history_row WHERE session_id = ? AND role = ? ORDER BY id DESC LIMIT ?",
        sessionId, role, limit)

# ============================================================================
# Agent Events
# ============================================================================

proc insertEvent*(s: AgentStore, kind: string, payload: JsonNode) =
    ic "insertEvent", kind
    var row = AgentEventRow(
        ts : $now().utc
        ,kind     : kind
        ,payload  : $payload
    )
    s.db.insert(row)

proc getEvents*(s: AgentStore, limit: int = 100): seq[AgentEventRow] =
    s.db.query(AgentEventRow,
        "SELECT * FROM agent_event_row ORDER BY id DESC LIMIT ?",
        limit)

proc getEventsByKind*(s: AgentStore, kind: string, limit: int = 100): seq[AgentEventRow] =
    s.db.query(AgentEventRow,
        "SELECT * FROM agent_event_row WHERE kind = ? ORDER BY id DESC LIMIT ?",
        kind, limit)

# ============================================================================
# API Requests
# ============================================================================

proc insertRequest*(s: AgentStore, payload: JsonNode) =
    ic "insertRequest"
    var row = ApiRequestRow(
        ts : $now().utc
        ,payload  : $payload
    )
    s.db.insert(row)

proc getRequests*(s: AgentStore, limit: int = 50): seq[ApiRequestRow] =
    s.db.query(ApiRequestRow,
        "SELECT * FROM api_request_row ORDER BY id DESC LIMIT ?",
        limit)

# ============================================================================
# API Responses
# ============================================================================

proc insertResponse*(s: AgentStore, payload: JsonNode) =
    ic "insertResponse"
    var row       = ApiResponseRow(
        ts        : $now().utc
        ,payload  : $payload
    )
    s.db.insert(row)

proc getResponses*(s: AgentStore, limit: int = 50): seq[ApiResponseRow] =
    s.db.query(ApiResponseRow,
        "SELECT * FROM api_response_row ORDER BY id DESC LIMIT ?",
        limit)