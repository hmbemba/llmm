## OpenAI API Client
##
## Provides:
## - Centralized request logic (DRY)
## - Header construction
## - URL building
##
## Example:
##   let client = newOpenAIClient(apiKey = "sk-...")
##   let response = await client.request("/responses", HttpPost, %*{"model": "gpt-4o"})

import
    std/asyncdispatch
    ,std/httpclient
    ,std/json
    ,std/options
    ,std/strutils
    ,std/sequtils
    ,std/uri

import
    ./common/errors
    ,ic

type
    OpenAIClient*     = ref object
        apiKey*       : string
        baseUrl*      = "https://api.openai.com/v1"
        organization* : Option[string]
        project*      : Option[string]

const
    DefaultBaseUrl* = "https://api.openai.com/v1"
    DefaultUserAgent = "curl/8.4.0"

# # -----------------------------------------------------------------------------
# # Constructor
# # -----------------------------------------------------------------------------

# proc newOpenAIClient*(
#     apiKey       : string,
#     baseUrl      = DefaultBaseUrl,
#     organization = none(string),
#     project      = none(string)
# ): OpenAIClient =
#     ## Create a new OpenAI client
#     result = OpenAIClient(
#         apiKey: apiKey,
#         baseUrl: baseUrl,
#         organization: organization,
#         project: project
#     )

# -----------------------------------------------------------------------------
# Internal Helpers
# -----------------------------------------------------------------------------

proc buildHeaders(client: OpenAIClient): HttpHeaders =
    ## Build HTTP headers for API requests
    var headerPairs = @[
        ("Authorization", "Bearer " & client.apiKey),
        ("Content-Type", "application/json")
    ]
    
    if client.organization.isSome:
        headerPairs.add(("OpenAI-Organization", client.organization.get))
    
    if client.project.isSome:
        headerPairs.add(("OpenAI-Project", client.project.get))
    
    result = newHttpHeaders(headerPairs)

proc buildUrl(client: OpenAIClient, endpoint: string, query: seq[(string, string)] = @[]): string =
    ## Build full URL from base, endpoint, and optional query parameters
    # icb client, endpoint, query
    result = client.baseUrl & endpoint
    if query.len > 0:
        result &= "?" & query.mapIt(encodeUrl(it[0]) & "=" & encodeUrl(it[1])).join("&")

# -----------------------------------------------------------------------------
# Centralized Request Method
# -----------------------------------------------------------------------------

proc request*(
    client: OpenAIClient,
    endpoint: string,
    httpMethod: HttpMethod,
    body: JsonNode = nil,
    query: seq[(string, string)] = @[]
): Future[string] {.async.} =
    ## Execute an HTTP request to the OpenAI API
    ##
    ## Returns the raw response body string.
    ## Caller is responsible for error checking and parsing.
    ##
    ## Example:
    ##   let resp = await client.request("/responses", HttpPost, %*{"model": "gpt-4o"})
    ##   if isApiError(resp):
    ##       echo parseApiError(resp)
    
    let url = buildUrl(client, endpoint, query)
    let headers = buildHeaders(client)
    
    # Create HTTP client per request
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
    client: OpenAIClient,
    endpoint: string,
    query: seq[(string, string)] = @[]
): Future[string] {.async.} =
    ## Convenience method for GET requests
    result = await client.request(endpoint, HttpGet, nil, query)

proc post*(
    client: OpenAIClient,
    endpoint: string,
    body: JsonNode,
    query: seq[(string, string)] = @[]
): Future[string] {.async.} =
    ## Convenience method for POST requests
    result = await client.request(endpoint, HttpPost, body, query)

proc delete*(
    client: OpenAIClient,
    endpoint: string,
    query: seq[(string, string)] = @[]
): Future[string] {.async.} =
    ## Convenience method for DELETE requests
    result = await client.request(endpoint, HttpDelete, nil, query)

# -----------------------------------------------------------------------------
# Query Parameter Helpers
# -----------------------------------------------------------------------------

proc includeQuery*(includes: openArray[string]): seq[(string, string)] =
    ## Build include query parameters
    result = @[]
    for inc in includes:
        result.add(("include", inc))

proc paginationQuery*(
    after = "",
    limit = 0,
    order = ""
): seq[(string, string)] =
    ## Build pagination query parameters
    result = @[]
    if after.len > 0:
        result.add(("after", after))
    if limit > 0:
        result.add(("limit", $limit))
    if order.len > 0:
        result.add(("order", order))