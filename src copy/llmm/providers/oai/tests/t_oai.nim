# =============================================================================
# test_oai_suite.nim - Comprehensive test suite for llmm/providers/oai
# =============================================================================

import std/[
unittest
,json
,options
,tables
,strutils
,sequtils
,os
,asyncdispatch
,strformat
]

# If your nimble package exposes "llmm", this should work:
import ../oai

# If the above import doesn't resolve, replace it with a relative import:
# import ../../src/llmm/providers/oai/oai as oai
# export oai

when defined(oai_live):
    import mynimlib/keys

discard """
# Unit tests only (no network)
nim r -d:ssl ./src/llmm/providers/oai/tests/t_oai.nim

# Live tests (will call OpenAI API) - requires mynimlib/keys and valid key
nim r -d:ssl -d:oai_live ./src/llmm/providers/oai/tests/t_oai.nim
"""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

template requireLive() =
    when not defined(oai_live):
        # This template is only meant to be used inside a `when defined(oai_live)` block.
        discard

proc mkClientForTests(): OpenAIClient =
    # Dummy client for unit tests (never calls network)
    newOpenAIClient(
        apiKey = "sk-test"
        ,baseUrl = "https://example.invalid/v1"
    )

# =============================================================================
# UNIT TESTS
# =============================================================================

suite "oai/common/errors":
    test "isApiError detects error envelope":
        let body = """{"error":{"message":"Nope","type":"invalid_request_error","param":null}}"""
        check isApiError(body) == true

    test "isApiError false on normal payload":
        let body = """{"id":"resp_123","object":"response"}"""
        check isApiError(body) == false

    test "parseApiError parses message/type/param":
        let body = """{"error":{"message":"Bad request","type":"invalid_request_error","param":"model"}}"""
        let e = parseApiError(body)
        check e.kind == oekApiError
        check e.message == "Bad request"
        check e.code == "invalid_request_error"
        check e.param == "model"
        check e.raw.len > 0

    test "parseApiError handles invalid json gracefully":
        let body = """{not_json"""
        let e = parseApiError(body)
        check e.kind == oekApiError
        check e.message.len > 0

    test "stringify error formatting":
        let e1 = OaiError(kind: oekNetworkError, message: "timeout")
        check $e1 == "Network error: timeout"

        let e2 = OaiError(kind: oekApiError, message: "nope", code: "invalid_request_error")
        check ($e2).contains("invalid_request_error")

suite "oai/client helpers":
    test "includeQuery produces repeated include= params":
        let q = includeQuery(["a", "b", "c"])
        check q.len == 3
        check q[0][0] == "include"
        check q[0][1] == "a"
        check q[2][1] == "c"

    test "paginationQuery builds only provided params":
        block:
            let q = paginationQuery()
            check q.len == 0
        block:
            let q = paginationQuery(after = "x")
            check q.len == 1
            check q[0] == ("after", "x")
        block:
            let q = paginationQuery(limit = 25, order = "asc")
            check q.len == 2
            check q[0] == ("limit", "25")
            check q[1] == ("order", "asc")
        block:
            let q = paginationQuery(after = "x", limit = 1, order = "desc")
            check q.len == 3

suite "oai/utils/builders":
    test "textInput produces input_text block":
        let j = textInput("hello")
        check j["type"].getStr == "input_text"
        check j["text"].getStr == "hello"

    test "userMessage(string) produces message role user":
        let j = userMessage("hi")
        check j["type"].getStr == "message"
        check j["role"].getStr == "user"
        # content is string node in your implementation
        check j["content"].getStr == "hi"

    test "systemMessage uses developer role (as implemented)":
        let j = systemMessage("rules")
        check j["type"].getStr == "message"
        check j["role"].getStr == "developer"
        check j["content"].getStr == "rules"

    test "imageUrlInput(url, prompt) produces message content array with text + image":
        let j = imageUrlInput(
            "https://example.com/x.png"
            ,prompt = "describe"
            ,detail = "auto"
        )
        check j["type"].getStr == "message"
        check j["role"].getStr == "user"
        check j["content"].kind == JArray
        check j["content"].len == 2
        check j["content"][0]["type"].getStr == "input_text"
        check j["content"][0]["text"].getStr == "describe"
        check j["content"][1]["type"].getStr == "input_image"
        check j["content"][1]["image_url"].getStr == "https://example.com/x.png"

    test "itemReference constructs item_reference":
        let j = itemReference("itm_123")
        check j["type"].getStr == "item_reference"
        check j["id"].getStr == "itm_123"

    test "functionCallOutput constructs function_call_output":
        let j = functionCallOutput("call_1", "ok")
        check j["type"].getStr == "function_call_output"
        check j["call_id"].getStr == "call_1"
        check j["output"].getStr == "ok"

suite "oai/tools/schema builder":
    test "obj basic shape":
        let s = obj().toJson()
        check s["type"].getStr == "object"
        check s.hasKey("properties")

    test "prop adds properties and required without duplicates":
        var s = obj()
            .prop("a", str(), required = true)
            .prop("b", intt(), required = true)
            .prop("a", str(), required = true) # should not double-add required
        let j = s.toJson()
        check j["properties"].hasKey("a")
        check j["properties"].hasKey("b")
        check j["required"].kind == JArray
        var names: seq[string] = @[]
        for r in j["required"]:
            names.add(r.getStr)
        check names.countIt(it == "a") == 1
        check names.countIt(it == "b") == 1

    test "noAdditionalProps sets additionalProperties false":
        let j = obj().strProp("q", "query", required = true).noAdditionalProps().toJson()
        check j["additionalProperties"].getBool == false

    test "array schema includes items":
        let j = arr(str()).minItems(1).maxItems(3).toJson()
        check j["type"].getStr == "array"
        check j["items"]["type"].getStr == "string"
        check j["minItems"].getInt == 1
        check j["maxItems"].getInt == 3

    test "functionTool wrapper produces expected structure":
        let params = obj()
            .strProp("query", "Search query", required = true)
            .intProp("limit", "Limit")
            .noAdditionalProps()

        let tool = functionTool(
            name = "search"
            ,description = "Search stuff"
            ,parameters = params
            ,strict = true
        )

        check tool["type"].getStr == "function"
        check tool["name"].getStr == "search"
        check tool["description"].getStr == "Search stuff"
        check tool["strict"].getBool == true
        check tool["parameters"]["type"].getStr == "object"

suite "oai/responses/utils (extractors)":
    test "extractText(OpenAIResponse) concatenates output_text blocks":
        var resp: OpenAIResponse
        resp.output = @[
            %*{
                "type": "message",
                "content": [
                    {"type": "output_text", "text": "Hello"},
                    {"type": "output_text", "text": "World"}
                ]
            }
        ]
        check resp.extractText == "Hello\nWorld"

    test "extractText(JsonNode) works on raw response json":
        let raw = %*{
            "output": [
                {
                    "type": "message",
                    "content": [
                        {"type": "output_text", "text": "A"},
                        {"type": "output_text", "text": "B"}
                    ]
                }
            ]
        }
        check raw.extractText == "A\nB"

    test "functionCalls parses function_call items and arguments JSON":
        var resp: OpenAIResponse
        resp.output = @[
            %*{
                "type": "function_call",
                "id": "fc_1",
                "call_id": "call_1",
                "name": "add",
                "arguments": """{"a":1,"b":2}"""
            }
        ]
        let fcs = resp.functionCalls
        check fcs.len == 1
        check fcs[0].name == "add"
        check fcs[0].id == "fc_1"
        check fcs[0].callId == "call_1"
        check fcs[0].arguments["a"].getInt == 1
        check fcs[0].arguments["b"].getInt == 2

    test "functionCalls falls back when arguments is not valid json":
        var resp: OpenAIResponse
        resp.output = @[
            %*{
                "type": "function_call",
                "name": "x",
                "arguments": """not_json"""
            }
        ]
        let fcs = resp.functionCalls
        check fcs.len == 1
        check fcs[0].name == "x"
        # fallback stores as string node in your code path
        check fcs[0].arguments.kind in {JString, JObject, JArray}

suite "oai/conversations/utils (extractors)":
    test "extractText(item) concatenates content.text for input/output/text":
        check parseJson(readFile currentSourcePath.parentDir() / "t_resp.json").extractText.startsWith """discard loop.nim - """

    test "ConversationItemList message filters":
        var list: ConversationItemList
        list.objectType = "list"
        list.data = @[
            %*{"type":"message","role":"user","content":[{"type":"input_text","text":"u1"}]},
            %*{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a1"}]},
            %*{"type":"web_search_call","id":"w1"},
            %*{"type":"message","role":"user","content":[{"type":"input_text","text":"u2"}]}
        ]

        check list.messages.len == 3
        check list.userMessages.len == 2
        check list.assistantMessages.len == 1
        check list.toolCalls.len == 1

    test "getLastUserMessage / getLastAssistantMessage":
        var list: ConversationItemList
        list.data = @[
            %*{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a1"}]},
            %*{"type":"message","role":"user","content":[{"type":"input_text","text":"u1"}]},
            %*{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a2"}]}
        ]
        let lastUser = list.getLastUserMessage
        let lastAsst = list.getLastAssistantMessage
        check lastUser.isSome
        check lastUser.get["role"].getStr == "user"
        check lastAsst.isSome
        check lastAsst.get["content"][0]["text"].getStr == "a2"

# =============================================================================
# LIVE INTEGRATION TESTS (guarded by -d:oai_live)
# =============================================================================

when defined(oai_live):
    suite "oai/live integration":
        test "createResponse + getResponse basic roundtrip":
            let client = newOpenAIClient(apiKey = keys.open_ai_api_key)
            defer: client.close()

            const model = "gpt-4o-mini"

            let r1 = waitFor client.createResponse(initCreateResponseOptions(
                model = model
                ,input = %"Say 'pong' only."
                ,store = true
                ,temperature = 0.0
            ))

            check r1.ok
            check r1.id.len > 0
            check r1.model.len > 0
            check r1.status.len > 0
            check r1.text.len > 0

            let respId = r1.id
            let r2 = waitFor client.getResponse(respId)
            check r2.ok
            check r2.id == respId

        test "createConversation + addItem + listItems + deleteConversation":
            let client = newOpenAIClient(apiKey = keys.open_ai_api_key)
            defer:
                client.close()

            # Create conversation with one message
            let c1 = waitFor client.createConversation(initCreateConversationOptions(
                items = @[userMessage("hello from test suite")]
                ,metadata = {"suite": "oai_live"}.toTable
            ))

            check c1.ok
            let convId = c1.id
            check convId.len > 0

            # Add an item
            let added = waitFor client.addItem(convId, userMessage("second message"))
            check added.ok
            check added.val.data.len >= 1

            # List items
            let listed = waitFor client.listItems(convId, limit = 20, order = oDesc)
            check listed.ok
            check listed.count >= 2

            # Delete conversation (cleanup)
            let del = waitFor client.deleteConversation(convId)
            check del.ok
            check del.val.deleted == true
            check del.val.id == convId
