## embeddings.nim — Embedding provider abstraction
##
## Thin interface for generating text embeddings.
## Provides:
## - Provider abstraction (EmbeddingProvider + EmbedFn)
## - OpenAI embeddings implementation using your existing OpenAIClient
## - Robust batching, validation, and observability via `ic`
## - Binary float32 <-> SQLite BLOB helpers (LE)
##
## Compile with -d:ic to enable rich debug output.

import std/[
    json
    ,asyncdispatch
    ,strformat
    ,strutils
    ,sequtils
    ,options
    ,times
    ,algorithm
    ,monotimes
]

import
    jsony
    ,rz
    ,ic

import
    ./providers/oai/oai     

# ============================================================================
# Types
# ============================================================================

type
    EmbeddingResult* = object
        vectors*      : seq[seq[float32]]
        model*        : string
        dim*          : int
        tokenCount*   : int               ## total tokens used (for cost tracking)
        promptTokens* : int               ## prompt_tokens (if provided)
        maxBatch*      : int               ## batch size used (for observability)
        maxRetries*    : int               ## retries used (for observability)

    ## Callback signature for embedding generation.
    ## NOTE: `.closure.` allows factories to capture client/model config.
    EmbedFn* = proc(texts: seq[string]): Future[EmbeddingResult] {.gcsafe, closure.}

    EmbeddingProvider* = ref object
        model*      : string
        dim*        : int
        maxBatch*   : int
        maxRetries* : int
        embedFn*    : EmbedFn

    OAIApiUsage* = object
        prompt_tokens* : int
        total_tokens*  : int

    OAIEmbeddingData* = object
        `object`*  : string
        embedding* : seq[float32]
        index*     : int

    OAIEmbeddingsResponse* = object
        `object`* : string
        data*     : seq[OAIEmbeddingData]
        model*    : string
        usage*    : Option[OAIApiUsage]

# ============================================================================
# Small helpers
# ============================================================================

proc isBlank(s: string): bool =
    result = s.len == 0 or s.allCharsInSet(Whitespace)

proc clampMin(x, minV: int): int =
    if x < minV: minV else: x

proc safeSnippet(s: string, n = 600): string =
    if s.len <= n: s else: s[0 ..< n] & "…"

proc chunkBy[T](items: seq[T], chunkSize: int): seq[seq[T]] =
    let cs = clampMin(chunkSize, 1)
    result = @[]
    var i = 0
    while i < items.len:
        let j = min(i + cs, items.len)
        result.add(items[i ..< j])
        i = j

template icBatchStats(texts: seq[string]) =
    when defined(ic):
        var totalChars = 0
        var maxChars   = 0
        var blanks     = 0
        for t in texts:
            totalChars += t.len
            if t.len > maxChars: maxChars = t.len
            if t.isBlank: blanks.inc
        icb "embeddings.stats", "n=", texts.len, "totalChars=", totalChars, "maxChars=", maxChars, "blank=", blanks

proc validateEmbeddingResponse(
    texts: seq[string],
    resp : OAIEmbeddingsResponse,
    expectedDim: int
) =
    ## Ensures:
    ## - data count matches inputs
    ## - indices cover 0..n-1
    ## - all vectors have consistent dimensionality
    if resp.data.len != texts.len:
        raise newException(ValueError,
            &"Embeddings response size mismatch. inputs={texts.len} data={resp.data.len} model={resp.model}")

    # Ensure ordering by index (OpenAI usually returns ordered, but we don’t assume)
    var sorted = resp.data
    sorted.sort(proc(a, b: OAIEmbeddingData): int = cmp(a.index, b.index))

    for i, item in sorted:
        if item.index != i:
            raise newException(ValueError,
                &"Embeddings response index mismatch at position {i}. got={item.index} model={resp.model}")

    # Dim checks
    let firstDim = if sorted.len > 0: sorted[0].embedding.len else: 0
    if firstDim <= 0:
        raise newException(ValueError, "Embeddings response contained empty vectors.")

    if expectedDim > 0 and firstDim != expectedDim:
        raise newException(ValueError,
            &"Embedding dim mismatch. expected={expectedDim} got={firstDim} model={resp.model}")

    for item in sorted:
        if item.embedding.len != firstDim:
            raise newException(ValueError,
                &"Embedding dim inconsistent. got={item.embedding.len} expected={firstDim} index={item.index} model={resp.model}")

# ============================================================================
# Binary serialization (float32 LE blobs for SQLite)
# ============================================================================

proc f32ToU32Bits(v: float32): uint32 =
    var bits: uint32
    copyMem(addr bits, unsafeAddr v, sizeof(v))
    result = bits

proc u32BitsToF32(bits: uint32): float32 =
    var v: float32
    copyMem(addr v, unsafeAddr bits, sizeof(bits))
    result = v

proc toBlob*(vec: seq[float32]): seq[byte] =
    ## Convert a float32 vector to little-endian bytes for SQLite BLOB storage.
    result = newSeq[byte](vec.len * 4)
    for i, v in vec:
        let bits = f32ToU32Bits(v)
        result[i * 4 + 0] = byte(bits and 0xFF)
        result[i * 4 + 1] = byte((bits shr 8) and 0xFF)
        result[i * 4 + 2] = byte((bits shr 16) and 0xFF)
        result[i * 4 + 3] = byte((bits shr 24) and 0xFF)

proc fromBlob*(blob: seq[byte]): seq[float32] =
    ## Convert little-endian bytes back to float32 vector.
    if blob.len mod 4 != 0:
        raise newException(ValueError, &"Invalid blob length (not multiple of 4): {blob.len}")
    let dim = blob.len div 4
    result = newSeq[float32](dim)
    for i in 0 ..< dim:
        let bits =
            uint32(blob[i * 4 + 0]) or
            (uint32(blob[i * 4 + 1]) shl 8) or
            (uint32(blob[i * 4 + 2]) shl 16) or
            (uint32(blob[i * 4 + 3]) shl 24)
        result[i] = u32BitsToF32(bits)

proc toBlobString*(vec: seq[float32]): string =
    ## Convert float32 vector to a raw string for SQLite BLOB binding.
    let bytes = toBlob(vec)
    result = newString(bytes.len)
    for i, b in bytes:
        result[i] = char(b)

proc fromBlobString*(s: string): seq[float32] =
    ## Convert raw BLOB string back to float32 vector.
    if s.len mod 4 != 0:
        raise newException(ValueError, &"Invalid blob string length (not multiple of 4): {s.len}")
    let dim = s.len div 4
    result = newSeq[float32](dim)
    for i in 0 ..< dim:
        let bits =
            uint32(ord(s[i * 4 + 0])) or
            (uint32(ord(s[i * 4 + 1])) shl 8) or
            (uint32(ord(s[i * 4 + 2])) shl 16) or
            (uint32(ord(s[i * 4 + 3])) shl 24)
        result[i] = u32BitsToF32(bits)

# ============================================================================
# OpenAI Embeddings API (consistent with your /responses patterns)
# ============================================================================

proc createEmbeddingsRaw*(
    client: OpenAIClient,
    texts : seq[string],
    model : string = "text-embedding-3-small"
): Future[string] {.async.} =
    ## Calls OpenAI embeddings endpoint and returns raw JSON string.
    ## NOTE: OpenAIClient.baseUrl already includes /v1, so endpoint is "/embeddings".
    if texts.len == 0:
        raise newException(ValueError, "createEmbeddingsRaw: texts is empty")

    icBatchStats(texts)
    when defined(ic):
        icb "oai.embeddings.request", "model=", model, "n=", texts.len

    let body = %*{
        "model": model,
        "input": %texts
    }

    # endpoint must be "/embeddings" (NOT "/v1/embeddings")
    result = await client.post("/embeddings", body)

proc createEmbeddings*(
    client: OpenAIClient,
    texts : seq[string],
    model : string = "text-embedding-3-small"
): Future[Rz[OAIEmbeddingsResponse]] {.async.} =
    ## Typed wrapper with error handling.
    var raw: string
    try:
        raw = await createEmbeddingsRaw(client, texts, model)
        if isApiError(raw):
            when defined(ic):
                icr "oai.embeddings.api_error", safeSnippet(raw)
            return rz.err[OAIEmbeddingsResponse](raw)
    except CatchableError as e:
        when defined(ic):
            icr "oai.embeddings.exception", e.msg
        return rz.err[OAIEmbeddingsResponse](&"Embeddings request failed: {e.msg}")

    try:
        let parsed = raw.fromJson(OAIEmbeddingsResponse)
        return rz.ok(parsed)
    except CatchableError as e:
        when defined(ic):
            icr "oai.embeddings.parse_error", e.msg
            icb "oai.embeddings.raw_snippet", safeSnippet(raw)
        return rz.err[OAIEmbeddingsResponse](
            &"Error parsing embeddings response: {e.msg}\nResponse -> {safeSnippet(raw)}"
        )

proc createEmbeddingsOrRaise*(
    client: OpenAIClient,
    texts : seq[string],
    model : string = "text-embedding-3-small"
): Future[OAIEmbeddingsResponse] {.async.} =
    let r = await createEmbeddings(client, texts, model)
    if not r.ok:
        raise newException(ValueError, &"OpenAI embeddings error:\n{safeSnippet(r.err)}")
    r.val

# ============================================================================
# Provider factories
# ============================================================================

proc newEmbedder*(
    model    : string,
    dim      : int,
    embedFn  : EmbedFn,
    maxBatch : int = 128,
    maxRetries: int = 2
): EmbeddingProvider =
    ## Create a custom embedding provider with your own embed function.
    icb "Creating custom embedder", model, dim, "maxBatch=", maxBatch, "maxRetries=", maxRetries
    EmbeddingProvider(
        model      : model
        ,dim       : dim
        ,maxBatch  : clampMin(maxBatch, 1)
        ,maxRetries: max(0, maxRetries)
        ,embedFn   : embedFn
    )

proc newOpenAIEmbedder*(
    model : string = "text-embedding-3-small",
    dim   : int = 1536,
    maxBatch  : int = 128,
    maxRetries: int = 2
): EmbeddingProvider =
    ## Backward-compatible constructor that DOES NOT capture a client.
    ## You must set embedFn later (or use the overload that takes a client).
    icb "Creating OpenAI embedder (no client)", model, dim
    EmbeddingProvider(
        model      : model
        ,dim       : dim
        ,maxBatch  : clampMin(maxBatch, 1)
        ,maxRetries: max(0, maxRetries)
        ,embedFn   : nil
    )

proc newOpenAIEmbedder*(
    client: OpenAIClient,
    model : string = "text-embedding-3-small",
    dim   : int = 1536,
    maxBatch  : int = 128,
    maxRetries: int = 2
): EmbeddingProvider =
    ## Preferred constructor: captures OpenAIClient and fully wires embedFn.
    icb "Creating OpenAI embedder (client)", model, dim, "maxBatch=", maxBatch, "maxRetries=", maxRetries

    result = EmbeddingProvider(
        model      : model
        ,dim       : dim
        ,maxBatch  : clampMin(maxBatch, 1)
        ,maxRetries: max(0, maxRetries)
    )

    # Wire embedFn using your OpenAI client + robust batching/validation.
    result.embedFn = proc(texts: seq[string]): Future[EmbeddingResult] {.async.} =
        if texts.len == 0:
            raise newException(ValueError, "embedFn: texts is empty")

        when defined(ic):
            icb "embeddings.embedFn.start", "model=", model, "n=", texts.len

        if texts.anyIt(it.isBlank):
            # Allow, but make it loud.
            when defined(ic):
                icy "embeddings.embedFn.warning", "blank/whitespace inputs present"

        let t0 = getMonoTime()

        var
            allVectors  : seq[seq[float32]] = @[]
            totalTokens = 0
            promptToks  = 0

        for batchIdx, batch in chunkBy(texts, result.maxBatch):
            when defined(ic):
                icb "embeddings.batch", "idx=", batchIdx, "n=", batch.len, "model=", model
            icBatchStats(batch)

            var attempt = 0
            var lastErr = ""

            while true:
                let r = await createEmbeddings(client, batch, model)
                if r.ok:
                    let resp = r.val

                    # Validate + order by index
                    validateEmbeddingResponse(batch, resp, dim)

                    var sorted = resp.data
                    sorted.sort(proc(a, b: OAIEmbeddingData): int = cmp(a.index, b.index))

                    for item in sorted:
                        allVectors.add(item.embedding)

                    if resp.usage.isSome:
                        let u = resp.usage.get
                        totalTokens += u.total_tokens
                        promptToks  += u.prompt_tokens

                    break

                # Error path
                lastErr = r.err
                when defined(ic):
                    icr "embeddings.batch.error", safeSnippet(lastErr)

                # Retry heuristic (best-effort, since OpenAIClient doesn’t expose HTTP status)
                attempt.inc
                if attempt > result.maxRetries:
                    raise newException(ValueError,
                        &"OpenAI embeddings failed after {result.maxRetries} retries. " &
                        &"model={model} batch={batchIdx} n={batch.len}\n" &
                        &"{safeSnippet(lastErr)}")

                # Light backoff (avoid pulling in extra deps)
                let sleepMs = 250 * attempt
                when defined(ic):
                    icy "embeddings.batch.retrying", "attempt=", attempt, "sleepMs=", sleepMs
                await sleepAsync(sleepMs)

        # Final dimension inference/validation
        let inferredDim = if allVectors.len > 0: allVectors[0].len else: 0
        if inferredDim <= 0:
            raise newException(ValueError, "Embeddings returned zero vectors.")

        if dim > 0 and inferredDim != dim:
            raise newException(ValueError,
                &"Embedding dim mismatch (final). expected={dim} got={inferredDim} model={model}")

        for v in allVectors:
            if v.len != inferredDim:
                raise newException(ValueError,
                    &"Embedding dim inconsistent (final). expected={inferredDim} got={v.len} model={model}")

        let dtMs = (getMonoTime() - t0).inMilliseconds
        when defined(ic):
            icb "embeddings.embedFn.done", "vectors=", allVectors.len, "dim=", inferredDim,
                "promptTokens=", promptToks, "totalTokens=", totalTokens, "ms=", dtMs

        return EmbeddingResult(
            vectors      : allVectors
            ,model       : model
            ,dim         : inferredDim
            ,tokenCount  : totalTokens
            ,promptTokens: promptToks
        )

# ============================================================================
# Provider API
# ============================================================================

proc embed*(
    p     : EmbeddingProvider,
    texts : seq[string]
): Future[EmbeddingResult] {.async.} =
    if p.isNil:
        raise newException(ValueError, "EmbeddingProvider is nil")
    if p.embedFn.isNil:
        raise newException(ValueError, "EmbeddingProvider.embedFn is nil — set it before calling embed()")
    if texts.len == 0:
        raise newException(ValueError, "embed(): texts is empty")

    when defined(ic):
        icb "embed()", "model=", p.model, "n=", texts.len, "maxBatch=", p.maxBatch, "maxRetries=", p.maxRetries
    icBatchStats(texts)

    result = await p.embedFn(texts)

    # Post-check vs provider dim (if configured)
    if p.dim > 0 and result.dim != p.dim:
        when defined(ic):
            icr "embed().dim_mismatch", "providerDim=", p.dim, "resultDim=", result.dim, "model=", p.model
        raise newException(ValueError,
            &"Provider dim mismatch. providerDim={p.dim} resultDim={result.dim} model={p.model}")

proc embedOne*(
    p    : EmbeddingProvider,
    text : string
): Future[seq[float32]] {.async.} =
    let r = await p.embed(@[text])
    if r.vectors.len == 0:
        raise newException(ValueError, "Embedding returned no vectors")
    r.vectors[0]
