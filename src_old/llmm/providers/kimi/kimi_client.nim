## Moonshot (Kimi) API Client
##
## Centralized request logic for Moonshot's OpenAI-compatible API.
##
## Base URL (default): https://api.moonshot.ai/v1
##
## Example:
##   import llmm/providers/kimi
##   let client = newKimiClient(apiKey = "sk-...")
##   let response = await client.request("/chat/completions", HttpPost, %*{"model": "moonshot-v1-8k"})

import
    std/asyncdispatch
    ,std/httpclient
    ,std/json
    ,std/options
    ,std/sequtils
    ,std/strutils
    ,std/uri

import
    ./common/errors
    ,ic

type
    KimiClient  * = ref object
        apiKey  * : string
        baseUrl * = "https://api.moonshot.ai/v1"

const
    DefaultBaseUrl* = "https://api.moonshot.ai/v1"
    DefaultUserAgent = "curl/8.4.0"

# -----------------------------------------------------------------------------
# Constructor / Lifecycle
# -----------------------------------------------------------------------------

# proc newKimiClient*(
#     apiKey: string,
#     baseUrl = DefaultBaseUrl
# ): KimiClient =
#     ## Create a new Moonshot (Kimi) client
#     KimiClient(
#         apiKey: apiKey,
#         baseUrl: baseUrl.strip(leading = false, trailing = true, chars = {'/'})
#     )

proc close*(client: KimiClient) =
    ## No-op for API parity with other clients.
    discard client

# -----------------------------------------------------------------------------
# Internal Helpers
# -----------------------------------------------------------------------------

proc buildHeaders(client: KimiClient): HttpHeaders =
    ## Build HTTP headers for API requests
    let headerPairs = @[
        ("Authorization", "Bearer " & client.apiKey),
        ("Content-Type", "application/json")
    ]
    result = newHttpHeaders(headerPairs)

proc buildUrl(
    client: KimiClient,
    endpoint: string,
    query: seq[(string, string)] = @[]
): string =
    ## Build full URL from base, endpoint, and optional query parameters
    result = client.baseUrl & endpoint
    if query.len > 0:
        result &= "?" & query.mapIt(encodeUrl(it[0]) & "=" & encodeUrl(it[1])).join("&")

# -----------------------------------------------------------------------------
# Centralized Request Method
# -----------------------------------------------------------------------------

proc request*(
    client: KimiClient,
    endpoint: string,
    httpMethod: HttpMethod,
    body: JsonNode = nil,
    query: seq[(string, string)] = @[]
): Future[string] {.async.} =
    ## Execute an HTTP request to the Moonshot API
    ##
    ## Returns the raw response body string.
    ## Caller is responsible for error checking and parsing.

    let url = buildUrl(client, endpoint, query)
    let headers = buildHeaders(client)

    let httpClient = newAsyncHttpClient(
        userAgent = DefaultUserAgent,
        maxRedirects = 0
    )
    defer: httpClient.close()

    httpClient.headers = headers

    let bodyStr = if body != nil: $body else: ""

    let resp = await httpClient.request(
        url = url,
        httpMethod = httpMethod,
        body = bodyStr
    )

    result = await resp.body

proc get*(
    client: KimiClient,
    endpoint: string,
    query: seq[(string, string)] = @[]
): Future[string] {.async.} =
    result = await client.request(endpoint, HttpGet, nil, query)

proc post*(
    client: KimiClient,
    endpoint: string,
    body: JsonNode,
    query: seq[(string, string)] = @[]
): Future[string] {.async.} =
    result = await client.request(endpoint, HttpPost, body, query)

proc delete*(
    client: KimiClient,
    endpoint: string,
    query: seq[(string, string)] = @[]
): Future[string] {.async.} =
    result = await client.request(endpoint, HttpDelete, nil, query)
