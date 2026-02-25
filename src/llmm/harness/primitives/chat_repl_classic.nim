# =============================================================================
# chat_repl_classic.nim - Stylish interactive chat REPL for llmm agents
# =============================================================================
#
# Replaces the chatRepl section of tick.nim with a rich terminal UI.
# Uses nimsterm for styled output + std/terminal for dimensions.
#
# SQLite-backed persistence: Chat history is persisted via AgentStore.
# On startup, prior sessions can be loaded from the database.
# During the session, chatTurn() handles all DB writes — this file
# only manages display and user interaction.
#
# Slash commands:
#   /help, /paste, /clip, /sh, /!, /history, /dbhistory, /save,
#   /clear, /debug, /stats, /timestamps, /wrap, /width, /cfg,
#   /session (new, list, switch, rename, delete, info),
#   /tools (list, enable, disable, toggle) - runtime tool management
#
# Compile flags:
#   -d:llmm_repl_termui     Enable termui spinner (requires --threads:on)
#   -d:llmm_repl_clipboard  Enable /clip command
#   -d:llmm_repl_debug      Default debug mode ON
#   -d:llmm_repl_stats      Default stats mode ON
#
# =============================================================================

# We import nimsterm for styled output
import nimsterm
import terminal
import std/osproc  # For /sh and /! shell command execution
import std/os      # For getEnv, getCurrentDir, getHomeDir (shell prompt)
import std/algorithm  # For sortedByIt (search results ranking)
import std/sequtils    # For filterIt, count
import std/strutils  # For string manipulation
import std/times     # For DateTime, Duration, now(), format()
import std/strformat # For & string interpolation
import std/tables    # For KV store
import std/options   # For Option, some, none
import std/asyncdispatch  # For async operations

# Job scheduling (background jobs)
import ./jobs/integration
import ./jobs/scheduler
import ./jobs/types as jobtypes
import ./jobs/store as jobstore
import ./jobs/schedule_tool

# Agent store for database operations
import ./store

# Agent type for session management
import ./agent
import ./sessions  # For newChatSession

when defined(llmm_repl_clipboard):
  import libclip/clipboard

when defined(llmm_repl_termui):
  import termui


# =============================================================================
# REPL Configuration & State
# =============================================================================

type
  ReplSettings* = object
    showDebug*      : bool   ## Show tool calls and internal events
    showStats*      : bool   ## Show token/time footer after each response
    showTimestamp*  : bool   ## Show timestamps on messages
    wordWrap*       : bool   ## Word-wrap output to terminal width
    maxWidth*       : int    ## Max content width (0 = auto from terminal)
    theme*          : ReplTheme
    loadHistory*    : bool   ## Load prior chat history from SQLite on startup
    maxHistoryLoad* : int    ## Max number of prior messages to load (0 = all)

  ReplTheme* = object
    ## Color scheme for the REPL. All fields are nimsterm Color values.
    userLabel*      : Color
    userText*       : Color
    assistantLabel* : Color
    assistantText*  : Color
    toolLabel*      : Color
    toolText*       : Color
    errorLabel*     : Color
    errorText*      : Color
    metaText*       : Color
    statText*       : Color
    headerAccent*   : Color
    dividerColor*   : Color
    promptArrow*    : Color
    shellUser*      : Color
    shellPath*      : Color
    shellExitCode*  : Color
    shellMarker*    : Color
    searchMatch*    : Color   ## Highlighted matching chars in /search results

  ReplMessage* = object
    role*      : string   # "user" | "assistant" | "tool" | "error" | "meta"
    name*      : string
    text*      : string
    timestamp* : DateTime
    tokens*    : int
    elapsed*   : Duration

  ReplState* = object
    settings*     : ReplSettings
    history*      : seq[ReplMessage]
    running*      : bool
    lastExitCode* : int    ## Exit code from the last /sh or /! command
    kvStore*      : Table[string, string]  ## Key-value storage for /kv command

# =============================================================================
# Default Theme - Clean dark terminal aesthetic
# =============================================================================

proc defaultTheme*(): ReplTheme =
  ReplTheme(
    userLabel      : cyan
    ,userText      : white
    ,assistantLabel : green
    ,assistantText  : white
    ,toolLabel      : yellow
    ,toolText       : brightBlack
    ,errorLabel     : red
    ,errorText      : red
    ,metaText       : brightBlack
    ,statText       : brightBlack
    ,headerAccent   : cyan
    ,dividerColor   : brightBlack
    ,promptArrow    : cyan
    ,shellUser      : green
    ,shellPath      : cyan
    ,shellExitCode  : red
    ,shellMarker    : white
    ,searchMatch    : yellow
  )

proc defaultSettings*(): ReplSettings =
  ReplSettings(
    showDebug      : defined(llmm_repl_debug)
    ,showStats     : defined(llmm_repl_stats) or true
    ,showTimestamp  : false
    ,wordWrap      : true
    ,maxWidth      : 0
    ,theme         : defaultTheme()
    ,loadHistory   : true
    ,maxHistoryLoad: 100
  )

proc initReplState*(): ReplState =
  ReplState(
    settings : defaultSettings()
    ,history : @[]
    ,running : true
    ,lastExitCode : 0
    ,kvStore : initTable[string, string]()
  )

# =============================================================================
# Terminal Helpers
# =============================================================================

proc getContentWidth(s: ReplSettings): int =
  ## Returns the content width to use for wrapping.
  if s.maxWidth > 0: return s.maxWidth
  let tw = terminalWidth()
  if tw > 10: tw - 4  # Leave some margin
  else: 76             # Safe fallback

proc wrapText*(text: string, width: int, indent: int = 0): string =
  ## Word-wrap text to given width with optional indent.
  ## Respects existing newlines.
  let indentStr = " ".repeat(indent)
  let effectiveWidth = width - indent
  if effectiveWidth <= 10: return text

  var lines: seq[string] = @[]
  for paragraph in text.split('\n'):
    if paragraph.strip().len == 0:
      lines.add ""
      continue

    var currentLine = ""
    for word in paragraph.splitWhitespace():
      if currentLine.len == 0:
        currentLine = word
      elif currentLine.len + 1 + word.len <= effectiveWidth:
        currentLine &= " " & word
      else:
        lines.add(indentStr & currentLine)
        currentLine = word

    if currentLine.len > 0:
      lines.add(indentStr & currentLine)

  result = lines.join("\n")

proc thinDivider(width: int, color: Color = brightBlack) =
  echo $styled("─".repeat(width)).fg(color).style(dim)

proc thickDivider(width: int, color: Color = brightBlack) =
  echo $styled("━".repeat(width)).fg(color)

# =============================================================================
# Formatted Message Printing
# =============================================================================

proc printHeader*(agentName: string, theme: ReplTheme, width: int) =
  ## Print the chat session header.
  echo ""
  let topBar = "╭" & "─".repeat(width - 2) & "╮"
  let botBar = "╰" & "─".repeat(width - 2) & "╯"

  echo $styled(topBar).fg(theme.headerAccent).style(dim)

  let title = &"  💬  Chat with {agentName}"
  let padding = max(0, width - 2 - title.len)
  echo $styled("│").fg(theme.headerAccent).style(dim) &
       $styled(title).fg(theme.headerAccent).style(bold) &
       " ".repeat(padding) &
       $styled("│").fg(theme.headerAccent).style(dim)

  echo $styled(botBar).fg(theme.headerAccent).style(dim)
  echo ""

  # Quick help line
  echo $styled("  Type ").fg(theme.metaText) &
       $styled("/help").fg(cyan).style(bold) &
       $styled(" for commands  •  ").fg(theme.metaText) &
       $styled("exit").fg(cyan).style(bold) &
       $styled(" to quit  •  ").fg(theme.metaText) &
       $styled("paste multi-line directly").fg(theme.metaText)
  echo ""

proc printUserMessage*(msg: string, theme: ReplTheme, width: int, ts: DateTime, showTs: bool) =
  ## Print a user message in styled format.
  let tsStr = if showTs: $styled(" " & ts.format("HH:mm")).fg(theme.metaText).style(dim) else: ""

  echo $styled("  You ").fg(theme.userLabel).style(bold) & tsStr
  let wrapped = wrapText(msg, width, indent = 4)
  for line in wrapped.split('\n'):
    echo $styled(line).fg(theme.userText)
  echo ""

proc printAssistantMessage*(name, msg: string, theme: ReplTheme, width: int,
                            ts: DateTime, showTs: bool, tokens: int, elapsed: Duration,
                            showStats: bool) =
  ## Print an assistant message in styled format.
  let tsStr = if showTs: $styled(" " & ts.format("HH:mm")).fg(theme.metaText).style(dim) else: ""

  echo $styled(&"  {name} ").fg(theme.assistantLabel).style(bold) & tsStr
  let wrapped = wrapText(msg, width, indent = 4)
  for line in wrapped.split('\n'):
    echo $styled(line).fg(theme.assistantText)

  if showStats and (tokens > 0 or elapsed > DurationZero):
    let elapsedMs = elapsed.inMilliseconds
    let statsLine = &"    ⏱ {elapsedMs}ms  •  📊 {tokens} tokens"
    echo $styled(statsLine).fg(theme.statText).style(dim)

  echo ""

proc printToolCall*(toolName, args: string, theme: ReplTheme) =
  ## Print a tool call event (debug mode).
  echo $styled("    ⚡ ").fg(theme.toolLabel) &
       $styled(toolName).fg(theme.toolLabel).style(bold) &
       $styled("(").fg(theme.toolText) &
       $styled(args.substr(0, min(args.len - 1, 80))).fg(theme.toolText).style(dim) &
       $styled(if args.len > 80: "…)" else: ")").fg(theme.toolText)

proc printToolResult*(toolId: string, ok: bool, output: string, theme: ReplTheme) =
  ## Print a tool result event (debug mode).
  let icon   = if ok: "✓" else: "✗"
  let color  = if ok: nimsterm.green else: nimsterm.red  
  let preview = output.substr(0, min(output.len - 1, 60)).replace("\n", " ")
  echo $styled(&"    {icon} ").fg(color) &
       $styled(preview).fg(theme.toolText).style(dim) &
       (if output.len > 60: $styled("…").fg(theme.toolText) else: "")

proc printError*(msg: string, theme: ReplTheme) =
  ## Print an error message.
  echo $styled("  ✗ Error: ").fg(theme.errorLabel).style(bold) &
       $styled(msg).fg(theme.errorText)
  echo ""

proc printMeta*(msg: string, theme: ReplTheme) =
  ## Print a meta/system message.
  echo $styled(&"  ℹ {msg}").fg(theme.metaText).style(dim)
  echo ""

# =============================================================================
# Help Screen
# =============================================================================

proc printHelp*(theme: ReplTheme, width: int) =
  echo ""
  echo $styled("  Commands").fg(theme.headerAccent).style(bold, underline)
  echo ""

  let cmds = @[
    ("/help",              "Show this help"),
    ("/paste",             "Enter paste mode (end with /end)"),
    ("/clip",              "Send clipboard as message"),
    ("/sh <command>",      "Run a shell command (captured output)"),
    ("/! <command>",       "Run interactive shell command (full terminal)"),
    ("/search <query>",    "Fuzzy search chat history"),
    ("/history [n]",       "Show last n exchanges (default 5)"),
    ("/dbhistory [n]",     "Show last n messages from SQLite (all sessions)"),
    ("/jobs",              "List scheduled jobs"),
    ("/job <action> <uid>", "Manage a job: cancel | pause | resume | info"),
    ("/tools",             "Tool management (list, add, remove, reload, create)"),
    ("/kv",                "Key-value store (see /kv --help)"),
    ("/save <path>",       "Save transcript to file"),
    ("/clear",             "Clear screen and reprint header"),
    ("/debug",             "Toggle tool-call visibility"),
    ("/stats",             "Toggle token/time stats"),
    ("/timestamps",        "Toggle timestamps"),
    ("/wrap",              "Toggle word wrapping"),
    ("/width <n>",         "Set max content width (0=auto)"),
    ("/cfg",               "Show current agent + REPL configuration"),
    ("/session",           "Session management (see below)"),
    ("exit / quit / q",    "End session"),
  ]

  for (cmd, desc) in cmds:
    let padded = cmd & " ".repeat(max(1, 24 - cmd.len))
    echo $styled("    ").fg(theme.metaText) &
         $styled(padded).fg(cyan).style(bold) &
         $styled(desc).fg(theme.metaText)

  echo ""
  echo $styled("  Session Commands").fg(theme.headerAccent).style(bold, underline)
  echo ""

  let sessionCmds = @[
    ("/session",              "Show current session info"),
    ("/session list",         "List all sessions"),
    ("/session new [name]",   "Create and switch to a new session"),
    ("/session switch <q>",   "Switch to session by id or name"),
    ("/session rename <name>","Rename current session"),
    ("/session delete <q>",   "Delete a session by id or name"),
  ]

  for (cmd, desc) in sessionCmds:
    let padded = cmd & " ".repeat(max(1, 28 - cmd.len))
    echo $styled("    ").fg(theme.metaText) &
         $styled(padded).fg(cyan).style(bold) &
         $styled(desc).fg(theme.metaText)

  echo ""
  echo $styled("  Tool Commands").fg(theme.headerAccent).style(bold, underline)
  echo ""

  let toolCmds = @[
    ("/tools",                "List all registered tools with status"),
    ("/tools list",           "List all registered tools with status"),
    ("/tools enable <name>",  "Enable one or more tools"),
    ("/tools disable <name>", "Disable one or more tools (confirms if built-in)"),
    ("/tools toggle <name>",  "Toggle enable/disable for one or more tools"),
  ]
  for (cmd, desc) in toolCmds:
    let padded = cmd & " ".repeat(max(1, 28 - cmd.len))
    echo $styled("    ").fg(theme.metaText) &
         $styled(padded).fg(cyan).style(bold) &
         $styled(desc).fg(theme.metaText)

  echo ""
  echo $styled("  KV Store Commands").fg(theme.headerAccent).style(bold, underline)
  echo ""

  let kvCmds = @[
    ("/kv",                            "List all stored keys (values truncated to 100 chars)"),
    ("/kv --help",                     "Show detailed KV help"),
    ("/kv --key <key> --value <val>",  "Store a key-value pair"),
    ("/kv add",                        "Interactive mode: prompts for key, then multi-line value"),
    ("/kv get <key>",                  "Get value for a specific key"),
    ("/kv delete <key>",               "Delete a key"),
    ("/kv clear",                      "Clear all keys"),
  ]

  for (cmd, desc) in kvCmds:
    let padded = cmd & " ".repeat(max(1, 34 - cmd.len))
    echo $styled("    ").fg(theme.metaText) &
         $styled(padded).fg(cyan).style(bold) &
         $styled(desc).fg(theme.metaText)

  echo ""

# =============================================================================
# Shell Prompt & Command Execution
# =============================================================================

proc getShortHome(path: string): string =
  ## Collapse the home directory portion to ~ like a real shell prompt.
  let home = getHomeDir().strip(trailing = true, chars = {DirSep, AltSep})
  if path.startsWith(home):
    result = "~" & path[home.len .. ^1]
  else:
    result = path

proc shellPrompt*(theme: ReplTheme, exitCode: int): string =
  ## Build a shell-style prompt: user@host cwd [exitcode] @#
  ## Exit code bracket is only shown when non-zero (like real shells).
  let user = getEnv("USERNAME", getEnv("USER", "user"))
  when defined(windows):
    let host = getEnv("COMPUTERNAME", "host")
  else:
    let host = getEnv("HOSTNAME", getEnv("HOST", "host"))
  let cwd = getCurrentDir().getShortHome()

  result = $styled(user & "@" & host).fg(theme.shellUser).style(bold) &
           " " &
           $styled(cwd).fg(theme.shellPath).style(bold)

  if exitCode != 0:
    result &= " " & $styled(&"[{exitCode}]").fg(theme.shellExitCode).style(bold)

  result &= " " & $styled("@#").fg(theme.shellMarker).style(bold)

proc runShellCommand*(command: string, theme: ReplTheme, interactive: bool = false, lastExitCode: int = 0): int =
  result = 0

  if command.strip().len == 0:
    printError("Usage: /sh <command>  or  /! <command>", theme)
    return 0

  if interactive:
    echo "  " & shellPrompt(theme, lastExitCode) & " " & $styled(command).fg(theme.toolText)
    try:
      result = execShellCmd(command)
      if result != 0:
        echo $styled(&"  exit code: {result}").fg(theme.errorText).style(dim)
    except OSError, IOError:
      printError(&"Failed to run command: {getCurrentExceptionMsg()}", theme)
      result = 1
  else:
    echo $styled("  $ ").fg(theme.toolLabel).style(bold) &
         $styled(command).fg(theme.toolText)
    try:
      let (output, exitCode) = execCmdEx(command)
      result = exitCode
      if output.len > 0:
        for line in output.strip(trailing = true).split('\n'):
          echo $styled("    " & line).fg(theme.metaText)
      if exitCode != 0:
        echo $styled(&"    exit code: {exitCode}").fg(theme.errorText).style(dim)
    except OSError, IOError:
      printError(&"Failed to run command: {getCurrentExceptionMsg()}", theme)
      result = 1

  echo ""

# =============================================================================
# Fuzzy Search
# =============================================================================

type
  FuzzyResult* = object
    score*   : int
    indices* : seq[int]

  SearchHit* = object
    msgIdx*    : int
    role*      : string
    name*      : string
    text*      : string
    timestamp* : DateTime
    tokens*    : int
    elapsed*   : Duration
    score*     : int
    indices*   : seq[int]
    source*    : string    ## "session" or "db"

proc fuzzyMatchAll*(pattern, haystack: string): FuzzyResult =
  if pattern.len == 0:
    return FuzzyResult(score: 0, indices: @[])

  let pLow = pattern.toLowerAscii()
  let hLow = haystack.toLowerAscii()

  var startPositions: seq[int] = @[]
  for i in 0 ..< hLow.len:
    if hLow[i] == pLow[0]:
      startPositions.add i

  if startPositions.len == 0:
    return FuzzyResult(score: 0, indices: @[])

  const
    bonusConsecutive  = 8
    bonusSeparator    = 10
    bonusFirstChar    = 12
    bonusCaseExact    = 4
    penaltyGap        = -3
    penaltyLeading    = -1
    maxLeadingPenalty = -8

  var bestScore = 0
  var bestIndices: seq[int] = @[]

  for startPos in startPositions:
    var matchIndices: seq[int] = @[]
    var pi = 0
    for hi in startPos ..< hLow.len:
      if pi < pLow.len and hLow[hi] == pLow[pi]:
        matchIndices.add hi
        inc pi
    if pi < pLow.len: continue

    var score = 0
    var prevIdx = startPos - 2

    for i, hi in matchIndices:
      if hi == prevIdx + 1:
        score += bonusConsecutive
      elif i > 0:
        let gap = hi - prevIdx - 1
        score += penaltyGap * gap

      if hi == 0:
        score += bonusFirstChar
      elif hi > 0:
        let prev = haystack[hi - 1]
        if prev in {' ', '_', '-', '/', '\\', '.', ',', ':', ';', '(', '[', '{', '\n'}:
          score += bonusSeparator

      if pattern.len > i and haystack[hi] == pattern[i]:
        score += bonusCaseExact

      prevIdx = hi

    if matchIndices.len > 0:
      let leading = matchIndices[0]
      score += max(penaltyLeading * leading, maxLeadingPenalty)

    if score <= 0: score = 1

    if score > bestScore:
      bestScore = score
      bestIndices = matchIndices

  var occurrences = 0
  var searchPos = 0
  while searchPos <= hLow.len - pLow.len:
    if hLow[searchPos ..< searchPos + pLow.len] == pLow:
      inc occurrences
      searchPos += pLow.len
    else:
      inc searchPos
  if occurrences > 1:
    bestScore += min((occurrences - 1) * 5, 20)

  return FuzzyResult(score: bestScore, indices: bestIndices)

proc highlightMatch*(text: string, indices: seq[int], matchColor: Color, baseColor: Color, maxLen: int = 120): string =
  var flat = text.replace("\n", " ").replace("\r", "")

  var startPos = 0
  var endPos = flat.len
  if flat.len > maxLen and indices.len > 0:
    let center = indices[0]
    startPos = max(0, center - maxLen div 3)
    endPos = min(flat.len, startPos + maxLen)
    if startPos > 0:
      startPos = max(0, startPos)

  let snippet = flat[startPos ..< endPos]
  let prefix = if startPos > 0: "…" else: ""
  let suffix = if endPos < flat.len: "…" else: ""

  var matchSet: set[uint16] = {}
  for idx in indices:
    let adjusted = idx - startPos
    if adjusted >= 0 and adjusted < snippet.len and adjusted <= high(uint16).int:
      matchSet.incl(adjusted.uint16)

  result = prefix
  for i, ch in snippet:
    if i.uint16 in matchSet:
      result &= $styled($ch).fg(matchColor).style(bold)
    else:
      result &= $styled($ch).fg(baseColor)
  result &= suffix

proc searchHistory*(state: ReplState, query: string, agentName: string,
                    agentStore: AgentStore = nil, maxResults: int = 15) =
  let theme = state.settings.theme
  let width = state.settings.getContentWidth()

  if query.strip().len == 0:
    printError("Usage: /search <query>", theme)
    return

  var hits: seq[SearchHit] = @[]

  for i, msg in state.history:
    if msg.role notin ["user", "assistant"]: continue
    let fr = fuzzyMatchAll(query, msg.text)
    if fr.score > 0:
      hits.add SearchHit(
        msgIdx:    i,
        role:      msg.role,
        name:      msg.name,
        text:      msg.text,
        timestamp: msg.timestamp,
        tokens:    msg.tokens,
        elapsed:   msg.elapsed,
        score:     fr.score,
        indices:   fr.indices,
        source:    "session",
      )

  if not agentStore.isNil:
    let rows = agentStore.getChatHistory(500)
    var seenTexts: seq[string] = @[]
    for h in hits:
      seenTexts.add h.text

    for i, row in rows:
      if row.role notin ["user", "assistant"]: continue
      let fr = fuzzyMatchAll(query, row.content)
      if fr.score > 0:
        var isDupe = false
        for seen in seenTexts:
          if seen == row.content:
            isDupe = true
            break
        if isDupe: continue

        var ts = now()
        try:
          ts = parse(row.ts, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
        except CatchableError:
          try:
            ts = parse(row.ts, "yyyy-MM-dd HH:mm:ss", utc())
          except CatchableError:
            discard

        hits.add SearchHit(
          msgIdx:    i,
          role:      row.role,
          name:      if row.role == "assistant": agentName else: "",
          text:      row.content,
          timestamp: ts,
          tokens:    row.tokensUsed,
          elapsed:   initDuration(milliseconds = row.elapsedMs),
          score:     fr.score,
          indices:   fr.indices,
          source:    "db",
        )

  if hits.len == 0:
    printMeta(&"No matches for \"{query}\"", theme)
    return

  hits.sort(proc(a, b: SearchHit): int = cmp(b.score, a.score))

  let showCount = min(maxResults, hits.len)
  let totalCount = hits.len

  echo ""
  printMeta(&"Found {totalCount} matches for \"{query}\" (showing top {showCount}):", theme)
  thinDivider(width, theme.dividerColor)

  for i in 0 ..< showCount:
    let hit = hits[i]
    let ts = hit.timestamp.format("MM-dd HH:mm")
    let roleLabel = case hit.role
      of "user": "You"
      of "assistant": hit.name
      else: hit.role
    let roleColor = case hit.role
      of "user": theme.userLabel
      of "assistant": theme.assistantLabel
      else: theme.metaText
    let sourceTag = if hit.source == "db": $styled(" [db]").fg(theme.metaText).style(dim) else: ""
    let scoreTag = $styled(&" ({hit.score})").fg(theme.statText).style(dim)

    echo $styled(&"  {i+1}. ").fg(theme.metaText) &
         $styled(roleLabel).fg(roleColor).style(bold) &
         $styled(&" {ts}").fg(theme.metaText).style(dim) &
         sourceTag & scoreTag

    let snippet = highlightMatch(hit.text, hit.indices, theme.searchMatch, theme.metaText, maxLen = width - 8)
    echo "     " & snippet
    echo ""

  if totalCount > showCount:
    printMeta(&"...and {totalCount - showCount} more. Refine your query to narrow results.", theme)

  thinDivider(width, theme.dividerColor)
  echo ""

# =============================================================================
# History & Transcript
# =============================================================================

proc printHistory*(state: ReplState, n: int, agentName: string) =
  let theme = state.settings.theme
  let width = state.settings.getContentWidth()
  let count = min(n, state.history.len)
  if count == 0:
    printMeta("No messages in history yet.", theme)
    return

  printMeta(&"Last {count} messages:", theme)
  thinDivider(width, theme.dividerColor)

  for i in (state.history.len - count) ..< state.history.len:
    let msg = state.history[i]
    case msg.role
    of "user":
      printUserMessage(msg.text, theme, width, msg.timestamp, showTs = true)
    of "assistant":
      printAssistantMessage(msg.name, msg.text, theme, width, msg.timestamp,
                            showTs = true, tokens = msg.tokens,
                            elapsed = msg.elapsed, showStats = state.settings.showStats)
    of "error":
      printError(msg.text, theme)
    else:
      printMeta(msg.text, theme)

  thinDivider(width, theme.dividerColor)
  echo ""

proc printDbHistory*(agentStore: AgentStore, n: int, agentName: string, theme: ReplTheme, width: int, showStats: bool) =
  if agentStore.isNil:
    printMeta("No database connected.", theme)
    return

  let rows = agentStore.getChatHistory(n)
  if rows.len == 0:
    printMeta("No messages in database yet.", theme)
    return

  printMeta(&"Last {rows.len} messages from database (all sessions):", theme)
  thinDivider(width, theme.dividerColor)

  for i in countdown(rows.high, 0):
    let row = rows[i]
    var ts = now()
    try:
      ts = parse(row.ts, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
    except CatchableError:
      try:
        ts = parse(row.ts, "yyyy-MM-dd HH:mm:ss", utc())
      except CatchableError:
        discard

    let elapsed = initDuration(milliseconds = row.elapsedMs)

    case row.role
    of "user":
      printUserMessage(row.content, theme, width, ts, showTs = true)
    of "assistant":
      printAssistantMessage(agentName, row.content, theme, width, ts,
                            showTs = true, tokens = row.tokensUsed,
                            elapsed = elapsed, showStats = showStats)
    of "error":
      printError(row.content, theme)
    else:
      printMeta(row.content, theme)

  thinDivider(width, theme.dividerColor)
  echo ""

proc saveTranscript*(state: ReplState, path: string, agentName: string) =
  var md = &"# Chat with {agentName}\n"
  md &= &"_Saved {now().format(\"yyyy-MM-dd HH:mm:ss\")}_\n\n---\n\n"

  for msg in state.history:
    let ts = msg.timestamp.format("HH:mm:ss")
    case msg.role
    of "user":
      md &= &"**You** _{ts}_\n\n{msg.text}\n\n"
    of "assistant":
      md &= &"**{msg.name}** _{ts}_"
      if msg.tokens > 0:
        md &= &" ({msg.tokens} tokens, {msg.elapsed.inMilliseconds}ms)"
      md &= &"\n\n{msg.text}\n\n"
    of "error":
      md &= &"> ⚠️ Error: {msg.text}\n\n"
    else:
      md &= &"_{msg.text}_\n\n"
    md &= "---\n\n"

  writeFile(path, md)

proc saveTranscriptFromDb*(agentStore: AgentStore, path: string, agentName: string, limit: int = 500) =
  if agentStore.isNil:
    raise newException(IOError, "No database connected")

  let rows = agentStore.getChatHistory(limit)
  var md = &"# Chat with {agentName} (Full History)\n"
  md &= &"_Saved {now().format(\"yyyy-MM-dd HH:mm:ss\")}_\n"
  md &= &"_{rows.len} messages from database_\n\n---\n\n"

  for i in countdown(rows.high, 0):
    let row = rows[i]
    let ts = row.ts
    case row.role
    of "user":
      md &= &"**You** _{ts}_\n\n{row.content}\n\n"
    of "assistant":
      md &= &"**{agentName}** _{ts}_"
      if row.tokensUsed > 0:
        md &= &" ({row.tokensUsed} tokens, {row.elapsedMs}ms)"
      md &= &"\n\n{row.content}\n\n"
    of "error":
      md &= &"> ⚠️ Error: {row.content}\n\n"
    else:
      md &= &"_{row.content}_\n\n"
    md &= "---\n\n"

  writeFile(path, md)

# =============================================================================
# SQLite History Loading (session-aware)
# =============================================================================

proc loadHistoryFromDb*(state: var ReplState, agentStore: AgentStore, agentName: string,
                        theme: ReplTheme, width: int, sessionId: string = "") =
  ## Load prior chat history from the AgentStore SQLite database into
  ## the REPL state and display it. Called once at startup or on session switch.
  ##
  ## If sessionId is provided, loads only that session's history.
  ## Otherwise loads all history (backward compatible).
  if agentStore.isNil:
    return

  let limit = if state.settings.maxHistoryLoad > 0: state.settings.maxHistoryLoad else: 500

  let rows = if sessionId.len > 0:
    agentStore.getSessionChatHistory(sessionId, limit)
  else:
    agentStore.getChatHistory(limit)

  if rows.len == 0:
    return

  let scopeLabel = if sessionId.len > 0: "this session" else: "previous sessions"
  printMeta(&"Loading {rows.len} messages from {scopeLabel}...", theme)
  thinDivider(width, theme.dividerColor)

  for i in countdown(rows.high, 0):
    let row = rows[i]

    var ts = now()
    try:
      ts = parse(row.ts, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
    except CatchableError:
      try:
        ts = parse(row.ts, "yyyy-MM-dd HH:mm:ss", utc())
      except CatchableError:
        discard

    let elapsed = initDuration(milliseconds = row.elapsedMs)

    state.history.add ReplMessage(
      role:      row.role,
      name:      if row.role == "assistant": agentName else: "",
      text:      row.content,
      timestamp: ts,
      tokens:    row.tokensUsed,
      elapsed:   elapsed,
    )

    case row.role
    of "user":
      printUserMessage(row.content, theme, width, ts, showTs = true)
    of "assistant":
      printAssistantMessage(agentName, row.content, theme, width, ts,
                            showTs = true, tokens = row.tokensUsed,
                            elapsed = elapsed, showStats = state.settings.showStats)
    of "error":
      printError(row.content, theme)
    else:
      discard

  thinDivider(width, theme.dividerColor)
  printMeta("End of loaded history", theme)
  echo ""

# =============================================================================
# Session Management Commands
# =============================================================================

proc printSessionInfo*(a: Agent, theme: ReplTheme, width: int) =
  ## Display info about the current session.
  let s = a.state.session
  echo ""
  echo $styled("  Current Session").fg(theme.headerAccent).style(bold, underline)
  thinDivider(width, theme.dividerColor)

  proc kv(key, value: string) =
    echo $styled("    " & key & ": ").fg(theme.metaText) &
         $styled(value).fg(theme.userText)

  kv("id", s.id)
  kv("name", s.name)
  kv("created", s.createdAt.format("yyyy-MM-dd HH:mm:ss"))
  kv("messages (in-memory)", $a.state.session.messages.len)

  if not a.state.agentStore.isNil:
    let dbCount = a.state.agentStore.sessionMessageCount(s.id)
    kv("messages (in db)", $dbCount)

  thinDivider(width, theme.dividerColor)
  echo ""

proc printSessionList*(a: Agent, theme: ReplTheme, width: int) =
  ## List all sessions from the database.
  if a.state.agentStore.isNil:
    printMeta("No database connected.", theme)
    return

  let sessions = a.state.agentStore.listSessions(limit = 30)
  if sessions.len == 0:
    printMeta("No sessions found.", theme)
    return

  let currentId = a.state.session.id

  echo ""
  echo $styled("  Sessions").fg(theme.headerAccent).style(bold, underline)
  thinDivider(width, theme.dividerColor)

  for s in sessions:
    let isCurrent = s.sessionId == currentId
    let marker = if isCurrent: "▸ " else: "  "
    let nameColor = if isCurrent: theme.assistantLabel else: theme.userText
    let msgCount = a.state.agentStore.sessionMessageCount(s.sessionId)

    # Parse lastActiveAt for display
    var lastActive = s.lastActiveAt
    if lastActive.len > 19: lastActive = lastActive[0..18]  # Trim to readable

    echo $styled(marker).fg(theme.assistantLabel).style(bold) &
         $styled(s.name).fg(nameColor).style(bold) &
         $styled(&" ({msgCount} msgs)").fg(theme.statText).style(dim) &
         $styled(&"  last: {lastActive}").fg(theme.metaText).style(dim)
    echo $styled(&"    id: {s.sessionId}").fg(theme.metaText).style(dim)

  thinDivider(width, theme.dividerColor)
  echo ""

proc sessionSwitch*(a: Agent, state: var ReplState, idOrName: string, theme: ReplTheme, width: int) =
  ## Switch the agent to a different session by id or name.
  ## Clears in-memory REPL history and reloads from db.
  if a.state.agentStore.isNil:
    printError("No database connected.", theme)
    return

  let found = a.state.agentStore.findSession(idOrName)
  if found.isNone:
    printError(&"Session not found: \"{idOrName}\". Use /session list to see available sessions.", theme)
    return

  let session = found.get

  if session.sessionId == a.state.session.id:
    printMeta(&"Already in session \"{session.name}\".", theme)
    return

  # Switch the agent's session
  a.switchSession(session.sessionId, session.name)

  # Clear REPL state and reload
  state.history = @[]

  printMeta(&"Switched to session \"{session.name}\"", theme)

  # Load this session's history from db
  state.loadHistoryFromDb(a.state.agentStore, a.cfg.name, theme, width, session.sessionId)

proc sessionNew*(a: Agent, state: var ReplState, name: string, theme: ReplTheme, width: int) =
  ## Create a new session and switch to it.
  let newSession = newChatSession(name)

  # Switch the agent
  a.switchSession(newSession.id, newSession.name)

  # Clear REPL state
  state.history = @[]

  printMeta(&"Created and switched to new session \"{newSession.name}\" ({newSession.id})", theme)

proc sessionRename*(a: Agent, newName: string, theme: ReplTheme) =
  ## Rename the current session.
  if newName.strip().len == 0:
    printError("Usage: /session rename <new name>", theme)
    return

  if a.state.agentStore.isNil:
    printError("No database connected.", theme)
    return

  let ok = a.state.agentStore.renameSession(a.state.session.id, newName.strip())
  if ok:
    a.state.session.name = newName.strip()
    printMeta(&"Session renamed to \"{newName.strip()}\"", theme)
  else:
    printError("Failed to rename session.", theme)

proc sessionDelete*(a: Agent, state: var ReplState, idOrName: string, theme: ReplTheme, width: int) =
  ## Delete a session by id or name.
  if a.state.agentStore.isNil:
    printError("No database connected.", theme)
    return

  let found = a.state.agentStore.findSession(idOrName)
  if found.isNone:
    printError(&"Session not found: \"{idOrName}\".", theme)
    return

  let session = found.get
  let isDeletingCurrent = session.sessionId == a.state.session.id

  # Confirm deletion
  echo $styled(&"  ⚠ Delete session \"{session.name}\" and all its messages? (y/N) ").fg(theme.errorLabel).style(bold)
  stdout.flushFile()

  let confirm = stdin.readLine().strip().toLowerAscii()
  if confirm notin ["y", "yes"]:
    printMeta("Deletion cancelled.", theme)
    return

  let ok = a.state.agentStore.deleteSession(session.sessionId, deleteMessages = true)
  if ok:
    printMeta(&"Session \"{session.name}\" deleted.", theme)

    if isDeletingCurrent:
      # Switch to a new session
      sessionNew(a, state, "", theme, width)
  else:
    printError("Failed to delete session.", theme)

proc processSessionCommand*(cmd: string, a: Agent, state: var ReplState, theme: ReplTheme, width: int): bool =
  ## Process /session subcommands. Returns true if handled.
  let parts = cmd.split(" ", maxsplit = 2)
  # parts[0] = "/session"
  let subCmd = if parts.len > 1: parts[1].strip().toLowerAscii() else: ""
  let arg = if parts.len > 2: parts[2].strip() else: ""

  case subCmd
  of "", "info":
    printSessionInfo(a, theme, width)
    return true

  of "list", "ls":
    printSessionList(a, theme, width)
    return true

  of "new", "create":
    sessionNew(a, state, arg, theme, width)
    return true

  of "switch", "sw", "use", "load":
    if arg.len == 0:
      printError("Usage: /session switch <id or name>", theme)
    else:
      sessionSwitch(a, state, arg, theme, width)
    return true

  of "rename", "mv":
    sessionRename(a, arg, theme)
    return true

  of "delete", "rm", "del":
    if arg.len == 0:
      printError("Usage: /session delete <id or name>", theme)
    else:
      sessionDelete(a, state, arg, theme, width)
    return true

  else:
    printError(&"Unknown session command: \"{subCmd}\". Try: list, new, switch, rename, delete", theme)
    return true

# =============================================================================
# =============================================================================
# Tool Management Commands (Runtime Enable/Disable)
# =============================================================================

proc printToolsList*(a: Agent, theme: ReplTheme, width: int) =
  ## Display list of all registered tools with their enabled/disabled status.
  let tools = a.cfg.tools
  
  if tools.len == 0:
    printMeta("No tools registered.", theme)
    return
  
  echo ""
  echo $styled("  Registered Tools").fg(theme.headerAccent).style(bold, underline)
  thinDivider(width, theme.dividerColor)
  
  # Sort tool names for consistent display
  var toolNames: seq[string] = @[]
  for name in tools.keys:
    toolNames.add(name)
  toolNames.sort()
  
  for name in toolNames:
    let tool = tools[name]
    let statusStr = if tool.isEnabled: "[enabled]" else: "[disabled]"
    let statusColor = if tool.isEnabled: theme.assistantLabel else: theme.errorLabel
    let builtInTag = if tool.isBuiltIn: $styled(" [built-in]").fg(theme.toolLabel).style(dim) else: ""
    
    echo $styled("    • ").fg(theme.metaText) &
         $styled(name).fg(theme.userText).style(bold) &
         " " &
         $styled(statusStr).fg(statusColor).style(dim) &
         builtInTag
  
  let enabledCount = toolNames.filterIt(tools[it].isEnabled).len
  thinDivider(width, theme.dividerColor)
  printMeta("Total: " & $tools.len & " tools (" & $enabledCount & " enabled, " & $(tools.len - enabledCount) & " disabled)", theme)
  echo ""

proc setToolEnabled*(a: Agent, toolNames: seq[string], enabled: bool, theme: ReplTheme) =
  ## Enable or disable one or more tools.
  var changed: seq[string] = @[]
  var notFound: seq[string] = @[]
  var alreadySet: seq[string] = @[]
  
  for name in toolNames:
    if not a.cfg.tools.hasKey(name):
      notFound.add(name)
    elif a.cfg.tools[name].isEnabled == enabled:
      alreadySet.add(name)
    else:
      a.cfg.tools[name].isEnabled = enabled
      changed.add(name)
  
  # Report results
  let action = if enabled: "enabled" else: "disabled"
  
  if changed.len > 0:
    printMeta($changed.len & " tool(s) " & action & ": " & changed.join(", "), theme)
  
  if alreadySet.len > 0:
    printMeta($alreadySet.len & " tool(s) already " & action & ": " & alreadySet.join(", "), theme)
  
  if notFound.len > 0:
    printError("Tool(s) not found: " & notFound.join(", "), theme)

proc confirmToolToggle*(a: Agent, toolNames: seq[string], enable: bool, theme: ReplTheme): bool =
  ## Ask user for confirmation before enabling/disabling tools.
  let action = if enable: "enable" else: "disable"
  
  echo $styled(&"  Are you sure you want to {action} these {toolNames.len} tool(s)? (y/N) ").fg(theme.errorLabel).style(bold) &
       $styled(toolNames.join(", ")).fg(theme.userText)
  stdout.flushFile()
  
  let confirm = stdin.readLine().strip().toLowerAscii()
  return confirm in ["y", "yes"]

proc processToolsCommand*(cmd: string, state: var ReplState, a: Agent, theme: ReplTheme, width: int): bool =
  ## Process /tools subcommands. Returns true if handled.
  let parts = cmd.splitWhitespace()
  
  if parts.len == 1:
    # Just /tools - show list
    printToolsList(a, theme, width)
    return true
  
  let subCmd = parts[1].strip().toLowerAscii()
  
  case subCmd
  of "list", "ls":
    printToolsList(a, theme, width)
    return true
  
  of "enable":
    if parts.len < 3:
      printError("Usage: /tools enable <tool1> [tool2] ...", theme)
      return true
    
    let toolNames = parts[2..^1]
    setToolEnabled(a, toolNames, true, theme)
    return true
  
  of "disable":
    if parts.len < 3:
      printError("Usage: /tools disable <tool1> [tool2] ...", theme)
      return true
    
    let toolNames = parts[2..^1]
    # Confirm if disabling multiple tools or built-in tools
    var needsConfirm = false
    for name in toolNames:
      if a.cfg.tools.hasKey(name) and a.cfg.tools[name].isBuiltIn:
        needsConfirm = true
        break
    
    if toolNames.len > 1 or needsConfirm:
      if not confirmToolToggle(a, toolNames, false, theme):
        printMeta("Operation cancelled.", theme)
        return true
    
    setToolEnabled(a, toolNames, false, theme)
    return true
  
  of "toggle":
    if parts.len < 3:
      printError("Usage: /tools toggle <tool1> [tool2] ...", theme)
      return true
    
    let toolNames = parts[2..^1]
    var toggled: seq[string] = @[]
    var notFound: seq[string] = @[]
    
    for name in toolNames:
      if not a.cfg.tools.hasKey(name):
        notFound.add(name)
      else:
        let newState = not a.cfg.tools[name].isEnabled
        a.cfg.tools[name].isEnabled = newState
        toggled.add(name & "->" & (if newState: "enabled" else: "disabled"))
    
    if toggled.len > 0:
      printMeta("Toggled: " & toggled.join(", "), theme)
    if notFound.len > 0:
      printError("Not found: " & notFound.join(", "), theme)
    return true
  
  else:
    printError(&"Unknown /tools command: '{subCmd}'. Try: list, enable, disable, toggle", theme)
    return true

# =============================================================================
# KV Store Commands
# =============================================================================

proc printKVHelp*(theme: ReplTheme, width: int) =
  ## Print detailed help for the /kv command.
  echo ""
  echo $styled("  KV Store - Store and retrieve key-value pairs").fg(theme.headerAccent).style(bold, underline)
  echo ""
  echo $styled("  Usage:").fg(theme.userLabel).style(bold)
  echo ""
  
  let examples = @[
    ("/kv",                       "List all keys with truncated values (100 char limit)"),
    ("/kv --help",                "Show this help message"),
    ("/kv --key mykey --value myvalue",  "Store a simple value"),
    ("/kv --key mykey --value hello world",  "Store value with spaces (no quotes needed)"),
    ("/kv add",                   "Interactive mode - prompts for key then multi-line value"),
    ("/kv get mykey",             "Get the full value for a key"),
    ("/kv delete mykey",          "Delete a specific key"),
    ("/kv clear",                 "Delete all keys"),
  ]
  
  for (cmd, desc) in examples:
    let padded = cmd & " ".repeat(max(1, 36 - cmd.len))
    echo $styled("    ").fg(theme.metaText) &
         $styled(padded).fg(cyan).style(bold) &
         $styled(desc).fg(theme.metaText)
  
  echo ""
  echo $styled("  Notes:").fg(theme.userLabel).style(bold)
  echo $styled("    • Keys are case-sensitive").fg(theme.metaText)
  echo $styled("    • Values can be multi-line in interactive mode").fg(theme.metaText)
  echo $styled("    • Values are truncated to 100 chars when listing").fg(theme.metaText)
  echo $styled("    • Storage is in-memory only (lost on restart)").fg(theme.metaText)
  echo ""

proc truncateValue(value: string; maxLen: int = 100): string =
  ## Truncate value for display, adding ellipsis if needed.
  let clean = value.replace("\n", " ↵ ")
  if clean.len <= maxLen:
    return clean
  return clean[0..<maxLen] & "…"

proc listKV*(state: ReplState, theme: ReplTheme, width: int) =
  ## List all key-value pairs in a table format.
  if state.kvStore.len == 0:
    printMeta("No keys stored. Use /kv --key <key> --value <val> to add one.", theme)
    return
  
  echo ""
  echo $styled("  Stored Keys").fg(theme.headerAccent).style(bold, underline)
  echo ""
  
  # Build table rows
  var rows: seq[seq[string]] = @[]
  var sortedKeys: seq[string] = @[]
  
  for key in state.kvStore.keys:
    sortedKeys.add(key)
  sortedKeys.sort()
  
  for key in sortedKeys:
    let value = state.kvStore[key]
    rows.add(@[key, truncateValue(value)])
  
  # Use nimsterm's simpleTable for clean display
  let headers = @["Key", "Value (truncated)"]
  echo simpleTable(headers, rows)
  echo ""
  printMeta(&"Total: {state.kvStore.len} key(s)", theme)

proc getKV*(state: ReplState, key: string, theme: ReplTheme) =
  ## Get full value for a specific key.
  if not state.kvStore.hasKey(key):
    printError(&"Key not found: '{key}'", theme)
    return
  
  echo ""
  echo $styled(&"  Key: ").fg(theme.metaText) &
       $styled(key).fg(theme.userText).style(bold)
  echo $styled("  Value:").fg(theme.metaText)
  echo ""
  
  let value = state.kvStore[key]
  for line in value.split('\n'):
    echo $styled("    " & line).fg(theme.userText)
  echo ""
  let lineCount = value.count('\n')
  printMeta(&"{value.len} characters, {lineCount} line(s)", theme)

proc deleteKV*(state: var ReplState, key: string, theme: ReplTheme) =
  ## Delete a specific key.
  if not state.kvStore.hasKey(key):
    printError(&"Key not found: '{key}'", theme)
    return
  
  state.kvStore.del(key)
  printMeta(&"Deleted key: '{key}'", theme)

proc clearKV*(state: var ReplState, theme: ReplTheme) =
  ## Clear all keys.
  if state.kvStore.len == 0:
    printMeta("No keys to clear.", theme)
    return
  
  let count = state.kvStore.len
  state.kvStore.clear()
  printMeta(&"Cleared {count} key(s)", theme)

proc interactiveKVAdd*(state: var ReplState, theme: ReplTheme) =
  ## Interactive mode: prompt for key, then multi-line value.
  echo ""
  echo $styled("  📋 Interactive KV Add Mode").fg(theme.headerAccent).style(bold)
  echo $styled("     Enter key (single line):").fg(theme.metaText)
  stdout.write $styled("  key ❯ ").fg(theme.promptArrow).style(bold)
  stdout.flushFile()
  
  let key = stdin.readLine().strip()
  if key.len == 0:
    printError("Key cannot be empty.", theme)
    return
  
  echo ""
  echo $styled("     Enter value (end with /end on its own line):").fg(theme.metaText)
  echo $styled("     ──────────────────────────────────────────").fg(theme.dividerColor)
  
  var lines: seq[string] = @[]
  while true:
    stdout.write $styled("  val ❯ ").fg(theme.promptArrow).style(dim)
    stdout.flushFile()
    let line = stdin.readLine()
    if line.strip() == "/end":
      break
    lines.add(line)
  
  let value = lines.join("\n")
  if value.len == 0:
    printError("Value cannot be empty.", theme)
    return
  
  state.kvStore[key] = value
  echo $styled("     ──────────────────────────────────────────").fg(theme.dividerColor)
  printMeta(&"Stored key '{key}' with {value.len} character(s)", theme)

proc processKVCommand*(cmd: string, state: var ReplState, theme: ReplTheme, width: int): bool =
  ## Process /kv subcommands. Returns true if handled.
  let parts = cmd.splitWhitespace()
  
  # No args - list all keys
  if parts.len == 1:
    listKV(state, theme, width)
    return true
  
  # Check for flags
  var i = 1
  var keyFlag = ""
  var valueFlag = ""
  var positionalArgs: seq[string] = @[]
  
  while i < parts.len:
    let part = parts[i]
    
    if part == "--help" or part == "-h":
      printKVHelp(theme, width)
      return true
    
    elif part == "--key" or part == "-k":
      if i + 1 >= parts.len:
        printError("Missing value for --key flag", theme)
        return true
      keyFlag = parts[i + 1]
      i += 2
    
    elif part == "--value" or part == "-v":
      if i + 1 >= parts.len:
        printError("Missing value for --value flag", theme)
        return true
      # Join all remaining parts as value
      valueFlag = parts[i + 1..^1].join(" ")
      break
    
    elif part.startsWith("-"):
      # Unknown flag
      printError(&"Unknown flag: {part}", theme)
      return true
    
    else:
      # Positional argument
      positionalArgs.add(part)
      i += 1
  
  # Handle --key and --value flags
  if keyFlag.len > 0:
    if valueFlag.len == 0:
      printError("Missing --value flag. Usage: /kv --key <key> --value <value>", theme)
      return true
    state.kvStore[keyFlag] = valueFlag
    printMeta(&"Stored key '{keyFlag}'", theme)
    return true
  
  # Handle positional subcommands
  if positionalArgs.len > 0:
    let subCmd = positionalArgs[0].toLowerAscii()
    
    case subCmd
    of "add":
      interactiveKVAdd(state, theme)
      return true
    
    of "get":
      if positionalArgs.len < 2:
        printError("Usage: /kv get <key>", theme)
      else:
        getKV(state, positionalArgs[1], theme)
      return true
    
    of "delete", "del", "rm":
      if positionalArgs.len < 2:
        printError("Usage: /kv delete <key>", theme)
      else:
        deleteKV(state, positionalArgs[1], theme)
      return true
    
    of "clear":
      clearKV(state, theme)
      return true
    
    of "help":
      printKVHelp(theme, width)
      return true
    
    else:
      # If it looks like a key (no spaces, not a command), treat as get
      if positionalArgs.len == 1 and subCmd.len > 0:
        getKV(state, subCmd, theme)
      else:
        printError(&"Unknown /kv command: '{subCmd}'. Try /kv --help", theme)
      return true
  
  # Default: list all
  listKV(state, theme, width)
  return true

# =============================================================================
# Job scheduling helpers
# =============================================================================

proc formatDelay(secs: int64): string =
  if secs >= 86400 and secs mod 86400 == 0: return &"{secs div 86400} days"
  if secs >= 3600 and secs mod 3600 == 0: return &"{secs div 3600} hours"
  if secs >= 60 and secs mod 60 == 0: return &"{secs div 60} minutes"
  return &"{secs} seconds"

proc formatRecurring(interval: string): string =
  return &"recurring {interval}"

proc tryParseDelaySchedule(input: string): Option[jobtypes.ScheduleSpec] =
  ## Very small built-in parser for:
  ##   - "in N minutes <task>" / "after N minutes <task>" (one-shot delay)
  ##   - "every N minutes <task>" (recurring cron)
  let s = input.strip()
  let low = s.toLowerAscii()
  
  # Handle "in " and "after " patterns (one-shot delay)
  if low.startsWith("in ") or low.startsWith("after "):
    let rest = if low.startsWith("in "): s[3..^1].strip() else: s[6..^1].strip()
    let parts = rest.splitWhitespace()
    if parts.len < 3: return none(jobtypes.ScheduleSpec)

    var n: int
    try:
      n = parseInt(parts[0])
    except:
      return none(jobtypes.ScheduleSpec)

    let unit = parts[1].toLowerAscii()
    var secs: int64
    if unit.startsWith("sec"): secs = n.int64
    elif unit.startsWith("min"): secs = (n * 60).int64
    elif unit.startsWith("hour") or unit in ["hr", "hrs"]: secs = (n * 3600).int64
    elif unit.startsWith("day"): secs = (n * 86400).int64
    else: return none(jobtypes.ScheduleSpec)

    let task = parts[2..^1].join(" ").strip()
    if task.len == 0: return none(jobtypes.ScheduleSpec)

    return some(jobtypes.ScheduleSpec(
      kind: jobtypes.skDelay,
      cronExpr: "",
      delaySeconds: secs,
      recurring: false,
      taskPrompt: task,
      rawInput: s
    ))
  
  # Handle "every " pattern (recurring cron)
  elif low.startsWith("every "):
    let rest = s[6..^1].strip()  # Skip "every "
    let parts = rest.splitWhitespace()
    if parts.len < 3: return none(jobtypes.ScheduleSpec)

    var n: int
    try:
      n = parseInt(parts[0])
    except:
      return none(jobtypes.ScheduleSpec)

    let unit = parts[1].toLowerAscii()
    var cronExpr: string
    
    # Build cron expression based on unit
    if unit.startsWith("min"):
      # Every N minutes: */N * * * *
      cronExpr = &"*/{n} * * * *"
    elif unit.startsWith("hour") or unit in ["hr", "hrs"]:
      # Every N hours: 0 */N * * *
      cronExpr = &"0 */{n} * * *"
    elif unit.startsWith("day"):
      # Every N days: 0 0 */N * *
      cronExpr = &"0 0 */{n} * *"
    else:
      return none(jobtypes.ScheduleSpec)

    let task = parts[2..^1].join(" ").strip()
    if task.len == 0: return none(jobtypes.ScheduleSpec)

    return some(jobtypes.ScheduleSpec(
      kind: jobtypes.skCron,
      cronExpr: cronExpr,
      delaySeconds: 0,
      recurring: true,
      taskPrompt: task,
      rawInput: s
    ))
  
  else:
    return none(jobtypes.ScheduleSpec)

proc jobShortId(uid: string): string =
  if uid.len > 8: uid[0..7] else: uid

proc attachJobHandlers(job: Job, agentName: string, theme: ReplTheme) =
  ## Print job lifecycle events into the REPL as they happen.
  ## NOTE: This is intentionally lightweight (one-liners + small preview).
  if job.isNil: return

  job.onStarting:
    printMeta(&"Job {jobShortId(e.jobId)} starting (run {e.runNumber})", theme)

  job.onCompleted:
    let cacheInfo = if e.cachedTokens > 0: &", {e.cachedTokens} cached" else: ""
    printMeta(&"Job {jobShortId(e.jobId)} completed ({e.elapsedMs}ms, {e.tokensUsed} tokens{cacheInfo}).", theme)
    if e.resultText.len > 0:
      let flat = e.resultText.replace("\n", " ").replace("\r", "")
      let preview = if flat.len > 140: flat[0..139] & "…" else: flat
      echo $styled("    " & preview).fg(theme.metaText).style(dim)
      echo ""

  job.onFailed:
    printError(&"Job {jobShortId(e.jobId)} failed: {e.errorMessage}", theme)

  job.onCancelled:
    printMeta(&"Job {jobShortId(e.jobId)} cancelled.", theme)

  job.onPaused:
    printMeta(&"Job {jobShortId(e.jobId)} paused.", theme)

  job.onResumed:
    printMeta(&"Job {jobShortId(e.jobId)} resumed.", theme)
# =============================================================================
# Input Handling (reused from tick.nim patterns)
# =============================================================================

const
  BpEnable  = "\x1b[?2004h"
  BpDisable = "\x1b[?2004l"
  BpStart   = "\x1b[200~"
  BpEnd     = "\x1b[201~"

when defined(windows):
  proc kbhit(): cint {.importc: "_kbhit", header: "<conio.h>".}
  proc getch(): cint {.importc: "_getch", header: "<conio.h>".}

  proc replReadPasteAware*(timeoutMs: int = 50): string =
    result = stdin.readLine()
    while true:
      sleep(timeoutMs)
      if kbhit() == 0: break
      result.add "\n" & stdin.readLine()
else:
  import std/selectors

  proc replReadPasteAware*(timeoutMs: int = 50): string =
    result = stdin.readLine()
    let sel = newSelector[int]()
    sel.registerHandle(stdin.getFileHandle().int, {Read}, 0)
    defer: sel.close()
    while true:
      let ready = sel.select(timeoutMs)
      if ready.len == 0: break
      result.add "\n" & stdin.readLine()

proc replEnableBracketedPaste() =
  stdout.write BpEnable
  stdout.flushFile()

proc replDisableBracketedPaste() =
  stdout.write BpDisable
  stdout.flushFile()

proc replReadBlock(): string =
  var line = stdin.readLine()
  if line.contains(BpStart):
    var lines: seq[string] = @[]
    line = line.replace(BpStart, "")
    while true:
      if line.contains(BpEnd):
        lines.add line.replace(BpEnd, "")
        break
      lines.add line
      line = stdin.readLine()
    return lines.join("\n")
  return line

proc readUserInput(): string =
  ## Read a line while pumping asyncdispatch.poll() so background jobs keep running.
  when defined(windows):
    var buf = ""
    while true:
      asyncdispatch.poll(50)
      if kbhit() != 0:
        let ch = getch().int
        case ch
        of 13, 10:
          echo ""
          return buf
        of 8:
          if buf.len > 0:
            buf.setLen(buf.len - 1)
            stdout.write "\b \b"
            stdout.flushFile()
        else:
          if ch >= 32:
            let c = chr(ch)
            buf.add c
            stdout.write $c
            stdout.flushFile()
  else:
    let sel = newSelector[int]()
    sel.registerHandle(stdin.getFileHandle().int, {Read}, 0)
    defer: sel.close()
    while true:
      asyncdispatch.poll(0)
      let ready = sel.select(50)
      asyncdispatch.poll(0)
      if ready.len > 0:
        return replReadBlock()

# =============================================================================
# Prompt
# =============================================================================

proc showPrompt*(theme: ReplTheme, lastExitCode: int = 0) =
  echo "  " & shellPrompt(theme, lastExitCode)
  stdout.write $styled("  ❯ ").fg(theme.promptArrow).style(bold)
  stdout.flushFile()

# =============================================================================
# Waiting / Thinking Indicator
# =============================================================================

proc replWaitForTurn*(a: Agent, fut: Future[TickResult], theme: ReplTheme): TickResult =
  ## Wait for a chat turn to complete, with visual feedback and error handling.
  ## Catches exceptions from the async operation and converts them to error results.
  
  when defined(llmm_repl_termui):
    let spinner = termuiSpinner(&"{a.cfg.name} is thinking...")
    while not fut.finished:
      asyncdispatch.poll(50)
    
    # Check if the future failed with an exception
    if fut.failed:
      let ex = fut.readError()
      spinner.fail(ex.msg)
      # Return an error result
      return TickResult(
        events: @[],
        text: "",
        toolCalls: @[],
        toolResults: @[],
        tokensUsed: 0,
        elapsed: initDuration(seconds = 0),
        done: false,
        error: some(&"Connection error: {ex.msg}")
      )
    
    let res = fut.read()
    if res.error.isSome:
      spinner.fail(res.error.get())
    else:
      spinner.complete("Done")
    return res
  
  else:
    stdout.write $styled(&"{a.cfg.name} is thinking").fg(theme.metaText).style(dim)
    stdout.flushFile()
    var dots = 0
    while not fut.finished:
      asyncdispatch.poll(100)
      dots = (dots + 1) mod 4
      stdout.write "\r"
      stdout.write $styled(&"{a.cfg.name} is thinking" & ".".repeat(dots) & " ".repeat(3 - dots)).fg(theme.metaText).style(dim)
      stdout.flushFile()

    stdout.write "\r"
    stdout.eraseLine()
    stdout.flushFile()
    
    # Check if the future failed with an exception
    if fut.failed:
      let ex = fut.readError()
      # Return an error result
      return TickResult(
        events: @[],
        text: "",
        toolCalls: @[],
        toolResults: @[],
        tokensUsed: 0,
        elapsed: initDuration(seconds = 0),
        done: false,
        error: some(&"Connection error: {ex.msg}")
      )
    
    return fut.read()

# =============================================================================
# Process TickResult into display
# =============================================================================

proc displayTickResult*(res: TickResult, agentName: string, state: var ReplState) =
  let theme = state.settings.theme
  let width = state.settings.getContentWidth()

  if state.settings.showDebug and res.toolCalls.len > 0:
    echo ""
    echo $styled("    ── Tools ──").fg(theme.toolLabel).style(dim)
    for i, ev in res.events:
      case ev.kind
      of aekToolCall:
        printToolCall(ev.callToolName, $ev.callToolArgs, theme)
      of aekToolResult:
        let ok = ev.resultOk
        printToolResult(ev.resultToolId, ok, $ev.resultOutput, theme)
      else:
        discard
    echo $styled("    ───────────").fg(theme.toolLabel).style(dim)
    echo ""

  if res.error.isSome:
    printError(res.error.get(), theme)
    state.history.add ReplMessage(
      role: "error", text: res.error.get(), timestamp: now()
    )
  elif res.text.len > 0:
    printAssistantMessage(
      agentName, res.text, theme, width,
      ts = now(), showTs = state.settings.showTimestamp,
      tokens = res.tokensUsed, elapsed = res.elapsed,
      showStats = state.settings.showStats
    )
    state.history.add ReplMessage(
      role: "assistant", name: agentName, text: res.text,
      timestamp: now(), tokens: res.tokensUsed, elapsed : res.elapsed
    )

# =============================================================================
# Config Display
# =============================================================================

proc printCfg*(cfg: AgentConfig, state: ReplState, sessionName: string = "", sessionId: string = "") =
  ## Print current agent + REPL configuration.
  let theme = state.settings.theme
  let width = state.settings.getContentWidth()

  proc kv(key, value: string) =
    echo $styled("    " & key & ": ").fg(theme.metaText) &
         $styled(value).fg(theme.userText)

  echo ""
  echo $styled("  Current configuration").fg(theme.headerAccent).style(bold, underline)
  thinDivider(width, theme.dividerColor)

  echo $styled("  Agent").fg(theme.assistantLabel).style(bold)
  kv("name", cfg.name)
  kv("id", cfg.id)
  if cfg.role.len > 0: kv("role", cfg.role)
  kv("model", cfg.model)
  kv("workspaceDir", cfg.workspaceDir)
  kv("dbPath", cfg.dbPath)
  kv("enableReflection", $cfg.enableReflection)
  if cfg.instructions.len > 0: kv("instructions", $cfg.instructions.len & " chars")
  if cfg.systemPrompt.len > 0: kv("systemPrompt", $cfg.systemPrompt.len & " chars")

  var toolNames: seq[string] = @[]
  for k in cfg.tools.keys: toolNames.add k
  toolNames.sort()
  kv("tools", if toolNames.len > 0: toolNames.join(", ") else: "(none)")
  kv("toolCount", $toolNames.len)
  
  
  echo ""

  echo $styled("  Session").fg(theme.assistantLabel).style(bold)
  if sessionId.len > 0: kv("sessionId", sessionId)
  if sessionName.len > 0: kv("sessionName", sessionName)
  echo ""

  echo $styled("  Policy").fg(theme.assistantLabel).style(bold)
  kv("maxToolCalls", $cfg.policy.maxToolCalls)
  kv("maxTokens", if cfg.policy.maxTokens > 0: $cfg.policy.maxTokens else: "(unset)")
  kv("timeout", if cfg.policy.timeout > initDuration(seconds = 0): $cfg.policy.timeout else: "none")
  kv("allowedTools", if cfg.policy.allowedTools.len > 0: cfg.policy.allowedTools.join(", ") else: "(all)")
  kv("hitlEvery", $cfg.policy.hitlEvery)
  kv("requireCheckpoints", $cfg.policy.requireCheckpoints)
  echo ""

  echo $styled("  Knowledge").fg(theme.assistantLabel).style(bold)
  kv("chunkerKind", $cfg.knowledgeConfig.chunkerKind)
  kv("maxChunkChars", $cfg.knowledgeConfig.maxChunkChars)
  kv("chunkOverlap", $cfg.knowledgeConfig.chunkOverlap)
  kv("embeddingModel", cfg.knowledgeConfig.embeddingModel)
  kv("embeddingDim", $cfg.knowledgeConfig.embeddingDim)
  kv("embeddingBatch", $cfg.knowledgeConfig.embeddingBatch)
  kv("vectorExtPath", if cfg.knowledgeConfig.vectorExtPath.len > 0: cfg.knowledgeConfig.vectorExtPath else: "(default)")
  kv("duplicateIngestPolicy", $cfg.knowledgeConfig.duplicateIngestPolicy)
  kv("searchOversample", $cfg.knowledgeConfig.searchOversample)
  echo ""

  echo $styled("  REPL").fg(theme.assistantLabel).style(bold)
  kv("showDebug", $state.settings.showDebug)
  kv("showStats", $state.settings.showStats)
  kv("showTimestamp", $state.settings.showTimestamp)
  kv("wordWrap", $state.settings.wordWrap)
  kv("maxWidth", $state.settings.maxWidth)
  kv("loadHistory", $state.settings.loadHistory)
  kv("maxHistoryLoad", $state.settings.maxHistoryLoad)
  

  thinDivider(width, theme.dividerColor)
  echo ""

# =============================================================================
# Command Processing (slash prefix)
# =============================================================================

proc processCommand*(cmd: string, state: var ReplState, agentName: string,
                     agentStore: AgentStore = nil, agent: Agent = nil,
                     sched: AgentScheduler = nil): bool =
  ## Process a REPL slash command. Returns true if the command was handled.
  let parts = cmd.split(" ", maxsplit = 1)
  let command = parts[0].toLowerAscii()
  let arg = if parts.len > 1: parts[1].strip() else: ""
  let theme = state.settings.theme
  let width = state.settings.getContentWidth()

  case command
  of "/help":
    printHelp(theme, width)
    return true

  of "/paste":
    return false  # Handled by caller

  of "/clip":
    return false  # Handled by caller

  of "/sh":
    state.lastExitCode = runShellCommand(arg, theme, interactive = false, lastExitCode = state.lastExitCode)
    return true

  of "/search":
    searchHistory(state, arg, agentName, agentStore)
    return true

  of "/history":
    let n = if arg.len > 0: (try: parseInt(arg) except: 5) else: 5
    printHistory(state, n, agentName)
    return true

  of "/dbhistory":
    let n = if arg.len > 0: (try: parseInt(arg) except: 20) else: 20
    printDbHistory(agentStore, n, agentName, theme, width, state.settings.showStats)
    return true

  of "/save":
    if arg.len == 0:
      printError("Usage: /save <filepath>  or  /save db <filepath>", theme)
    elif arg.startsWith("db "):
      let dbPath = arg[3..^1].strip()
      if dbPath.len == 0:
        printError("Usage: /save db <filepath>", theme)
      else:
        try:
          saveTranscriptFromDb(agentStore, dbPath, agentName)
          printMeta(&"Full database transcript saved to {dbPath}", theme)
        except:
          printError(&"Failed to save: {getCurrentExceptionMsg()}", theme)
    else:
      try:
        saveTranscript(state, arg, agentName)
        printMeta(&"Transcript saved to {arg}", theme)
      except:
        printError(&"Failed to save: {getCurrentExceptionMsg()}", theme)
    return true

  of "/clear":
    eraseScreen(stdout)
    setCursorPos(stdout, 0, 0)
    printHeader(agentName, theme, width)
    return true

  of "/debug":
    state.settings.showDebug = not state.settings.showDebug
    let status = if state.settings.showDebug: "ON" else: "OFF"
    printMeta(&"Debug mode: {status}", theme)
    return true

  of "/stats":
    state.settings.showStats = not state.settings.showStats
    let status = if state.settings.showStats: "ON" else: "OFF"
    printMeta(&"Stats display: {status}", theme)
    return true

  of "/timestamps":
    state.settings.showTimestamp = not state.settings.showTimestamp
    let status = if state.settings.showTimestamp: "ON" else: "OFF"
    printMeta(&"Timestamps: {status}", theme)
    return true

  of "/wrap":
    state.settings.wordWrap = not state.settings.wordWrap
    let status = if state.settings.wordWrap: "ON" else: "OFF"
    printMeta(&"Word wrap: {status}", theme)
    return true

  of "/width":
    if arg.len == 0:
      printMeta(&"Current width: {state.settings.getContentWidth()}", theme)
    else:
      state.settings.maxWidth = try: parseInt(arg) except: 0
      printMeta(&"Max width set to: {state.settings.getContentWidth()}", theme)
    return true

  of "/jobs":
    if sched.isNil:
      printError("Job scheduler not initialized.", theme)
    else:
      let rows = sched.jobStore.getAllJobs(sched.agentId, limit = 200)
      if rows.len == 0:
        printMeta("No jobs.", theme)
      else:
        printMeta(&"Jobs ({rows.len}):", theme)
        for row in rows:
          var nextAt = if row.nextRunAt.len > 0: row.nextRunAt else: "(none)"
          var lastAt = if row.lastRunAt.len > 0: row.lastRunAt else: "(never)"
          if nextAt.len > 19 and nextAt != "(none)": nextAt = nextAt[0..18]
          if lastAt.len > 19 and lastAt != "(never)": lastAt = lastAt[0..18]

          let task = if row.taskPrompt.len > 70: row.taskPrompt[0..69] & "…" else: row.taskPrompt
          let err  = if row.lastError.len > 0:
                        (if row.lastError.len > 80: row.lastError[0..79] & "…" else: row.lastError)
                     else: ""

          echo $styled(&"    {row.uid}  {row.status}/{row.scheduleKind}  runs: {row.runCount}").fg(theme.metaText).style(dim)
          echo $styled(&"      next: {nextAt}   last: {lastAt}").fg(theme.metaText).style(dim)
          echo $styled(&"      task: {task}").fg(theme.metaText)
          if err.len > 0:
            echo $styled(&"      err : {err}").fg(theme.errorText).style(dim)
          echo ""
    return true

  of "/job":
    if sched.isNil:
      printError("Job scheduler not initialized.", theme)
      return true

    let p = arg.splitWhitespace()
    if p.len < 2:
      printError("Usage: /job cancel|pause|resume|info <uid>", theme)
      return true

    let action = p[0].toLowerAscii()
    let uid = p[1]

    case action
    of "cancel", "c", "rm", "del":
      sched.cancelJob(uid)
      printMeta(&"Cancel requested for job {uid}", theme)

    of "pause", "p":
      sched.pauseJob(uid)
      printMeta(&"Pause requested for job {uid}", theme)

    of "resume", "r":
      sched.resumeJob(uid)
      printMeta(&"Resume requested for job {uid}", theme)

    of "info", "show":
      let opt = sched.jobStore.getByUid(uid)
      if opt.isNone:
        printError(&"Job not found: {uid}", theme)
      else:
        let row = opt.get
        printMeta(&"Job {row.uid}:", theme)
        echo $styled(&"    status      : {row.status}").fg(theme.metaText).style(dim)
        echo $styled(&"    kind        : {row.scheduleKind}").fg(theme.metaText).style(dim)
        echo $styled(&"    created     : {row.createdAt}").fg(theme.metaText).style(dim)
        echo $styled(&"    lastRunAt   : {row.lastRunAt}").fg(theme.metaText).style(dim)
        echo $styled(&"    nextRunAt   : {row.nextRunAt}").fg(theme.metaText).style(dim)
        echo $styled(&"    runCount    : {row.runCount}").fg(theme.metaText).style(dim)
        if row.lastError.len > 0:
          echo $styled(&"    lastError   : {row.lastError}").fg(theme.errorText).style(dim)
        echo $styled(&"    task        : {row.taskPrompt}").fg(theme.metaText)
        echo ""

    else:
      printError(&"Unknown /job action: {action}. Try: cancel, pause, resume, info", theme)

    return true

  of "/session":
    if not agent.isNil:
      return processSessionCommand(cmd, agent, state, theme, width)
    else:
      printError("Session management not available (agent reference missing).", theme)
      return true
  
  of "/tools":
    if not agent.isNil:
      return processToolsCommand(cmd, state, agent, theme, width)
    else:
      printError("Tool management not available (agent reference missing).", theme)
      return true
  
  of "/kv":
    return processKVCommand(cmd, state, theme, width)

  else:
    # Handle /! shorthand — interactive mode (full terminal handover)
    if command.startsWith("/!"):
      let shCmd = if command == "/!": arg
                  else: command[2..^1] & (if arg.len > 0: " " & arg else: "")
      state.lastExitCode = runShellCommand(shCmd, theme, interactive = true, lastExitCode = state.lastExitCode)
      return true

    return false  # Not a recognized command

# =============================================================================
# Main Chat REPL (upgraded with SQLite support + slash commands + sessions)
# =============================================================================

proc chatRepl*(a: Agent, firstMsg: string = "", settings: ReplSettings = defaultSettings()) =
  ## Opens a rich interactive chat REPL with the agent.
  ##
  ## Features:
  ##   - SQLite-backed chat history (loads prior sessions, persists via chatTurn)
  ##   - Session management (/session new, list, switch, rename, delete)
  ##   - Runtime tool enable/disable (/tools enable, disable, toggle)
  ##   - Styled message display with word wrapping
  ##   - Tool call visibility (toggle with /debug)
  ##   - Token/time stats (toggle with /stats)
  ##   - Shell command execution (/sh or /!)
  ##   - Chat history (/history / /dbhistory), transcript saving (/save / /save db)
  ##   - Multi-line paste support (bracketed paste + /paste mode)
  ##   - Animated thinking indicator
  ##   - Customizable theme and settings

  var state = initReplState()
  state.settings = settings

  let theme = state.settings.theme
  let width = state.settings.getContentWidth()

  # Grab the AgentStore handle for DB operations
  let agentStore = a.state.agentStore

  # Job scheduler (runs via asyncdispatch.poll in the input loop)
  var sched: AgentScheduler = nil
  try:
    sched = initScheduler(a)
    asyncCheck sched.startScheduler()
    for j in scheduler.listJobs(sched):
      attachJobHandlers(j, a.cfg.name, theme)
  except CatchableError as ex:
    sched = nil
    printError(&"Job scheduler init failed: {ex.msg}", theme)

  # Register the schedule tool so LLM can use it for complex scheduling
  if not sched.isNil:
    if a.cfg.knowledgeConfig.client.isNil:
      icy "ScheduleTool not registered - no OpenAI client configured in knowledgeConfig"
    else:
      a.addTools ScheduleTool(sched, a.cfg.knowledgeConfig.client)


  # Print header
  printHeader(a.cfg.name, theme, width)

  # Show current session info
  printMeta(&"Session: \"{a.state.session.name}\" ({a.state.session.id})", theme)

  # Load prior chat history from SQLite for this session if enabled
  if state.settings.loadHistory and not agentStore.isNil:
    state.loadHistoryFromDb(agentStore, a.cfg.name, theme, width, a.state.session.id)

  replEnableBracketedPaste()
  defer: replDisableBracketedPaste()

  # Handle firstMsg if provided
  if firstMsg.len > 0:
    printUserMessage(firstMsg, theme, width, now(), state.settings.showTimestamp)
    state.history.add ReplMessage(
      role: "user", text: firstMsg, timestamp: now()
    )

    let fut = a.chatTurn(firstMsg)
    let res = replWaitForTurn(a, fut, theme)
    displayTickResult(res, a.cfg.name, state)

  # Main loop
  while state.running:
    showPrompt(theme, state.lastExitCode)

    var raw: string
    try:
      raw = readUserInput()
    except EOFError:
      echo ""
      break

    let cmd = raw.strip()
    let low = cmd.toLowerAscii()

    # Exit
    if low in ["exit", "quit", "q"]:
      echo ""
      echo $styled("  👋 Session ended.").fg(theme.metaText)
      if state.history.len > 0:
        echo $styled(&"     {state.history.len} messages exchanged.").fg(theme.metaText).style(dim)
      echo ""
      break

    # Empty input
    if cmd.len == 0:
      continue

    # Slash commands
    if cmd.startsWith("/"):
      if low == "/cfg":
        printCfg(a.cfg, state, a.state.session.name, a.state.session.id)
        continue

      if processCommand(cmd, state, a.cfg.name, agentStore, a, sched):
        continue

      # Handle /paste specially
      if low == "/paste":
        echo $styled("  📋 Paste mode — end with /end").fg(theme.metaText).style(dim)
        var lines: seq[string] = @[]
        while true:
          let line = stdin.readLine()
          if line.strip() == "/end": break
          lines.add line
        raw = lines.join("\n")
        if raw.strip().len == 0: continue

      # Handle /clip
      elif low == "/clip":
        when defined(llmm_repl_clipboard):
          raw = getClipboardText()
        else:
          printError("Clipboard not compiled. Rebuild with -d:llmm_repl_clipboard", theme)
          continue

      # Unknown slash command
      else:
        let parts = cmd.split(" ", maxsplit = 1)
        printError(&"Unknown command: {parts[0]}. Type /help for available commands.", theme)
        continue

    let userMsg = raw.strip()
    if userMsg.len == 0:
      continue

    # Display user message
    printUserMessage(userMsg, theme, width, now(), state.settings.showTimestamp)
    state.history.add ReplMessage(
      role: "user", text: userMsg, timestamp: now()
    )

    # Scheduling shortcuts: "in 2 minutes <task>" or "every 2 minutes <task>"
    if not sched.isNil:
      let specOpt = tryParseDelaySchedule(userMsg)
      if specOpt.isSome:
        let spec = specOpt.get
        let job = sched.scheduleSpec(spec, scheduleDesc = userMsg)
        attachJobHandlers(job, a.cfg.name, theme)
        
        # Generate appropriate response based on schedule type
        let reply = if spec.recurring:
          &"OK — I'll do that {formatRecurring(spec.cronExpr)}. (job {job.uid})"
        else:
          &"OK — I'll do that in {formatDelay(spec.delaySeconds)}. (job {job.uid})"
        
        printAssistantMessage(a.cfg.name, reply, theme, width, ts = now(),
                            showTs = state.settings.showTimestamp,
                            tokens = 0, elapsed = DurationZero,
                            showStats = false)
        state.history.add ReplMessage(role: "assistant", name: a.cfg.name, text: reply, timestamp: now())
        continue

    # Execute chat turn — chatTurn() handles all SQLite persistence
    let fut = a.chatTurn(userMsg)
    let res = replWaitForTurn(a, fut, theme)
    displayTickResult(res, a.cfg.name, state)


proc feedback*(a: Agent, firstMsg: string = "") =
  ## Opens a feedback-focused chat REPL with memory priority.
  const feedbackPrefix = """
## IMPORTANT: User Feedback Session

The user is providing direct feedback. This information is HIGH PRIORITY and should be stored in memory.

For EVERY piece of feedback the user shares:
1. Acknowledge it
2. Store it using the memory tool with source: "correction" or "user_preference" and kind: "fact" or "lesson" as appropriate
3. Confirm what you stored

Treat everything in this session as important context to remember for future interactions.
"""

  let originalPrompt = a.cfg.systemPrompt
  a.cfg.systemPrompt = a.cfg.systemPrompt & "\n\n" & feedbackPrefix

  var settings = defaultSettings()
  settings.showStats = true
  settings.showDebug = true

  echo ""
  echo $styled("  📝 Feedback Session").fg(yellow).style(bold)
  echo $styled("     Everything you say will be prioritized for memory storage.").fg(brightBlack).style(dim)
  echo ""

  chatRepl(a, firstMsg, settings)

  a.cfg.systemPrompt = originalPrompt