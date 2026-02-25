## Moonshot (Kimi) "Official Tools" (Formula tools)
##
## Moonshot official tools are implemented as *Formulas*.
##
## Flow (per Moonshot docs):
## 1) Add tool definitions (type=function) to chat completions request.
## 2) If the model returns tool_calls, execute the corresponding Formula via:
##      POST /formulas/{formula_uri}/fibers
##    with body {"name": <function.name>, "arguments": <json-string>}
## 3) Feed the Formula output back to the model as a role=tool message.
##
## Docs:
## - https://platform.moonshot.ai/docs/guide/use-official-tools

import std/[asyncdispatch, json]

import ../../../harness/tools/base
import ../../kimi/kimi_client

# -----------------------------------------------------------------------------
# Internals
# -----------------------------------------------------------------------------

proc kkOpenSchema(): JsonNode =
  ## A permissive JSON schema for tools where we don't (yet) have a stable
  ## published argument schema.
  %*{
    "type": "object",
    "additionalProperties": true
  }

proc kkRunFormulaFiber(
    client: KimiClient,
    formulaUri: string,
    functionName: string,
    args: JsonNode
): Future[JsonNode] {.async, gcsafe.} =
  ## Execute a Formula tool call and return the value that should be used as the
  ## `role=tool` message content.
  ##
  ## On success, Moonshot returns a Fiber object with `status=succeeded` and the
  ## output typically located at:
  ## - context.output
  ## - OR context.encrypted_output (notably for web-search)
  ##
  ## We return:
  ## - JString for successful outputs (so provider passes raw content to model)
  ## - JObject toolError(...) for failures

  let body = %*{
    "name": functionName,
    # API expects a JSON-encoded string of the arguments
    "arguments": $args
  }

  let endpoint = "/formulas/" & formulaUri & "/fibers"

  var raw: string
  try:
    raw = await client.post(endpoint, body)
  except CatchableError as e:
    return toolError("Formula call failed: " & e.msg)

  var resp: JsonNode
  try:
    resp = parseJson(raw)
  except CatchableError:
    return toolError("Formula call returned non-JSON: " & raw)

  if resp.kind != JObject:
    return toolError("Formula call returned unexpected JSON: " & raw)

  let status = (if resp.hasKey("status"): resp["status"].getStr else: "")
  if status != "succeeded":
    # Prefer top-level error, then context.error
    if resp.hasKey("error"):
      return toolError(resp["error"].getStr)
    if resp.hasKey("context") and resp["context"].kind == JObject:
      let ctx = resp["context"]
      if ctx.hasKey("error"):
        return toolError(ctx["error"].getStr)
    return toolError("Formula call did not succeed (status=" & status & ")")

  if not resp.hasKey("context") or resp["context"].kind != JObject:
    return toolError("Formula call missing context")

  let ctx = resp["context"]

  if ctx.hasKey("output"):
    let outp = ctx["output"]
    if outp.kind == JString:
      # Return output as raw JString for direct pass-through
      return %outp.getStr
    else:
      # If the tool returns structured JSON, stringify it.
      return %($outp)

  if ctx.hasKey("encrypted_output"):
    let outp = ctx["encrypted_output"]
    if outp.kind == JString:
      # Return encrypted content as raw JString so provider passes it through.
      # The model expects the raw encrypted format to process it.
      return %outp.getStr
    else:
      return %($outp)

  return toolError("Formula call succeeded but produced no output")


proc kkFormulaTool*(
    client: KimiClient,
    name: string,
    formulaUri: string,
    description: string,
    parameters: JsonNode = nil
): Tool =
  ## Create a harness Tool that calls a Moonshot Formula tool.
  ##
  ## `name` must match what the model will emit in tool_calls[].function.name.
  result = Tool(
    name: name,
    description: description,
    parameters: (if parameters != nil: parameters else: kkOpenSchema()),
    strict: false,
    handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} =
      return await kkRunFormulaFiber(client, formulaUri, name, args),
    isBuiltIn: false
  )

# -----------------------------------------------------------------------------
# Official tools list (Moonshot namespace)
# -----------------------------------------------------------------------------
# Tool names are from Moonshot's docs "Official Tools List".
# Note: formula URIs use hyphens (e.g. web-search) but tool function names in
# chat tool_calls use underscores (e.g. web_search).

proc kkConvertTool*(client: KimiClient; formulaUri = "moonshot/convert:latest"): Tool =
  kkFormulaTool(
    client = client,
    name = "convert",
    formulaUri = formulaUri,
    description = "Moonshot official convert tool (units + currency)",
    parameters = kkOpenSchema()
  )

proc kkWebSearchTool*(client: KimiClient; formulaUri = "moonshot/web-search:latest"): Tool =
  # From docs sample: required argument is {"query": string}
  let schema = %*{
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "What to search for"
      }
    },
    "required": ["query"]
  }

  kkFormulaTool(
    client = client,
    name = "web_search",
    formulaUri = formulaUri,
    description = "Moonshot official web-search tool",
    parameters = schema
  )

proc kkRethinkTool*(client: KimiClient; formulaUri = "moonshot/rethink:latest"): Tool =
  kkFormulaTool(client, "rethink", formulaUri, "Moonshot official rethink tool", kkOpenSchema())

proc kkRandomChoiceTool*(client: KimiClient; formulaUri = "moonshot/random-choice:latest"): Tool =
  kkFormulaTool(client, "random_choice", formulaUri, "Moonshot official random-choice tool", kkOpenSchema())

proc kkMewTool*(client: KimiClient; formulaUri = "moonshot/mew:latest"): Tool =
  kkFormulaTool(client, "mew", formulaUri, "Moonshot official mew tool", kkOpenSchema())

proc kkMemoryTool*(client: KimiClient; formulaUri = "moonshot/memory:latest"): Tool =
  kkFormulaTool(client, "memory", formulaUri, "Moonshot official memory tool", kkOpenSchema())

proc kkExcelTool*(client: KimiClient; formulaUri = "moonshot/excel:latest"): Tool =
  kkFormulaTool(client, "excel", formulaUri, "Moonshot official excel tool", kkOpenSchema())

proc kkDateTool*(client: KimiClient; formulaUri = "moonshot/date:latest"): Tool =
  kkFormulaTool(client, "date", formulaUri, "Moonshot official date tool", kkOpenSchema())

proc kkBase64Tool*(client: KimiClient; formulaUri = "moonshot/base64:latest"): Tool =
  kkFormulaTool(client, "base64", formulaUri, "Moonshot official base64 tool", kkOpenSchema())

proc kkFetchTool*(client: KimiClient; formulaUri = "moonshot/fetch:latest"): Tool =
  kkFormulaTool(client, "fetch", formulaUri, "Moonshot official fetch tool", kkOpenSchema())

proc kkQuickJsTool*(client: KimiClient; formulaUri = "moonshot/quickjs:latest"): Tool =
  kkFormulaTool(client, "quickjs", formulaUri, "Moonshot official quickjs tool", kkOpenSchema())

proc kkCodeRunnerTool*(client: KimiClient; formulaUri = "moonshot/code_runner:latest"): Tool =
  kkFormulaTool(client, "code_runner", formulaUri, "Moonshot official code runner tool", kkOpenSchema())
