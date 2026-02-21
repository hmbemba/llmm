## store.nim — Unified SQLite storage for agent artifacts
##
## Single database backing: memories, chat history, events, requests, responses.
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
    ChatHistoryRow  * = ref object
        id          * : int           ## debby auto-increment PK
        ts   * : string        ## ISO datetime string
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
    result.db.initTable ChatHistoryRow
    result.db.initTable AgentEventRow
    result.db.initTable ApiRequestRow
    result.db.initTable ApiResponseRow

    # Indexes for chat history (FTS-friendly later)
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
# Chat History
# ============================================================================

proc insertChatEntry*(s: AgentStore
    ,role        : string
    ,content     : string
    ,toolCalls   : seq[JsonNode] = @[]
    ,toolResults : seq[JsonNode] = @[]
    ,tokensUsed  : int = 0
    ,elapsed     : Duration = default(Duration)
    ,model       : string = ""
    ,responseId  : string = ""
    ,done        : bool = true
) =
    ic "insertChatEntry", role, content.len
    var row = ChatHistoryRow(
        ts   : $now().utc
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

proc getChatHistory*(s: AgentStore, limit: int = 50): seq[ChatHistoryRow] =
    s.db.query(ChatHistoryRow,
        "SELECT * FROM chat_history_row ORDER BY id DESC LIMIT ?",
        limit)

proc getChatHistoryByRole*(s: AgentStore, role: string, limit: int = 50): seq[ChatHistoryRow] =
    s.db.query(ChatHistoryRow,
        "SELECT * FROM chat_history_row WHERE role = ? ORDER BY id DESC LIMIT ?",
        role, limit)

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