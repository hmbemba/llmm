## knowledge.nim — Persistent knowledge base backed by SQLite + sqlite-vector
##
## Semantic search over ingested documents (PDFs, text, markdown, code).
## Uses sqlite-vector extension for approximate nearest-neighbor search
## and stores embeddings as float32 BLOBs alongside chunk content.
##
## Designed to live alongside MemoryStore in the same agent.db.
## Memory = agent's self-generated learnings (small, keyword-based)
## Knowledge = external corpus (large, embedding-based semantic search)
##
## NOTE: KnowledgeStore uses raw sqlite3 (via db.handle or a separate
## connection) for vector operations, since debby doesn't know about the
## sqlite-vector extension functions. Regular CRUD uses debby.
##
## Usage:
##   let ks = newKnowledgeStore(agentStore.db, embedder, "./vector.dll")
##   let docId = await ks.ingestFile("manual.md")
##   let results = await ks.search("how to configure networking", k = 5)

import std/[
    json
    ,times
    ,strutils
    ,sequtils
    ,strformat
    ,options
    ,os
    ,algorithm
    ,asyncdispatch
]

import debby/sqlite
import db_connector/sqlite3 as csqlite3   # <-- Nim 2.x: wrapper lives in db_connector, not std/wrappers :contentReference[oaicite:5]{index=5}
import ic
import ../../../debby_utils
import ../../../embeddings

# ============================================================================
# Types
# ============================================================================

type
    KnowledgeDocument* = ref object
        id*           : int            ## debby auto-increment PK
        sourceType*   : string         ## "pdf", "text", "markdown", "url"
        sourcePath*   : string         ## absolute path or URL
        title*        : string
        metadataJson* : string         ## JSON blob for extra info
        chunkCount*   : int            ## how many chunks were generated
        createdAt*    : int64          ## unix timestamp

    KnowledgeChunk* = ref object
        id*             : int          ## debby auto-increment PK
        documentId*     : int          ## FK -> KnowledgeDocument
        pageNo*         : int          ## page number (0 if N/A)
        chunkIndex*     : int          ## index within page
        content*        : string       ## the actual text
        metadataJson*   : string       ## JSON blob
        embedding*      : Bytes        ## float32 LE bytes stored as BLOB (Debby Bytes -> BLOB)
        embeddingDim*   : int
        embeddingModel* : string
        createdAt*      : int64        ## unix timestamp

    SearchResult* = object
        chunkId*    : int
        documentId* : int
        pageNo*     : int
        chunkIndex* : int
        content*    : string
        distance*   : float
        title*      : string
        sourceType* : string
        sourcePath* : string

    ChunkerKind* = enum
        ckCharBased     ## simple character-based with overlap (POC default)
        ckLineBased     ## split on newlines, drop blanks, merge up to max
        ckParagraph     ## split on double newlines

    DuplicateIngestPolicy* = enum
        dipSkip         ## if source_path exists, do nothing
        dipReplace      ## delete existing doc (latest) and re-ingest
        dipVersion      ## keep existing and insert a new doc version

    KnowledgeConfig* = object
        maxChunkChars*         = 1200
        chunkOverlap*          = 150
        chunkerKind*           = ckCharBased
        embeddingBatch*        = 64
        embeddingModel*        = "text-embedding-3-small"
        embeddingDim*          = 1536
        vectorExtPath*         : string
        duplicateIngestPolicy* = dipSkip
        searchOversample*      = 1      ## candidates = k * max(1, oversample); helpful once you add WHERE filters

    KnowledgeStore* = ref object
        db*           : Db
        embedder*     : EmbeddingProvider
        vectorExtPath*: string
        vectorLoaded* : bool
        config*       : KnowledgeConfig



# ============================================================================
# SQLite C API (minimal) for extension loading
#   - We declare what we need directly so we aren't blocked by wrapper versions.
#   - Uses sqlite3_db_config(ENABLE_LOAD_EXTENSION) (recommended) so SQL
#     load_extension() remains disabled. See SQLite docs.
# ============================================================================

when defined(windows):
  when defined(cpu64):
    const SqliteDynLib = "sqlite3_64.dll"
  else:
    const SqliteDynLib = "sqlite3_32.dll"
elif defined(macosx):
  const SqliteDynLib = "libsqlite3(|.0).dylib"
else:
  const SqliteDynLib = "libsqlite3.so(|.0)"


{.pragma: sqliteDyn, cdecl, dynlib: SqliteDynLib.}

type PSqlite3* = pointer

const
  SQLITE_OK* = 0
  SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION* = 1005  # :contentReference[oaicite:3]{index=3}

proc sqlite3_db_config*(db: PSqlite3; op: cint): cint
  {.sqliteDyn, importc: "sqlite3_db_config", varargs.}

proc sqlite3_load_extension*(db: PSqlite3; zFile, zProc: cstring; pzErrMsg: ptr cstring): cint
  {.sqliteDyn, importc: "sqlite3_load_extension".}

proc sqlite3_errmsg*(db: PSqlite3): cstring
  {.sqliteDyn, importc: "sqlite3_errmsg".}

proc sqlite3_free*(z: cstring)
  {.sqliteDyn, importc: "sqlite3_free".}


proc defaultKnowledgeConfig*(): KnowledgeConfig =
    result = KnowledgeConfig(
        maxChunkChars         : 1200
        ,chunkOverlap         : 150
        ,chunkerKind          : ckCharBased
        ,embeddingBatch       : 64
        ,embeddingModel       : "text-embedding-3-small"
        ,embeddingDim         : 1536
        ,vectorExtPath        : ""
        ,duplicateIngestPolicy: dipSkip
        ,searchOversample     : 1
    )


proc getColumnDeclType(db: Db, tableName, colName: string): string =
    ## PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
    for row in db.query("PRAGMA table_info(" & tableName & ");"):
        if row.len >= 3 and row[1] == colName:
            return row[2].strip().toUpperAscii()
    return ""

proc ensureEmbeddingIsBlob(ks: KnowledgeStore) =
    ## sqlite-vector requires the embedding column be declared as BLOB.
    let decl = getColumnDeclType(ks.db, "knowledge_chunk", "embedding")
    if decl == "BLOB":
        return

    icy "Schema mismatch: knowledge_chunk.embedding must be BLOB for sqlite-vector", "got", decl

    let n = ks.db.query("SELECT count(*) FROM knowledge_chunk;")[0][0].parseInt
    if n == 0:
        # Simple path: no data to preserve
        icy "No rows in knowledge_chunk; dropping + recreating table with BLOB embedding"
        discard ks.db.query("DROP TABLE IF EXISTS knowledge_chunk;")
        ks.db.initTable KnowledgeChunk
        return

    # Data-preserving migration
    icy "Migrating knowledge_chunk to BLOB embedding (copy + rename)"
    ks.db.withTransaction:
        discard ks.db.query("ALTER TABLE knowledge_chunk RENAME TO knowledge_chunk_old;")

        # Create the new table with the updated schema (Bytes -> BLOB) :contentReference[oaicite:2]{index=2}
        discard ks.db.query(ks.db.createTableStatement(KnowledgeChunk))

        discard ks.db.query("""
            INSERT INTO knowledge_chunk
              (id, document_id, page_no, chunk_index, content, metadata_json,
               embedding, embedding_dim, embedding_model, created_at)
            SELECT
              id, document_id, page_no, chunk_index, content, metadata_json,
              CAST(embedding AS BLOB), embedding_dim, embedding_model, created_at
            FROM knowledge_chunk_old;
        """)

        discard ks.db.query("DROP TABLE knowledge_chunk_old;")


# ============================================================================
# Chunking
# ============================================================================

proc chunkTextChar*(text: string, maxChars: int = 1200, overlap: int = 150): seq[string] =
    ## Simple character-based chunker with overlap.
    if maxChars <= 0:
        return @[text]

    let
        n        = text.len
        stepBack = if maxChars <= 1: 0 else: min(overlap, maxChars - 1)

    var i = 0
    while i < n:
        let j = min(n, i + maxChars)
        let chunk = text[i ..< j].strip()
        if chunk.len > 0:
            result.add chunk
        if j >= n:
            break
        i = j - stepBack

proc chunkTextLine*(text: string, maxChars: int = 1200, overlap: int = 150): seq[string] =
    ## Line-based chunker:
    ## - split on newlines
    ## - drop blank lines
    ## - merge lines up to maxChars
    ## - carry a char-overlap into next chunk (optional)
    if maxChars <= 0:
        return @[text]

    let lines = text.splitLines()

    var current = ""

    template pushChunk(chunk: string) =
        let c = chunk.strip()
        if c.len > 0:
            result.add c

    for rawLine in lines:
        let line = rawLine.strip()
        if line.len == 0:
            continue

        # If a single line is too large, fall back to char chunking for that line.
        if line.len > maxChars:
            if current.strip().len > 0:
                pushChunk(current)
                current = ""

            for piece in chunkTextChar(line, maxChars, overlap):
                if piece.strip().len > 0:
                    result.add piece
            continue

        if current.len == 0:
            current = line
            continue

        let candidateLen = current.len + 1 + line.len
        if candidateLen <= maxChars:
            current.add "\n"
            current.add line
        else:
            let flushed = current.strip()
            pushChunk(flushed)

            # Carry overlap forward
            var carry = ""
            if overlap > 0 and flushed.len > 0:
                let start = max(0, flushed.len - min(overlap, maxChars - 1))
                carry = flushed[start .. ^1]

            if carry.len > 0 and carry.len + 1 + line.len <= maxChars:
                current = carry & "\n" & line
            else:
                current = line

    if current.strip().len > 0:
        pushChunk(current)

proc chunkTextParagraph*(text: string, maxChars: int = 1200): seq[string] =
    ## Split on double newlines, merge small paragraphs up to maxChars.
    let paragraphs = text.split("\n\n")
    var current = ""
    for p in paragraphs:
        let trimmed = p.strip()
        if trimmed.len == 0:
            continue

        if current.len > 0 and current.len + trimmed.len + 2 > maxChars:
            result.add current.strip()
            current = trimmed
        else:
            if current.len > 0:
                current.add "\n\n"
            current.add trimmed

    if current.strip().len > 0:
        result.add current.strip()

proc chunkText*(text: string, cfg: KnowledgeConfig): seq[string] =
    case cfg.chunkerKind
    of ckCharBased:
        chunkTextChar(text, cfg.maxChunkChars, cfg.chunkOverlap)
    of ckLineBased:
        chunkTextLine(text, cfg.maxChunkChars, cfg.chunkOverlap)
    of ckParagraph:
        chunkTextParagraph(text, cfg.maxChunkChars)

# ============================================================================
# Text extraction (text/md direct read)
# ============================================================================

type
    ExtractedPage* = tuple[pageNo: int, text: string]

proc normalizeWhitespace*(s: string): string =
    ## Clean up extracted text: collapse spaces, limit blank lines.
    result = s.replace("\x00", " ")

    # Collapse horizontal whitespace
    var prev = false
    var outt = newStringOfCap(result.len)
    for c in result:
        if c in {' ', '\t'}:
            if not prev:
                outt.add ' '
            prev = true
        else:
            prev = false
            outt.add c
    result = outt

    # Collapse 3+ newlines into 2
    while "\n\n\n" in result:
        result = result.replace("\n\n\n", "\n\n")

    result = result.strip()

proc extractTextFromFile*(path: string): seq[ExtractedPage] =
    ## Extract text from a file.
    ## For PDFs, use ingestPdf (not implemented here).
    let ext = path.splitFile.ext.toLowerAscii
    case ext
    of ".txt", ".md", ".nim", ".py", ".js", ".ts", ".html", ".css", ".json",
       ".yaml", ".yml", ".toml", ".cfg", ".ini", ".sh", ".bat", ".ps1",
       ".c", ".cpp", ".h", ".hpp", ".rs", ".go", ".java", ".kt", ".rb",
       ".lua", ".zig", ".odin":
        let content = readFile(path)
        let cleaned = normalizeWhitespace(content)
        if cleaned.len > 0:
            result.add (pageNo: 1, text: cleaned)
    else:
        raise newException(ValueError,
            &"Unsupported file type: {ext}. Use ingestPdf for PDFs, or extract text first.")

# ============================================================================
# Initialization helpers (sqlite handle + extension loading)
# ============================================================================

# ============================================================================
# Raw sqlite3 handle access (Debby)
#   Debby.Db is `distinct pointer` -> sqlite3*.
# ============================================================================

proc rawSqliteHandle*(ks: KnowledgeStore): pointer =
  ## Returns sqlite3* as `pointer`.
  ## Debby: Db = distinct pointer, so the Db itself *is* the sqlite3 handle. :contentReference[oaicite:2]{index=2}
  when compiles(cast[pointer](ks.db)):
    return cast[pointer](ks.db)
  elif compiles(ks.db.handle):
    # In case you ever swap Db implementations later
    return cast[pointer](ks.db.handle)
  else:
    raise newException(ValueError,
      "Can't get raw sqlite3 handle from Db. For Debby sqlite, Db is a distinct pointer (sqlite3*).")



proc loadVectorExtension(ks: KnowledgeStore) =
  if ks.vectorExtPath.len == 0:
    icr "No vector extension path configured — semantic search disabled"
    return

  if not fileExists(ks.vectorExtPath):
    icr "Vector extension not found", ks.vectorExtPath
    return

  icb "Loading sqlite-vector extension", ks.vectorExtPath, fileExists(ks.vectorExtPath)

  try:
    let h = cast[PSqlite3](ks.rawSqliteHandle())

    # Enable extension loading for the C-API only (recommended). :contentReference[oaicite:4]{index=4}
    var prev: cint = 0
    let rcEnable = sqlite3_db_config(
      h,
      SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION.cint,
      1.cint,
      addr prev
    )
    if rcEnable != SQLITE_OK:
      icr "sqlite3_db_config(ENABLE_LOAD_EXTENSION,1) failed", rcEnable, $sqlite3_errmsg(h)
      ks.vectorLoaded = false
      return

    # Always turn it back off right after loading.
    defer:
      var ignored: cint = 0
      discard sqlite3_db_config(
        h,
        SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION.cint,
        0.cint,
        addr ignored
      )

    var errMsg: cstring = nil
    let rcLoad = sqlite3_load_extension(h, ks.vectorExtPath.cstring, nil, addr errMsg)

    if rcLoad != SQLITE_OK:
      let msg =
        if errMsg != nil: $errMsg
        else: $sqlite3_errmsg(h)
      if errMsg != nil: sqlite3_free(errMsg)
      icr "Failed to load sqlite-vector", rcLoad, msg
      ks.vectorLoaded = false
      return

    if errMsg != nil: sqlite3_free(errMsg)

    ks.vectorLoaded = true
    ic "sqlite-vector extension loaded successfully"

  except CatchableError as e:
    icr "Failed to load sqlite-vector (exception)", e.msg
    ks.vectorLoaded = false


proc initKnowledgeTables(ks: KnowledgeStore) =
    icb "Initializing knowledge tables"
    ks.db.initTable KnowledgeDocument
    ks.db.initTable KnowledgeChunk

    ks.ensureEmbeddingIsBlob()   # <-- add this


    discard ks.db.query """
        CREATE INDEX IF NOT EXISTS idx_knowledge_chunk_doc
        ON knowledge_chunk (document_id);
    """
    discard ks.db.query """
        CREATE INDEX IF NOT EXISTS idx_knowledge_chunk_model
        ON knowledge_chunk (embedding_model, embedding_dim);
    """
    discard ks.db.query """
        CREATE INDEX IF NOT EXISTS idx_knowledge_document_source
        ON knowledge_document (source_type, source_path);
    """

proc initVectorIndex*(ks: KnowledgeStore) =
    ## Call vector_init to register the embedding column for vector search.
    if not ks.vectorLoaded:
        icy "Vector extension not loaded, skipping vector_init"
        return

    let opts = &"type=FLOAT32,dimension={ks.embedder.dim}"
    icb "Calling vector_init", opts

    try:
        discard ks.db.query(
            "SELECT vector_init('knowledge_chunk', 'embedding', ?);",
            opts
        )
        ic "vector_init succeeded"
    except CatchableError as e:
        if "already" in e.msg.toLowerAscii:
            ic "vector_init: already initialized (OK)"
        else:
            icr "vector_init failed", e.msg
            ks.vectorLoaded = false

proc newKnowledgeStore*(
    db            : Db
    ,embedder     : EmbeddingProvider
    ,vectorExtPath: string = ""
    ,config       : KnowledgeConfig = defaultKnowledgeConfig()
): KnowledgeStore =
    icb "=== Initializing KnowledgeStore ==="

    var cfg = config
    if cfg.embeddingDim != embedder.dim:
        icy "KnowledgeConfig.embeddingDim != embedder.dim; overriding",
            cfg.embeddingDim, "->", embedder.dim
        cfg.embeddingDim = embedder.dim

    result = KnowledgeStore(
        db            : db
        ,embedder     : embedder
        ,vectorExtPath: vectorExtPath
        ,vectorLoaded : false
        ,config       : cfg
    )

    result.initKnowledgeTables()
    result.loadVectorExtension()
    if result.vectorLoaded:
        result.initVectorIndex()

    let docCount   = result.db.query("SELECT count(*) as c FROM knowledge_document")[0][0].parseInt
    let chunkCount = result.db.query("SELECT count(*) as c FROM knowledge_chunk")[0][0].parseInt
    ic "KnowledgeStore ready", docCount, "documents", chunkCount, "chunks"

# ============================================================================
# Document management
# ============================================================================

proc insertDocument*(
    ks         : KnowledgeStore
    ,sourceType: string
    ,sourcePath: string
    ,title     : string
    ,metadata  : JsonNode = %*{}
): int =
    var doc = KnowledgeDocument(
        sourceType   : sourceType
        ,sourcePath  : sourcePath
        ,title       : title
        ,metadataJson: $metadata
        ,chunkCount  : 0
        ,createdAt   : epochTime().int64
    )
    ks.db.insert(doc)
    ic "Inserted document", doc.id, title
    return doc.id

proc getDocument*(ks: KnowledgeStore, id: int): Option[KnowledgeDocument] =
    let results = ks.db.filter(KnowledgeDocument, it.id == id)
    if results.len > 0: some(results[0]) else: none(KnowledgeDocument)

proc listDocuments*(ks: KnowledgeStore, limit: int = 50): seq[KnowledgeDocument] =
    ks.db.query(
        KnowledgeDocument
        ,"SELECT * FROM knowledge_document ORDER BY created_at DESC LIMIT ?"
        ,limit
    )

proc deleteDocument*(ks: KnowledgeStore, docId: int): bool =
    icb "deleteDocument", docId
    let doc = ks.getDocument(docId)
    if doc.isNone:
        icr "Document not found", docId
        return false

    discard ks.db.query(
        "DELETE FROM knowledge_chunk WHERE document_id = ?;"
        ,docId
    )

    ks.db.delete(doc.get)
    ic "Deleted document and chunks", docId
    return true

proc documentCount*(ks: KnowledgeStore): int =
    ks.db.query("SELECT count(*) as c FROM knowledge_document")[0][0].parseInt

proc chunkCount*(ks: KnowledgeStore): int =
    ks.db.query("SELECT count(*) as c FROM knowledge_chunk")[0][0].parseInt

proc chunkCountForDoc*(ks: KnowledgeStore, docId: int): int =
    ks.db.query(
        "SELECT count(*) as c FROM knowledge_chunk WHERE document_id = ?"
        ,docId
    )[0][0].parseInt

proc latestDocumentIdBySourcePath*(ks: KnowledgeStore, sourcePath: string): int =
    let rows = ks.db.query(
        "SELECT id FROM knowledge_document WHERE source_path = ? ORDER BY created_at DESC LIMIT 1;"
        ,sourcePath
    )
    if rows.len == 0: return 0
    return rows[0][0].parseInt

proc documentCountBySourcePath*(ks: KnowledgeStore, sourcePath: string): int =
    ks.db.query(
        "SELECT count(*) as c FROM knowledge_document WHERE source_path = ?;"
        ,sourcePath
    )[0][0].parseInt

# ============================================================================
# Ingestion
# ============================================================================

proc maybeQuantize*(ks: KnowledgeStore) =
    ## Simple-but-slow: quantize after each ingest so searches work immediately.
    if not ks.vectorLoaded:
        return

    try:
        discard ks.db.query("SELECT vector_quantize('knowledge_chunk', 'embedding');")
        discard ks.db.query("SELECT vector_quantize_preload('knowledge_chunk', 'embedding');")
    except CatchableError as e:
        icr "vector_quantize/preload failed", e.msg

proc ingestChunks*(
    ks       : KnowledgeStore
    ,docId   : int
    ,pages   : seq[ExtractedPage]
): Future[int] {.async.} =
    icb "ingestChunks", docId, pages.len, "pages"

    var allChunks: seq[string]
    var chunkMeta: seq[tuple[pageNo: int, idx: int]]

    for (pageNo, text) in pages:
        let chunks = chunkText(text, ks.config)
        for ci, ch in chunks:
            allChunks.add ch
            chunkMeta.add (pageNo: pageNo, idx: ci)

    if allChunks.len == 0:
        icy "No chunks extracted"
        return 0

    var total = 0
    let batchSize = max(1, ks.config.embeddingBatch)

    for i in countup(0, allChunks.high, batchSize):
        let batchEnd   = min(i + batchSize - 1, allChunks.high)
        let batchTexts = allChunks[i .. batchEnd]

        icb "Embedding batch", i, "..", batchEnd, "of", allChunks.len

        let embResult = await ks.embedder.embed(batchTexts)

        if embResult.vectors.len != batchTexts.len:
            raise newException(ValueError,
                &"Embedding batch size mismatch: got {embResult.vectors.len} vectors for {batchTexts.len} texts")

        for j, vec in embResult.vectors:
            if vec.len != ks.embedder.dim:
                raise newException(ValueError,
                    &"Embedding dim mismatch: vec.len={vec.len}, expected={ks.embedder.dim} (idx {j})")

            let (pageNo, idx) = chunkMeta[i + j]
            let blobStr = toBlobString(vec)

            var chunk = KnowledgeChunk(
                documentId     : docId
                ,pageNo        : pageNo
                ,chunkIndex    : idx
                ,content       : batchTexts[j]
                ,metadataJson  : "{}"
                ,embedding     : Bytes blobStr
                ,embeddingDim  : vec.len
                ,embeddingModel: embResult.model
                ,createdAt     : epochTime().int64
            )
            ks.db.insert(chunk)
            total.inc

        ic "Stored batch", min(i + batchSize, allChunks.len), "/", allChunks.len

    discard ks.db.query(
        "UPDATE knowledge_document SET chunk_count = ? WHERE id = ?;"
        ,total, docId
    )

    ks.maybeQuantize()

    ic "Ingestion complete", total, "chunks for doc", docId
    return total

proc ingestText*(
    ks         : KnowledgeStore
    ,text      : string
    ,title     : string
    ,sourceType: string = "text"
    ,sourcePath: string = ""
    ,metadata  : JsonNode = %*{}
): Future[int] {.async.} =
    icb "ingestText", title, text.len, "chars"

    let docId = ks.insertDocument(
        sourceType  = sourceType
        ,sourcePath = sourcePath
        ,title      = title
        ,metadata   = metadata
    )

    let pages = @[(pageNo: 1, text: normalizeWhitespace(text))]
    return await ks.ingestChunks(docId, pages)

proc ingestFile*(
    ks    : KnowledgeStore
    ,path : string
    ,title: string = ""
): Future[int] {.async.} =
    icb "ingestFile", path

    if not fileExists(path):
        raise newException(IOError, "File not found: " & path)

    let absPath   = path.absolutePath
    let existing  = ks.latestDocumentIdBySourcePath(absPath)

    if existing != 0:
        case ks.config.duplicateIngestPolicy
        of dipSkip:
            icy "Already ingested (skip)", absPath, "docId", existing
            return ks.chunkCountForDoc(existing)

        of dipReplace:
            icy "Already ingested (replace)", absPath, "docId", existing
            discard ks.deleteDocument(existing)
            # fallthrough to ingest fresh

        of dipVersion:
            # keep existing; create a new document version
            discard

    let
        baseTitle = if title.len > 0: title else: path.extractFilename
        pages     = extractTextFromFile(path)
        sourceTy  = path.splitFile.ext.toLowerAscii.strip(chars = {'.'})

    var meta = %*{"file_name": path.extractFilename}

    var docTitle = baseTitle
    if existing != 0 and ks.config.duplicateIngestPolicy == dipVersion:
        let versionNo = ks.documentCountBySourcePath(absPath) + 1
        docTitle = &"{baseTitle} (v{versionNo})"
        meta["version"] = %versionNo
        meta["previous_document_id"] = %existing

    let docId = ks.insertDocument(
        sourceType  = sourceTy
        ,sourcePath = absPath
        ,title      = docTitle
        ,metadata   = meta
    )

    return await ks.ingestChunks(docId, pages)

# ============================================================================
# Search
# ============================================================================

proc search*(
    ks    : KnowledgeStore
    ,query: string
    ,k    : int = 5
): Future[seq[SearchResult]] {.async.} =
    icb "search()", query, k

    if not ks.vectorLoaded:
        icr "Vector extension not loaded — cannot perform semantic search"
        return @[]

    let kk = max(1, k)

    # Embed the query
    let queryVec = await ks.embedder.embedOne(query)
    if queryVec.len != ks.embedder.dim:
        raise newException(ValueError,
            &"Query embedding dim mismatch: got {queryVec.len}, expected {ks.embedder.dim}")

    let queryBlob = toBlobString(queryVec)

    let oversample = max(1, ks.config.searchOversample)
    let kScan      = kk * oversample

    let sql = """
        SELECT c.id, c.document_id, c.page_no, c.chunk_index, c.content,
               v.distance,
               d.title, d.source_type, d.source_path
        FROM vector_quantize_scan('knowledge_chunk', 'embedding', ?, ?) AS v
        JOIN knowledge_chunk c ON c.id = v.rowid
        JOIN knowledge_document d ON d.id = c.document_id
        ORDER BY v.distance ASC
        LIMIT ?;
    """

    try:
        let rows = ks.db.query(sql, queryBlob, kScan, kk)
        for row in rows:
            result.add SearchResult(
                chunkId     : row[0].parseInt
                ,documentId : row[1].parseInt
                ,pageNo     : row[2].parseInt
                ,chunkIndex : row[3].parseInt
                ,content    : row[4]
                ,distance   : row[5].parseFloat
                ,title      : row[6]
                ,sourceType : row[7]
                ,sourcePath : row[8]
            )
        ic "search returning", result.len, "results"
    except CatchableError as e:
        icr "Vector search failed", e.msg
        raise newException(ValueError,
            "Vector search failed (is sqlite-vector loaded + quantized?): " & e.msg)

proc searchWithContext*(
    ks       : KnowledgeStore
    ,query   : string
    ,k       : int = 5
    ,maxChars: int = 4000
): Future[seq[SearchResult]] {.async.} =
    var results = await ks.search(query, k)
    var totalChars = 0
    var trimmed: seq[SearchResult]

    for r in results:
        if totalChars + r.content.len > maxChars:
            let remaining = maxChars - totalChars
            if remaining > 100:
                var truncated = r
                truncated.content = r.content[0 ..< remaining] & "..."
                trimmed.add truncated
            break

        trimmed.add r
        totalChars += r.content.len

    return trimmed

# ============================================================================
# Formatting (for context injection into prompts)
# ============================================================================

proc formatSearchResults*(results: seq[SearchResult]): string =
    if results.len == 0:
        return ""

    var lines: seq[string] = @[]
    lines.add "## Retrieved Knowledge\n"

    for i, r in results:
        lines.add &"### [{i+1}] {r.title} (p.{r.pageNo})"
        lines.add r.content
        lines.add ""

    return lines.join("\n")

proc formatSearchResultsAsJson*(results: seq[SearchResult]): JsonNode =
    result = newJArray()
    for r in results:
        result.add %*{
            "chunk_id"     : r.chunkId
            ,"document_id" : r.documentId
            ,"title"       : r.title
            ,"page"        : r.pageNo
            ,"content"     : r.content
            ,"distance"    : r.distance
            ,"source"      : r.sourcePath
        }
