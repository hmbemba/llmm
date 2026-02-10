# =============================================================================
# chat_repl.nim - Stylish interactive chat REPL for llmm agents
# =============================================================================
#
# Replaces the chatRepl section of tick.nim with a rich terminal UI.
# Uses nimsterm for styled output + std/terminal for dimensions.
#
# Compile flags:
#   -d:llmm_repl_termui     Enable termui spinner (requires --threads:on)
#   -d:llmm_repl_clipboard  Enable :clip command
#   -d:llmm_repl_debug      Default debug mode ON
#   -d:llmm_repl_stats      Default stats mode ON
#
# =============================================================================

import std/[
json
,times
,options
,asyncdispatch
,strformat
,strutils
,sugar
,tables
,terminal
,os
,sequtils
]

import rz, ic
import agent, sessions
import ../tools/base
import ../../general_helpers
import ../../providers/oai/oai_client
import ../../providers/oai/common/types
import ../../providers/oai/utils/builders
import ../../providers/oai/responses/types
import ../../providers/oai/responses/api
import ../../providers/oai/responses/utils

import ./memory/types
import ./memory/store
import ./memory/tool
import ./memory/integration

# We import nimsterm for styled output
import nimsterm

when defined(llmm_repl_termui):
  import termui


# Re-export TickResult if not already visible from tick
# (or just import tick and use its TickResult)

# =============================================================================
# REPL Configuration & State
# =============================================================================

type
  ReplSettings* = object
    showDebug*     : bool   ## Show tool calls and internal events
    showStats*     : bool   ## Show token/time footer after each response
    showTimestamp* : bool   ## Show timestamps on messages
    wordWrap*      : bool   ## Word-wrap output to terminal width
    maxWidth*      : int    ## Max content width (0 = auto from terminal)
    theme*         : ReplTheme

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

  ReplMessage* = object
    role*      : string   # "user" | "assistant" | "tool" | "error" | "meta"
    name*      : string
    text*      : string
    timestamp* : DateTime
    tokens*    : int
    elapsed*   : Duration

  ReplState* = object
    settings*  : ReplSettings
    history*   : seq[ReplMessage]
    running*   : bool

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
  )

proc defaultSettings*(): ReplSettings =
  ReplSettings(
    showDebug     : defined(llmm_repl_debug)
    ,showStats    : defined(llmm_repl_stats) or true
    ,showTimestamp : false
    ,wordWrap     : true
    ,maxWidth     : 0
    ,theme        : defaultTheme()
  )

proc initReplState*(): ReplState =
  ReplState(
    settings : defaultSettings()
    ,history : @[]
    ,running : true
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
       $styled(":help").fg(cyan).style(bold) &
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
    (":help",          "Show this help"),
    (":paste",         "Enter paste mode (end with :end)"),
    (":clip",          "Send clipboard as message"),
    (":history [n]",   "Show last n exchanges (default 5)"),
    (":save <path>",   "Save transcript to file"),
    (":clear",         "Clear screen and reprint header"),
    (":debug",         "Toggle tool-call visibility"),
    (":stats",         "Toggle token/time stats"),
    (":timestamps",    "Toggle timestamps"),
    (":wrap",          "Toggle word wrapping"),
    (":width <n>",     "Set max content width (0=auto)"),
    ("exit / quit / q", "End session"),
  ]

  for (cmd, desc) in cmds:
    let padded = cmd & " ".repeat(max(1, 20 - cmd.len))
    echo $styled("    ").fg(theme.metaText) &
         $styled(padded).fg(cyan).style(bold) &
         $styled(desc).fg(theme.metaText)

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

proc saveTranscript*(state: ReplState, path: string, agentName: string) =
  ## Save the conversation transcript as Markdown.
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
  ## Try bracketed paste first, fall back to paste-aware reader.
  result = replReadBlock()
  if result.len == 0:
    result = replReadPasteAware()

# =============================================================================
# Prompt
# =============================================================================

proc showPrompt*(theme: ReplTheme) =
  ## Show the input prompt.
  stdout.write $styled("  ❯ ").fg(theme.promptArrow).style(bold)
  stdout.flushFile()

# =============================================================================
# Waiting / Thinking Indicator
# =============================================================================

proc replWaitForTurn*(a: Agent, fut: Future[TickResult], theme: ReplTheme): TickResult =
  ## Wait for a chatTurn to complete, showing a spinner/indicator.
  when defined(llmm_repl_termui):
    let spinner = termuiSpinner(&"  {a.name} is thinking...")
    while not fut.finished:
      asyncdispatch.poll(50)
    let res = fut.read()
    if res.error.isSome:
      spinner.fail(res.error.get())
    else:
      spinner.complete("Done")
    return res
  else:
    # Simple animated dots fallback
    stdout.write $styled(&"  {a.name} is thinking").fg(theme.metaText).style(dim)
    stdout.flushFile()
    var dots = 0
    while not fut.finished:
      asyncdispatch.poll(100)
      dots = (dots + 1) mod 4
      stdout.write "\r"
      stdout.write $styled(&"  {a.name} is thinking" & ".".repeat(dots) & " ".repeat(3 - dots)).fg(theme.metaText).style(dim)
      stdout.flushFile()

    # Clear the thinking line
    stdout.write "\r"
    stdout.eraseLine()
    stdout.flushFile()
    return fut.read()

# =============================================================================
# Process TickResult into display
# =============================================================================

proc displayTickResult*(res: TickResult, agentName: string, state: var ReplState) =
  ## Process and display a TickResult with full event visibility.
  let theme = state.settings.theme
  let width = state.settings.getContentWidth()

  # Show tool calls in debug mode
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

  # Show assistant response
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
      timestamp: now(), tokens: res.tokensUsed, elapsed: res.elapsed
    )

# =============================================================================
# Command Processing
# =============================================================================

proc processCommand*(cmd: string, state: var ReplState, agentName: string): bool =
  ## Process a REPL command. Returns true if the command was handled.
  let parts = cmd.split(" ", maxsplit = 1)
  let command = parts[0].toLowerAscii()
  let arg = if parts.len > 1: parts[1].strip() else: ""
  let theme = state.settings.theme
  let width = state.settings.getContentWidth()

  case command
  of ":help":
    printHelp(theme, width)
    return true

  of ":paste":
    return false  # Handled by caller

  of ":clip":
    return false  # Handled by caller

  of ":history":
    let n = if arg.len > 0: (try: parseInt(arg) except: 5) else: 5
    printHistory(state, n, agentName)
    return true

  of ":save":
    if arg.len == 0:
      printError("Usage: :save <filepath>", theme)
    else:
      try:
        saveTranscript(state, arg, agentName)
        printMeta(&"Transcript saved to {arg}", theme)
      except:
        printError(&"Failed to save: {getCurrentExceptionMsg()}", theme)
    return true

  of ":clear":
    eraseScreen(stdout)
    setCursorPos(stdout, 0, 0)
    printHeader(agentName, theme, width)
    return true

  of ":debug":
    state.settings.showDebug = not state.settings.showDebug
    let status = if state.settings.showDebug: "ON" else: "OFF"
    printMeta(&"Debug mode: {status}", theme)
    return true

  of ":stats":
    state.settings.showStats = not state.settings.showStats
    let status = if state.settings.showStats: "ON" else: "OFF"
    printMeta(&"Stats display: {status}", theme)
    return true

  of ":timestamps":
    state.settings.showTimestamp = not state.settings.showTimestamp
    let status = if state.settings.showTimestamp: "ON" else: "OFF"
    printMeta(&"Timestamps: {status}", theme)
    return true

  of ":wrap":
    state.settings.wordWrap = not state.settings.wordWrap
    let status = if state.settings.wordWrap: "ON" else: "OFF"
    printMeta(&"Word wrap: {status}", theme)
    return true

  of ":width":
    if arg.len == 0:
      printMeta(&"Current width: {state.settings.getContentWidth()}", theme)
    else:
      state.settings.maxWidth = try: parseInt(arg) except: 0
      printMeta(&"Max width set to: {state.settings.getContentWidth()}", theme)
    return true

  else:
    return false  # Not a recognized command

# =============================================================================
# Main Chat REPL (upgraded)
# =============================================================================

proc chatRepl*(a: Agent, firstMsg: string = "", settings: ReplSettings = defaultSettings()) =
  ## Opens a rich interactive chat REPL with the agent.
  ##
  ## Features:
  ##   - Styled message display with word wrapping
  ##   - Tool call visibility (toggle with :debug)
  ##   - Token/time stats (toggle with :stats)
  ##   - Chat history (:history), transcript saving (:save)
  ##   - Multi-line paste support (bracketed paste + :paste mode)
  ##   - Animated thinking indicator
  ##   - Customizable theme and settings

  var state = initReplState()
  state.settings = settings

  let theme = state.settings.theme
  let width = state.settings.getContentWidth()

  # Print header
  printHeader(a.name, theme, width)

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
    displayTickResult(res, a.name, state)

  # Main loop
  while state.running:
    showPrompt(theme)

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

    # Commands
    if cmd.startsWith(":"):
      if processCommand(cmd, state, a.name):
        continue

      # Handle :paste specially
      if cmd == ":paste":
        echo $styled("  📋 Paste mode — end with :end").fg(theme.metaText).style(dim)
        var lines: seq[string] = @[]
        while true:
          let line = stdin.readLine()
          if line.strip() == ":end": break
          lines.add line
        raw = lines.join("\n")
        if raw.strip().len == 0: continue

      # Handle :clip
      elif cmd == ":clip":
        when defined(llmm_repl_clipboard):
          raw = getClipboardText()
        else:
          printError("Clipboard not compiled. Rebuild with -d:llmm_repl_clipboard", theme)
          continue

    let userMsg = raw.strip()
    if userMsg.len == 0:
      continue

    # Display user message
    printUserMessage(userMsg, theme, width, now(), state.settings.showTimestamp)
    state.history.add ReplMessage(
      role: "user", text: userMsg, timestamp: now()
    )

    # Execute chat turn
    let fut = a.chatTurn(userMsg)
    let res = replWaitForTurn(a, fut, theme)
    displayTickResult(res, a.name, state)


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

  let originalPrompt = a.systemPrompt
  a.systemPrompt = a.systemPrompt & "\n\n" & feedbackPrefix

  var settings = defaultSettings()
  settings.showStats = true
  settings.showDebug = true  # Show memory tool calls during feedback

  # Override the header briefly
  echo ""
  echo $styled("  📝 Feedback Session").fg(yellow).style(bold)
  echo $styled("     Everything you say will be prioritized for memory storage.").fg(brightBlack).style(dim)
  echo ""

  chatRepl(a, firstMsg, settings)

  a.systemPrompt = originalPrompt