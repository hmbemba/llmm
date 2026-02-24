## Jina AI Search Foundation API Tools
## Get your Jina AI API key for free: https://jina.ai/?sui=apikey
##
## This module provides tools for Jina AI's Search Foundation APIs:
## - Embeddings API: Generate embeddings for text, images, or code
## - Reader API (r.jina.ai): Fetch LLM-friendly content from URLs
## - Search API (s.jina.ai): Web search with LLM-friendly results
## - Reranker API: Rerank search results by relevance
## - VLM API: Vision-language model for image understanding
## - DeepSearch API: Comprehensive web research with reasoning
## - Segmenter API: Tokenize and segment text into chunks
## - Classifier API: Zero-shot classification for text or images

import
    std/asyncdispatch
    ,std/httpclient
    ,std/json
    ,std/strformat
    ,std/strutils
    ,std/os
    ,std/base64
    ,std/options

import base

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

const
    JINA_EMBEDDINGS_URL = "https://api.jina.ai/v1/embeddings"
    JINA_RERANK_URL     = "https://api.jina.ai/v1/rerank"
    JINA_READER_URL     = "https://r.jina.ai/"
    JINA_SEARCH_URL     = "https://s.jina.ai/"
    JINA_VLM_URL        = "https://api-beta-vlm.jina.ai/v1/chat/completions"
    JINA_DEEPSEARCH_URL = "https://deepsearch.jina.ai/v1/chat/completions"
    JINA_SEGMENT_URL    = "https://segment.jina.ai/"
    JINA_CLASSIFY_URL   = "https://api.jina.ai/v1/classify"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

proc getJinaApiKey(): string =
    ## Get Jina API key from environment variable
    result = getEnv("JINA_API_KEY", "")

proc createJinaHeaders(apiKey: string = ""): HttpHeaders =
    ## Create headers for Jina API requests
    let key = if apiKey.len > 0: apiKey else: getJinaApiKey()
    result = newHttpHeaders({
        "Authorization": &"Bearer {key}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    })

proc makeJinaRequest(url: string, body: JsonNode, apiKey: string = ""): Future[JsonNode] {.async.} =
    ## Make an async HTTP POST request to Jina API
    let headers = createJinaHeaders(apiKey)
    let client = newAsyncHttpClient()
    client.headers = headers
    
    try:
        let response = await client.post(url, body = $body)
        let respBody = await response.body
        
        if response.code.int >= 200 and response.code.int < 300:
            try:
                result = parseJson(respBody)
            except:
                result = %*{ "raw_response": respBody }
        else:
            result = toolError(&"HTTP {response.code}: {respBody}")
    except Exception as e:
        result = toolError(&"Request failed: {e.msg}")
    finally:
        client.close()

proc makeJinaGet(url: string, apiKey: string = ""): Future[JsonNode] {.async.} =
    ## Make an async HTTP GET request to Jina API
    let headers = createJinaHeaders(apiKey)
    let client = newAsyncHttpClient()
    client.headers = headers
    
    try:
        let response = await client.get(url)
        let respBody = await response.body
        
        if response.code.int >= 200 and response.code.int < 300:
            try:
                result = parseJson(respBody)
            except:
                result = %*{ "content": respBody }
        else:
            result = toolError(&"HTTP {response.code}: {respBody}")
    except Exception as e:
        result = toolError(&"Request failed: {e.msg}")
    finally:
        client.close()

# -----------------------------------------------------------------------------
# Embeddings Tool
# -----------------------------------------------------------------------------

proc JinaEmbeddingsTool*(): Tool =
    ## Generate embeddings for text, images, or code using Jina AI.
    ## Supports models: jina-embeddings-v4 (multimodal), jina-embeddings-v3 (text),
    ## jina-clip-v2 (multimodal), jina-code-embeddings-0.5b/1.5b (code).
    Tool(
        name: "jina_embeddings",
        description: "Generate embeddings for text, images, or code. Models: 'jina-embeddings-v4' (multimodal, 2048d), 'jina-embeddings-v3' (text, 1024d), 'jina-clip-v2' (multimodal, 1024d), 'jina-code-embeddings-0.5b/1.5b' (code). Supports text strings, image URLs, base64 images, and PDF URLs.",
        parameters: %*{
            "type": "object",
            "properties": {
                "input": {
                    "type": "array",
                    "items": {
                        "oneOf": [
                            {"type": "string"},
                            {
                                "type": "object",
                                "properties": {
                                    "text": {"type": "string"},
                                    "image": {"type": "string"},
                                    "pdf": {"type": "string"}
                                }
                            }
                        ]
                    },
                    "description": "Array of texts, image URLs/base64, or objects with 'text', 'image', or 'pdf' keys"
                },
                "model": {
                    "type": "string",
                    "enum": ["jina-embeddings-v4", "jina-embeddings-v3", "jina-clip-v2", "jina-code-embeddings-0.5b", "jina-code-embeddings-1.5b"],
                    "default": "jina-embeddings-v3",
                    "description": "Embedding model to use"
                },
                "task": {
                    "type": "string",
                    "enum": ["retrieval.query", "retrieval.passage", "text-matching", "classification", "code.query", "code.passage", "nl2code.query", "nl2code.passage", "qa.query", "qa.passage"],
                    "description": "Task type for optimization (model-specific)"
                },
                "embedding_type": {
                    "type": "string",
                    "enum": ["float", "base64", "binary", "ubinary"],
                    "default": "float",
                    "description": "Format of returned embeddings"
                },
                "dimensions": {
                    "type": "integer",
                    "description": "Truncate embeddings to specified size"
                },
                "late_chunking": {
                    "type": "boolean",
                    "default": false,
                    "description": "Enable late chunking for long documents"
                },
                "normalized": {
                    "type": "boolean",
                    "default": false,
                    "description": "Normalize embeddings to unit L2 norm (v3/clip-v2 only)"
                },
                "api_key": {
                    "type": "string",
                    "description": "Jina API key (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["input"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: ""
            
            var body = %*{}
            body["input"] = args["input"]
            
            if args.hasKey("model"):
                body["model"] = args["model"]
            else:
                body["model"] = %"jina-embeddings-v3"
            
            if args.hasKey("task"):
                body["task"] = args["task"]
            if args.hasKey("embedding_type"):
                body["embedding_type"] = args["embedding_type"]
            if args.hasKey("dimensions"):
                body["dimensions"] = args["dimensions"]
            if args.hasKey("late_chunking"):
                body["late_chunking"] = args["late_chunking"]
            if args.hasKey("normalized"):
                body["normalized"] = args["normalized"]
            
            result = await makeJinaRequest(JINA_EMBEDDINGS_URL, body, apiKey)
    )

# -----------------------------------------------------------------------------
# Basic Reader Tool (No API Key Required)
# -----------------------------------------------------------------------------

proc JinaBasicReaderTool*(): Tool =
    ## Fetch LLM-friendly content from a URL using Jina Reader API.
    ## FREE for basic usage - no API key required!
    ## Simply prepends 'https://r.jina.ai/' to your URL.
    ## For higher rate limits, provide an API key via JINA_API_KEY env var or api_key parameter.
    Tool(
        name: "jina_basic_reader",
        description: "Fetch LLM-friendly markdown content from a URL. FREE for basic usage - no API key required! Just provide a URL. For higher rate limits, set JINA_API_KEY environment variable. Returns title, description, and cleaned content.",
        parameters: %*{
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "URL to fetch and extract content from"
                },
                "api_key": {
                    "type": "string",
                    "description": "Optional: Jina API key for higher rate limits (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["url"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let url = args["url"].getStr
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: getEnv("JINA_API_KEY", "")
            
            # Prepend r.jina.ai to the URL
            let readerUrl = JINA_READER_URL & url
            
            var headers = newHttpHeaders({
                "Accept": "application/json"
            })
            
            # Add auth header if API key is available
            if apiKey.len > 0:
                headers["Authorization"] = &"Bearer {apiKey}"
            
            let client = newAsyncHttpClient()
            client.headers = headers
            
            try:
                let response = await client.get(readerUrl)
                let respBody = await response.body
                
                if response.code.int >= 200 and response.code.int < 300:
                    try:
                        result = parseJson(respBody)
                    except:
                        # Fallback: return as raw content if not valid JSON
                        result = %*{
                            "content": respBody,
                            "url": url
                        }
                else:
                    result = toolError(&"HTTP {response.code}: {respBody}")
            except Exception as e:
                result = toolError(&"Request failed: {e.msg}")
            finally:
                client.close()
    )

# -----------------------------------------------------------------------------
# Reader Tool (Advanced)
# -----------------------------------------------------------------------------

proc JinaReaderTool*(): Tool =
    ## Fetch LLM-friendly content from a URL using Jina Reader API.
    ## Extracts clean markdown from web pages for downstream LLM tasks.
    Tool(
        name: "jina_reader",
        description: "Fetch LLM-friendly markdown content from a URL. Returns title, description, cleaned content, images, and links. Use 'browser' engine for JS-heavy sites, 'direct' for speed.",
        parameters: %*{
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "URL to fetch and extract content from"
                },
                "engine": {
                    "type": "string",
                    "enum": ["browser", "direct", "cf-browser-rendering"],
                    "description": "Engine: browser (best quality), direct (fastest), cf-browser-rendering (JS-heavy sites)"
                },
                "timeout": {
                    "type": "integer",
                    "description": "Maximum time in seconds to wait for page load"
                },
                "target_selector": {
                    "type": "string",
                    "description": "CSS selectors to focus on specific elements"
                },
                "remove_selector": {
                    "type": "string",
                    "description": "CSS selectors to exclude (e.g., header, footer, .ads)"
                },
                "wait_for_selector": {
                    "type": "string",
                    "description": "CSS selector to wait for before returning"
                },
                "with_links_summary": {
                    "type": "boolean",
                    "default": false,
                    "description": "Include summary of all links"
                },
                "with_images_summary": {
                    "type": "boolean",
                    "default": false,
                    "description": "Include summary of all images"
                },
                "with_generated_alt": {
                    "type": "boolean",
                    "default": false,
                    "description": "Generate alt text for images without captions"
                },
                "no_cache": {
                    "type": "boolean",
                    "default": false,
                    "description": "Bypass cache for fresh retrieval"
                },
                "return_format": {
                    "type": "string",
                    "enum": ["markdown", "html", "text", "screenshot", "pageshot"],
                    "default": "markdown",
                    "description": "Output format"
                },
                "api_key": {
                    "type": "string",
                    "description": "Jina API key (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["url"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: ""
            let url = args["url"].getStr
            
            var body = %*{ "url": url }
            
            if args.hasKey("viewport"):
                body["viewport"] = args["viewport"]
            if args.hasKey("inject_page_script"):
                body["injectPageScript"] = args["inject_page_script"]
            
            let headers = createJinaHeaders(apiKey)
            let client = newAsyncHttpClient()
            client.headers = headers
            
            # Add optional headers
            if args.hasKey("engine"):
                client.headers["X-Engine"] = args["engine"].getStr
            if args.hasKey("timeout"):
                client.headers["X-Timeout"] = $args["timeout"].getInt
            if args.hasKey("target_selector"):
                client.headers["X-Target-Selector"] = args["target_selector"].getStr
            if args.hasKey("remove_selector"):
                client.headers["X-Remove-Selector"] = args["remove_selector"].getStr
            if args.hasKey("wait_for_selector"):
                client.headers["X-Wait-For-Selector"] = args["wait_for_selector"].getStr
            if args.hasKey("with_links_summary") and args["with_links_summary"].getBool:
                client.headers["X-With-Links-Summary"] = "true"
            if args.hasKey("with_images_summary") and args["with_images_summary"].getBool:
                client.headers["X-With-Images-Summary"] = "true"
            if args.hasKey("with_generated_alt") and args["with_generated_alt"].getBool:
                client.headers["X-With-Generated-Alt"] = "true"
            if args.hasKey("no_cache") and args["no_cache"].getBool:
                client.headers["X-No-Cache"] = "true"
            if args.hasKey("return_format"):
                client.headers["X-Return-Format"] = args["return_format"].getStr
            
            try:
                let response = await client.post(JINA_READER_URL, body = $body)
                let respBody = await response.body
                
                if response.code.int >= 200 and response.code.int < 300:
                    try:
                        result = parseJson(respBody)
                    except:
                        result = %*{ "content": respBody }
                else:
                    result = toolError(&"HTTP {response.code}: {respBody}")
            except Exception as e:
                result = toolError(&"Request failed: {e.msg}")
            finally:
                client.close()
    )

# -----------------------------------------------------------------------------
# Search Tool
# -----------------------------------------------------------------------------

proc JinaSearchTool*(): Tool =
    ## Search the web using Jina Search API.
    ## Returns search results in LLM-friendly format with content, links, and metadata.
    Tool(
        name: "jina_search",
        description: "Search the web and get LLM-friendly results. Returns pages with title, description, URL, and cleaned content. Use 'site' to restrict to a domain, 'gl' for country, 'hl' for language.",
        parameters: %*{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query"
                },
                "site": {
                    "type": "string",
                    "description": "Restrict search to specific domain (e.g., 'jina.ai')"
                },
                "gl": {
                    "type": "string",
                    "description": "Country code for search (e.g., 'US', 'DE', 'JP')"
                },
                "hl": {
                    "type": "string",
                    "description": "Language code (e.g., 'en', 'de', 'ja')"
                },
                "location": {
                    "type": "string",
                    "description": "Location for query origin (city-level recommended)"
                },
                "num": {
                    "type": "integer",
                    "description": "Maximum results to return (may increase latency)"
                },
                "page": {
                    "type": "integer",
                    "default": 0,
                    "description": "Result offset for pagination"
                },
                "no_cache": {
                    "type": "boolean",
                    "default": false,
                    "description": "Bypass cache for real-time data"
                },
                "with_links_summary": {
                    "type": "boolean",
                    "default": false,
                    "description": "Include summary of all links"
                },
                "with_images_summary": {
                    "type": "boolean",
                    "default": false,
                    "description": "Include summary of all images"
                },
                "respond_with": {
                    "type": "string",
                    "enum": ["no-content"],
                    "description": "Use 'no-content' to exclude page content from response"
                },
                "api_key": {
                    "type": "string",
                    "description": "Jina API key (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["query"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: ""
            
            var body = %*{ "q": args["query"].getStr }
            
            if args.hasKey("gl"):
                body["gl"] = args["gl"]
            if args.hasKey("hl"):
                body["hl"] = args["hl"]
            if args.hasKey("location"):
                body["location"] = args["location"]
            if args.hasKey("num"):
                body["num"] = args["num"]
            if args.hasKey("page"):
                body["page"] = args["page"]
            
            let headers = createJinaHeaders(apiKey)
            let client = newAsyncHttpClient()
            client.headers = headers
            
            # Add optional headers
            if args.hasKey("site"):
                client.headers["X-Site"] = args["site"].getStr
            if args.hasKey("no_cache") and args["no_cache"].getBool:
                client.headers["X-No-Cache"] = "true"
            if args.hasKey("with_links_summary") and args["with_links_summary"].getBool:
                client.headers["X-With-Links-Summary"] = "true"
            if args.hasKey("with_images_summary") and args["with_images_summary"].getBool:
                client.headers["X-With-Images-Summary"] = "true"
            if args.hasKey("respond_with"):
                client.headers["X-Respond-With"] = args["respond_with"].getStr
            
            try:
                let response = await client.post(JINA_SEARCH_URL, body = $body)
                let respBody = await response.body
                
                if response.code.int >= 200 and response.code.int < 300:
                    try:
                        result = parseJson(respBody)
                    except:
                        result = %*{ "raw_response": respBody }
                else:
                    result = toolError(&"HTTP {response.code}: {respBody}")
            except Exception as e:
                result = toolError(&"Request failed: {e.msg}")
            finally:
                client.close()
    )

# -----------------------------------------------------------------------------
# Reranker Tool
# -----------------------------------------------------------------------------

proc JinaRerankTool*(): Tool =
    ## Rerank documents by relevance to a query using Jina Reranker API.
    ## Improves search result quality by scoring document-query relevance.
    Tool(
        name: "jina_rerank",
        description: "Rerank documents by relevance to a query. Models: 'jina-reranker-v3' (0.6B, multilingual), 'jina-reranker-m0' (2.4B, multimodal), 'jina-reranker-v2-base-multilingual' (278M), 'jina-colbert-v2' (560M). Returns documents sorted by relevance score.",
        parameters: %*{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query for relevance scoring"
                },
                "documents": {
                    "type": "array",
                    "items": {
                        "oneOf": [
                            {"type": "string"},
                            {
                                "type": "object",
                                "properties": {
                                    "text": {"type": "string"},
                                    "image": {"type": "string"}
                                }
                            }
                        ]
                    },
                    "description": "Documents to rerank (strings or objects with 'text'/'image')"
                },
                "model": {
                    "type": "string",
                    "enum": ["jina-reranker-v3", "jina-reranker-m0", "jina-reranker-v2-base-multilingual", "jina-colbert-v2"],
                    "default": "jina-reranker-v3",
                    "description": "Reranker model to use"
                },
                "top_n": {
                    "type": "integer",
                    "description": "Number of top results to return (default: all)"
                },
                "return_documents": {
                    "type": "boolean",
                    "default": true,
                    "description": "Return document text in results (false = indices and scores only)"
                },
                "api_key": {
                    "type": "string",
                    "description": "Jina API key (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["query", "documents"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: ""
            
            var body = %*{}
            body["query"] = args["query"]
            body["documents"] = args["documents"]
            
            if args.hasKey("model"):
                body["model"] = args["model"]
            else:
                body["model"] = %"jina-reranker-v3"
            
            if args.hasKey("top_n"):
                body["top_n"] = args["top_n"]
            if args.hasKey("return_documents"):
                body["return_documents"] = args["return_documents"]
            
            result = await makeJinaRequest(JINA_RERANK_URL, body, apiKey)
    )

# -----------------------------------------------------------------------------
# VLM (Vision Language Model) Tool
# -----------------------------------------------------------------------------

proc JinaVLMChatTool*(): Tool =
    ## Chat with Jina's Vision-Language Model for image understanding.
    ## Supports image analysis, visual QA, and multimodal conversations.
    ## Note: Cold starts may take 30-60 seconds. Retry on 503 errors.
    Tool(
        name: "jina_vlm_chat",
        description: "Chat with Jina VLM for image understanding and multimodal conversations. Supports image URLs, base64 images, and follow-up questions. Note: Cold starts may take 30-60 seconds.",
        parameters: %*{
            "type": "object",
            "properties": {
                "messages": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "role": {
                                "type": "string",
                                "enum": ["user", "assistant"]
                            },
                            "content": {
                                "oneOf": [
                                    {"type": "string"},
                                    {
                                        "type": "array",
                                        "items": {
                                            "type": "object",
                                            "properties": {
                                                "type": {"type": "string", "enum": ["text", "image_url"]},
                                                "text": {"type": "string"},
                                                "image_url": {
                                                    "type": "object",
                                                    "properties": {
                                                        "url": {"type": "string"}
                                                    }
                                                }
                                            }
                                        }
                                    }
                                ]
                            }
                        },
                        "required": ["role", "content"]
                    },
                    "description": "Conversation messages. Images: {'type': 'image_url', 'image_url': {'url': '...'}}"
                },
                "stream": {
                    "type": "boolean",
                    "default": false,
                    "description": "Stream tokens as they are generated"
                },
                "api_key": {
                    "type": "string",
                    "description": "Jina API key (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["messages"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: ""
            
            var body = %*{}
            body["model"] = %"jina-vlm"
            body["messages"] = args["messages"]
            
            if args.hasKey("stream"):
                body["stream"] = args["stream"]
            
            result = await makeJinaRequest(JINA_VLM_URL, body, apiKey)
    )

# -----------------------------------------------------------------------------
# DeepSearch Tool
# -----------------------------------------------------------------------------

proc JinaDeepSearchTool*(): Tool =
    ## Comprehensive web research using Jina DeepSearch API.
    ## Combines searching, reading, and reasoning for thorough investigation.
    ## Note: Supports streaming; non-streaming may timeout on complex queries.
    Tool(
        name: "jina_deepsearch",
        description: "Comprehensive web research combining search, reading, and reasoning. Best for complex investigations requiring multiple sources. Returns reasoning steps and final answer. Note: May take significant time; use streaming for best results.",
        parameters: %*{
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Research query or question to investigate"
                },
                "stream": {
                    "type": "boolean",
                    "default": true,
                    "description": "Stream results as they arrive (recommended to avoid timeouts)"
                },
                "reasoning_effort": {
                    "type": "string",
                    "enum": ["low", "medium", "high"],
                    "description": "Amount of reasoning effort to apply"
                },
                "budget_tokens": {
                    "type": "integer",
                    "description": "Maximum tokens for DeepSearch process (overrides reasoning_effort)"
                },
                "max_attempts": {
                    "type": "integer",
                    "description": "Maximum retries with different reasoning approaches"
                },
                "no_direct_answer": {
                    "type": "boolean",
                    "default": false,
                    "description": "Force deep search even for simple queries"
                },
                "max_returned_urls": {
                    "type": "integer",
                    "description": "Maximum URLs to include in final answer"
                },
                "boost_hostnames": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Domains to prioritize for content retrieval"
                },
                "bad_hostnames": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Domains to exclude from search"
                },
                "only_hostnames": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Only include these domains (all others ignored)"
                },
                "api_key": {
                    "type": "string",
                    "description": "Jina API key (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["query"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: ""
            
            var body = %*{}
            body["model"] = %"jina-deepsearch-v1"
            
            # Convert simple query to messages format
            let messages = %*[{"role": "user", "content": %args["query"].getStr}]
            body["messages"] = messages
            
            if args.hasKey("stream"):
                body["stream"] = args["stream"]
            else:
                body["stream"] = %true
            
            if args.hasKey("reasoning_effort"):
                body["reasoning_effort"] = args["reasoning_effort"]
            if args.hasKey("budget_tokens"):
                body["budget_tokens"] = args["budget_tokens"]
            if args.hasKey("max_attempts"):
                body["max_attempts"] = args["max_attempts"]
            if args.hasKey("no_direct_answer"):
                body["no_direct_answer"] = args["no_direct_answer"]
            if args.hasKey("max_returned_urls"):
                body["max_returned_urls"] = args["max_returned_urls"]
            if args.hasKey("boost_hostnames"):
                body["boost_hostnames"] = args["boost_hostnames"]
            if args.hasKey("bad_hostnames"):
                body["bad_hostnames"] = args["bad_hostnames"]
            if args.hasKey("only_hostnames"):
                body["only_hostnames"] = args["only_hostnames"]
            
            result = await makeJinaRequest(JINA_DEEPSEARCH_URL, body, apiKey)
    )

# -----------------------------------------------------------------------------
# Segmenter Tool
# -----------------------------------------------------------------------------

proc JinaSegmentTool*(): Tool =
    ## Tokenize and segment text using Jina Segmenter API.
    ## Useful for chunking documents for RAG applications.
    Tool(
        name: "jina_segment",
        description: "Tokenize and segment text into chunks. Supports multiple tokenizers (cl100k_base, o200k_base, p50k_base, r50k_base, p50k_edit, gpt2). Useful for RAG chunking. Returns token count, chunks, and token positions.",
        parameters: %*{
            "type": "object",
            "properties": {
                "content": {
                    "type": "string",
                    "description": "Text content to segment and tokenize"
                },
                "tokenizer": {
                    "type": "string",
                    "enum": ["cl100k_base", "o200k_base", "p50k_base", "r50k_base", "p50k_edit", "gpt2"],
                    "default": "cl100k_base",
                    "description": "Tokenizer to use"
                },
                "return_tokens": {
                    "type": "boolean",
                    "default": false,
                    "description": "Include tokens and their IDs in response"
                },
                "return_chunks": {
                    "type": "boolean",
                    "default": false,
                    "description": "Segment text into semantic chunks (required for chunking)"
                },
                "max_chunk_length": {
                    "type": "integer",
                    "default": 1000,
                    "description": "Maximum characters per chunk (requires return_chunks=true)"
                },
                "head": {
                    "type": "integer",
                    "description": "Return first N tokens (exclusive with tail)"
                },
                "tail": {
                    "type": "integer",
                    "description": "Return last N tokens (exclusive with head)"
                },
                "api_key": {
                    "type": "string",
                    "description": "Jina API key (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["content"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: ""
            
            var body = %*{}
            body["content"] = args["content"]
            
            if args.hasKey("tokenizer"):
                body["tokenizer"] = args["tokenizer"]
            else:
                body["tokenizer"] = %"cl100k_base"
            
            if args.hasKey("return_tokens"):
                body["return_tokens"] = args["return_tokens"]
            if args.hasKey("return_chunks"):
                body["return_chunks"] = args["return_chunks"]
            if args.hasKey("max_chunk_length"):
                body["max_chunk_length"] = args["max_chunk_length"]
            if args.hasKey("head"):
                body["head"] = args["head"]
            if args.hasKey("tail"):
                body["tail"] = args["tail"]
            
            result = await makeJinaRequest(JINA_SEGMENT_URL, body, apiKey)
    )

# -----------------------------------------------------------------------------
# Classifier Tool
# -----------------------------------------------------------------------------

proc JinaClassifyTool*(): Tool =
    ## Zero-shot classification for text or images using Jina Classifier API.
    ## Classify inputs into user-defined categories without training.
    Tool(
        name: "jina_classify",
        description: "Zero-shot classification for text or images. For text use 'jina-embeddings-v3', for images use 'jina-clip-v2', for both use 'jina-embeddings-v4'. Classifies inputs into user-provided labels with confidence scores.",
        parameters: %*{
            "type": "object",
            "properties": {
                "input": {
                    "type": "array",
                    "items": {
                        "oneOf": [
                            {"type": "string"},
                            {
                                "type": "object",
                                "properties": {
                                    "text": {"type": "string"},
                                    "image": {"type": "string"}
                                }
                            }
                        ]
                    },
                    "description": "Texts to classify (strings) or images (objects with 'text' or 'image' key). Cannot mix text and image objects."
                },
                "labels": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Categories to classify into (e.g., ['positive', 'negative', 'neutral'])"
                },
                "model": {
                    "type": "string",
                    "enum": ["jina-embeddings-v3", "jina-clip-v2", "jina-embeddings-v4"],
                    "description": "Model: embeddings-v3 (text), clip-v2 (images), embeddings-v4 (both)"
                },
                "classifier_id": {
                    "type": "string",
                    "description": "Existing classifier ID (creates new if not provided)"
                },
                "api_key": {
                    "type": "string",
                    "description": "Jina API key (defaults to JINA_API_KEY env var)"
                }
            },
            "required": ["input", "labels"],
            "additionalProperties": false
        },
        strict: false,
        handler: proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            let apiKey = if args.hasKey("api_key"): args["api_key"].getStr else: ""
            
            var body = %*{}
            body["input"] = args["input"]
            body["labels"] = args["labels"]
            
            if args.hasKey("model"):
                body["model"] = args["model"]
            if args.hasKey("classifier_id"):
                body["classifier_id"] = args["classifier_id"]
            
            result = await makeJinaRequest(JINA_CLASSIFY_URL, body, apiKey)
    )

# -----------------------------------------------------------------------------
# Toolkits
# -----------------------------------------------------------------------------

proc JinaBasicFreeToolkit*(): Toolkit =
    ## Free Jina AI toolkit: Basic Reader (no API key required).
    result = newToolkit("jina_basic_free", "Free Jina AI tools (no API key required)")
    result.add JinaBasicReaderTool()

proc JinaBasicToolkit*(): Toolkit =
    ## Basic Jina AI toolkit: Reader, Search, Embeddings.
    result = newToolkit("jina_basic", "Basic Jina AI Search Foundation tools")
    result.add JinaBasicReaderTool()
    result.add JinaReaderTool()
    result.add JinaSearchTool()
    result.add JinaEmbeddingsTool()

proc JinaRAGToolkit*(): Toolkit =
    ## RAG-focused toolkit: Reader, Embeddings, Reranker, Segmenter.
    result = newToolkit("jina_rag", "Jina AI tools for RAG applications")
    result.add JinaReaderTool()
    result.add JinaEmbeddingsTool()
    result.add JinaRerankTool()
    result.add JinaSegmentTool()

proc JinaMultimodalToolkit*(): Toolkit =
    ## Multimodal toolkit: VLM, Classifier, Embeddings (multimodal).
    result = newToolkit("jina_multimodal", "Jina AI multimodal tools (images + text)")
    result.add JinaVLMChatTool()
    result.add JinaClassifyTool()
    result.add JinaEmbeddingsTool()

proc JinaFullToolkit*(): Toolkit =
    ## Complete Jina AI toolkit with all tools.
    result = newToolkit("jina_full", "Complete Jina AI Search Foundation toolkit")
    result.add JinaEmbeddingsTool()
    result.add JinaReaderTool()
    result.add JinaSearchTool()
    result.add JinaRerankTool()
    result.add JinaVLMChatTool()
    result.add JinaDeepSearchTool()
    result.add JinaSegmentTool()
    result.add JinaClassifyTool()
