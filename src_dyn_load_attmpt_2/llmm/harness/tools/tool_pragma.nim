## tool_pragma.nim — Zero-boilerplate tool registration for llmm
##
## Usage:
##   proc NimCompileTool*(basePath: string = "."): Tool {.tool.} =
##     Tool(
##       name: "nim_compile",
##       description: "Compile a Nim source file.",
##       parameters: %*{ ... },
##       strict: false,
##       handler: proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.} = ...
##     )
##
## What the macro does:
##   1. Leaves your proc body completely unchanged
##   2. Extracts `name`, `description`, `parameters`, `strict` from the Tool(...)
##      constructor at compile time
##   3. Registers a ToolMeta entry into a module-level seq
##   4. Auto-generates a `listTools*()` proc for the module
##
## For compiled-together mode:
##   Import the module and call `listTools()` to get all metadata.
##   Then call the factory procs directly.
##
## For subprocess mode:
##   The dispatcher generator calls `listTools()` at compile time
##   to know what tools exist and which factory procs to wire up.
##   No comment parsing needed.
##
## Design constraints:
##   - The Tool(...) constructor must be a literal in the proc body
##     (not hidden behind a helper). This is already true in all existing tools.
##   - The macro reads string/bool literals and JsonNode expressions from the AST.
##   - If the macro can't extract a field, it uses sensible defaults.

import std/[macros, json, tables, strformat, options]
import base

type
  ToolMeta* = object
    ## Compile-time metadata extracted from a {.tool.} factory proc.
    name*        : string
    description* : string
    factory*     : string   ## The factory proc name (e.g. "NimCompileTool")
    parameters*  : JsonNode ## The JSON schema, or nil
    strict*      : bool

# ---------------------------------------------------------------------------
# Module-level registry (one per module that uses {.tool.})
# ---------------------------------------------------------------------------
# Each module gets its own `toolRegistry` seq. The auto-generated
# `listTools()` proc returns it. This works because Nim's module
# system gives each file its own scope.

var toolRegistry* {.compileTime.}: seq[tuple[name, factory: string, strict: bool]] = @[]

# ---------------------------------------------------------------------------
# AST Helpers — dig into the proc body to find Tool(...) fields
# ---------------------------------------------------------------------------

proc findToolConstructor(body: NimNode): NimNode =
  ## Recursively search the proc body for a `Tool(...)` object constructor.
  ## Returns the constructor node, or nil if not found.
  case body.kind
  of nnkObjConstr:
    # Check if this is Tool(...)
    if body[0].kind == nnkIdent and $body[0] == "Tool":
      return body
    if body[0].kind == nnkSym and $body[0] == "Tool":
      return body
  of nnkStmtList, nnkStmtListExpr:
    for child in body:
      let found = findToolConstructor(child)
      if found != nil: return found
  of nnkAsgn, nnkLetSection, nnkVarSection:
    for child in body:
      let found = findToolConstructor(child)
      if found != nil: return found
  of nnkIdentDefs:
    for child in body:
      let found = findToolConstructor(child)
      if found != nil: return found
  of nnkReturnStmt:
    if body.len > 0:
      return findToolConstructor(body[0])
  of nnkIfStmt, nnkIfExpr, nnkElifBranch, nnkElse:
    for child in body:
      let found = findToolConstructor(child)
      if found != nil: return found
  of nnkBlockStmt:
    for child in body:
      let found = findToolConstructor(child)
      if found != nil: return found
  else:
    # Walk children generically
    for i in 0 ..< body.len:
      let found = findToolConstructor(body[i])
      if found != nil: return found
  return nil

proc extractStringField(constr: NimNode, fieldName: string): string =
  ## Extract a string literal field from an object constructor.
  ## Tool(name: "foo", ...) -> "foo"
  for i in 1 ..< constr.len:
    let field = constr[i]
    if field.kind == nnkExprColonExpr and field.len >= 2:
      let key = $field[0]
      if key == fieldName:
        if field[1].kind == nnkStrLit:
          return field[1].strVal
        # Handle string concatenation or other expressions — take the literal part
        if field[1].kind == nnkPrefix and field[1].len > 1:
          if field[1][1].kind == nnkStrLit:
            return field[1][1].strVal
  return ""

proc extractBoolField(constr: NimNode, fieldName: string, default: bool = true): bool =
  ## Extract a bool literal field from an object constructor.
  for i in 1 ..< constr.len:
    let field = constr[i]
    if field.kind == nnkExprColonExpr and field.len >= 2:
      let key = $field[0]
      if key == fieldName:
        if field[1].kind == nnkIdent:
          return $field[1] == "true"
  return default

# ---------------------------------------------------------------------------
# The {.tool.} pragma macro
# ---------------------------------------------------------------------------

macro tool*(procDef: untyped): untyped =
  ## Pragma macro for tool factory procs.
  ##
  ## Extracts metadata from the Tool(...) constructor in the proc body
  ## and registers it at compile time. The proc itself is emitted unchanged.
  ##
  ## Example:
  ##   proc MyTool*(basePath: string = "."): Tool {.tool.} =
  ##     Tool(name: "my_tool", description: "Does stuff", ...)

  # Validate: must be a proc definition
  procDef.expectKind(nnkProcDef)

  let procName = $procDef.name

  # Strip the export marker if present to get the bare name
  let factoryName = if procDef.name.kind == nnkPostfix:
    $procDef.name[1]
  else:
    procName

  # Search the proc body for Tool(...)
  let body = procDef.body
  let toolConstr = findToolConstructor(body)

  var toolName = ""
  var strict = true

  if toolConstr != nil:
    toolName = extractStringField(toolConstr, "name")
    strict = extractBoolField(toolConstr, "strict", true)
  else:
    # Fallback: derive tool name from proc name
    # NimCompileTool -> nim_compile_tool
    hint("tool pragma: Could not find Tool(...) constructor in " & factoryName &
         ". Using proc name as tool name.")
    toolName = factoryName

  if toolName.len == 0:
    toolName = factoryName

  # Register at compile time
  toolRegistry.add((name: toolName, factory: factoryName, strict: strict))

  # Emit the proc unchanged (remove the {.tool.} pragma from the output)
  result = procDef

  # Remove the tool pragma from the pragma list so the compiler doesn't complain
  # about an unknown pragma at later stages
  if result.pragma.kind == nnkPragma:
    var newPragma = newNimNode(nnkPragma)
    for p in result.pragma:
      let pName = if p.kind == nnkIdent: $p
                  elif p.kind == nnkCall and p[0].kind == nnkIdent: $p[0]
                  elif p.kind == nnkExprColonExpr and p[0].kind == nnkIdent: $p[0]
                  else: ""
      if pName != "tool":
        newPragma.add p
    if newPragma.len == 0:
      result.pragma = newEmptyNode()
    else:
      result.pragma = newPragma


# ---------------------------------------------------------------------------
# listTools() generator — call this at module scope after all {.tool.} procs
# ---------------------------------------------------------------------------

macro generateToolList*(): untyped =
  var entries = newNimNode(nnkBracket)

  for reg in toolRegistry:
    let n = newLit(reg.name)
    let f = newLit(reg.factory)
    let s = newLit(reg.strict)
    entries.add quote do:
      ToolMeta(
        name: `n`,
        factory: `f`,
        strict: `s`,
        description: "",
        parameters: nil
      )

  result = quote do:
    proc listTools*(): seq[ToolMeta] =
      @`entries`

  toolRegistry.setLen(0)
# ---------------------------------------------------------------------------
# Runtime introspection helpers
# ---------------------------------------------------------------------------

proc getToolMeta*(t: Tool): ToolMeta =
  ## Extract ToolMeta from a constructed Tool object at runtime.
  ## Useful when you have the Tool in hand and want its metadata.
  ToolMeta(
    name: t.name,
    description: t.description,
    factory: "",
    parameters: t.parameters,
    strict: t.strict
  )


# ---------------------------------------------------------------------------
# collectTools — the "just works" runtime helper
# ---------------------------------------------------------------------------
# For compiled-together mode, you often want to just call the factory
# and get both the Tool and its metadata. This helper does that.

type ToolFactory* = proc(basePath: string): Tool

proc collectTools*(factories: openArray[(string, ToolFactory)], basePath: string): seq[Tool] =
  ## Call each factory and collect the resulting Tools.
  ## Usage:
  ##   let tools = collectTools({
  ##     "NimCompileTool": NimCompileTool,
  ##     "NimRunTool": NimRunTool,
  ##   }, basePath = "./workspace")
  for (name, factory) in factories:
    result.add factory(basePath)