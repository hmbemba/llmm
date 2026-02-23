# =============================================================================
# chat_repl.nim – Fullscreen illwill TUI chat REPL for llmm agents
# =============================================================================
#
# A rich terminal interface built on illwill with:
#   - Double-buffered fullscreen rendering (~30 FPS)
#   - Scrollable chat history with word-wrapped messages
#   - Inline text editor with cursor, multi-line compose mode
#   - Animated thinking indicator during agent turns
#   - Command palette (Ctrl+P) with fuzzy filtering
#   - Mouse scroll on chat history
#   - Tool-call debug overlay
#   - Token/time stats footer
#   - Transcript save, clipboard paste, history search
#   - Fully themeable color scheme
#   - SQLite-backed chat history (persisted via AgentStore)
#
# Compile:
#   nim c -r -d:ssl chat_repl.nim
#
# Flags:
#   -d:llmm_repl_clipboard   Enable :clip / Ctrl+Shift+V
#   -d:llmm_repl_debug       Default debug ON
#   -d:llmm_repl_stats       Default stats ON
#
# NOTE: This file is `include`d from tick.nim, so all types from
# agent.nim, sessions.nim, store.nim, tick.nim etc. are in scope.
# =============================================================================

import std/[strutils, strformat, sequtils, times, options, os, math, algorithm]
import illwill

# =============================================================================
# Theme
# =============================================================================

type
  TuiTheme* = object
    headerBg*:        BackgroundColor
    headerFg*:        ForegroundColor
    footerBg*:        BackgroundColor
    footerFg*:        ForegroundColor
    borderFg*:        ForegroundColor
    userLabel*:       ForegroundColor
    userText*:        ForegroundColor
    assistantLabel*:  ForegroundColor
    assistantText*:   ForegroundColor
    toolFg*:          ForegroundColor
    errorFg*:         ForegroundColor
    metaFg*:          ForegroundColor
    statFg*:          ForegroundColor
    inputFg*:         ForegroundColor
    inputActiveBg*:   BackgroundColor
    paletteBorderFg*: ForegroundColor
    paletteFg*:       ForegroundColor
    paletteSelBg*:    BackgroundColor

proc defaultTheme*(): TuiTheme =
  TuiTheme(
    headerBg:        bgBlue,
    headerFg:        fgWhite,
    footerBg:        bgBlack,
    footerFg:        fgWhite,
    borderFg:        fgCyan,
    userLabel:       fgCyan,
    userText:        fgWhite,
    assistantLabel:  fgGreen,
    assistantText:   fgWhite,
    toolFg:          fgYellow,
    errorFg:         fgRed,
    metaFg:          fgBlack,       # bright-black = grey
    statFg:          fgBlack,
    inputFg:         fgWhite,
    inputActiveBg:   bgNone,
    paletteBorderFg: fgMagenta,
    paletteFg:       fgWhite,
    paletteSelBg:    bgMagenta,
  )

# =============================================================================
# Settings
# =============================================================================

type
  ReplSettings* = object
    showDebug*:     bool
    showStats*:     bool
    showTimestamps*: bool
    wordWrap*:      bool
    theme*:         TuiTheme
    loadHistory*:   bool          ## Load prior chat history from SQLite on startup
    maxHistoryLoad*: int          ## Max number of prior messages to load (0 = all)

proc defaultSettings*(): ReplSettings =
  ReplSettings(
    showDebug:     defined(llmm_repl_debug),
    showStats:     true,
    showTimestamps: false,
    wordWrap:      true,
    theme:         defaultTheme(),
    loadHistory:   true,
    maxHistoryLoad: 100,
  )

# =============================================================================
# Chat message model
# =============================================================================

type
  ChatRole* = enum
    crUser, crAssistant, crTool, crError, crMeta

  ChatMessage* = object
    role*:      ChatRole
    name*:      string
    text*:      string
    timestamp*: DateTime
    tokens*:    int
    elapsed*:   Duration

# =============================================================================
# Rendered line – a chat message gets word-wrapped into these
# =============================================================================

type
  RenderedLine = object
    text: string
    fg:   ForegroundColor
    bright: bool
    bg:   BackgroundColor
    # If this is the first line of a message, it carries the label
    isLabel: bool

# =============================================================================
# Command palette
# =============================================================================

type
  PaletteCommand = object
    id:    string
    title: string
    hint:  string
    key:   string   # display shortcut

proc allCommands(): seq[PaletteCommand] =
  @[
    PaletteCommand(id: "debug",      title: "Toggle debug (tool calls)",  hint: "Show/hide tool invocations",  key: "Ctrl+D"),
    PaletteCommand(id: "stats",      title: "Toggle stats",              hint: "Token count / latency footer", key: "Ctrl+T"),
    PaletteCommand(id: "timestamps", title: "Toggle timestamps",         hint: "Show HH:MM on messages",       key: ""),
    PaletteCommand(id: "wrap",       title: "Toggle word wrap",          hint: "Wrap long lines",              key: ""),
    PaletteCommand(id: "clear",      title: "Clear chat history",        hint: "Erase all messages",           key: "Ctrl+L"),
    PaletteCommand(id: "save",       title: "Save transcript",           hint: "Save as Markdown",             key: "Ctrl+S"),
    PaletteCommand(id: "paste",      title: "Compose multi-line",        hint: "Enter compose mode",           key: "Ctrl+O"),
    PaletteCommand(id: "help",       title: "Show help overlay",         hint: "Keyboard shortcuts",           key: "?"),
    PaletteCommand(id: "quit",       title: "Quit",                      hint: "End session",                  key: "Ctrl+Q"),
  ]

proc filterCommands(q: string): seq[PaletteCommand] =
  if q.strip().len == 0: return allCommands()
  let low = q.toLowerAscii()
  allCommands().filterIt(
    it.title.toLowerAscii().contains(low) or
    it.hint.toLowerAscii().contains(low)
  )

# =============================================================================
# Application state
# =============================================================================

type
  InputMode = enum
    imNormal,    # single-line typing
    imCompose,   # multi-line compose (Ctrl+O)

  OverlayKind = enum
    okNone, okHelp, okPalette, okSavePrompt

  AppState = object
    running:       bool
    settings:      ReplSettings
    agentName:     string

    # Chat
    messages:      seq[ChatMessage]
    rendered:      seq[RenderedLine]   # flattened, word-wrapped lines
    chatScroll:    int                 # offset from bottom (0 = latest)

    # Input
    inputBuf:      string
    inputCursor:   int
    inputMode:     InputMode
    composeLines:  seq[string]         # lines accumulated in compose mode

    # Thinking
    thinking:      bool
    thinkFrame:    int

    # Overlays
    overlay:       OverlayKind
    paletteQuery:  string
    paletteIdx:    int
    savePathBuf:   string

    # Status toast
    toastMsg:      string
    toastUntil:    float

    # Search
    searchMode:    bool
    searchQuery:   string
    searchHits:    seq[int]            # indices into `messages`
    searchIdx:     int

# =============================================================================
# Helpers
# =============================================================================

proc clampI(x, lo, hi: int): int = max(lo, min(hi, x))

proc padRight(s: string, n: int): string =
  if s.len >= n: return s[0 ..< n]
  s & ' '.repeat(n - s.len)

proc centerIn(s: string, n: int): string =
  if n <= 0: return ""
  if s.len >= n: return s[0 ..< n]
  let left = (n - s.len) div 2
  ' '.repeat(left) & s & ' '.repeat(n - s.len - left)

proc setToast(state: var AppState, msg: string, secs = 2.0) =
  state.toastMsg = msg
  state.toastUntil = epochTime() + secs

proc toastActive(state: AppState): bool =
  state.toastMsg.len > 0 and epochTime() < state.toastUntil

proc keyToChar(k: Key): Option[char] =
  ## Map an illwill Key to a printable char (ASCII subset).
  let v = ord(k)
  if v >= 32 and v <= 126:
    return some(chr(v))
  # Shifted letters
  case k
  of Key.ShiftA: return some('A')
  of Key.ShiftB: return some('B')
  of Key.ShiftC: return some('C')
  of Key.ShiftD: return some('D')
  of Key.ShiftE: return some('E')
  of Key.ShiftF: return some('F')
  of Key.ShiftG: return some('G')
  of Key.ShiftH: return some('H')
  of Key.ShiftI: return some('I')
  of Key.ShiftJ: return some('J')
  of Key.ShiftK: return some('K')
  of Key.ShiftL: return some('L')
  of Key.ShiftM: return some('M')
  of Key.ShiftN: return some('N')
  of Key.ShiftO: return some('O')
  of Key.ShiftP: return some('P')
  of Key.ShiftQ: return some('Q')
  of Key.ShiftR: return some('R')
  of Key.ShiftS: return some('S')
  of Key.ShiftT: return some('T')
  of Key.ShiftU: return some('U')
  of Key.ShiftV: return some('V')
  of Key.ShiftW: return some('W')
  of Key.ShiftX: return some('X')
  of Key.ShiftY: return some('Y')
  of Key.ShiftZ: return some('Z')
  else: discard
  # Common punctuation that illwill maps to named keys
  case k
  of Key.Space:          return some(' ')
  of Key.Comma:          return some(',')
  of Key.Dot:            return some('.')
  of Key.Slash:          return some('/')
  of Key.Backslash:      return some('\\')
  of Key.Minus:          return some('-')
  of Key.Underscore:     return some('_')
  of Key.Equals:         return some('=')
  of Key.Semicolon:      return some(';')
  of Key.Colon:          return some(':')
  of Key.SingleQuote:    return some('\'')
  of Key.DoubleQuote:    return some('"')
  of Key.LeftParen:      return some('(')
  of Key.RightParen:     return some(')')
  of Key.LeftBracket:    return some('[')
  of Key.RightBracket:   return some(']')
  of Key.LeftBrace:      return some('{')
  of Key.RightBrace:     return some('}')
  of Key.Asterisk:       return some('*')
  of Key.Plus:           return some('+')
  of Key.QuestionMark:   return some('?')
  of Key.ExclamationMark: return some('!')
  of Key.Hash:           return some('#')
  of Key.Dollar:         return some('$')
  of Key.Percent:        return some('%')
  of Key.Ampersand:      return some('&')
  of Key.At:             return some('@')
  of Key.Caret:          return some('^')
  of Key.GraveAccent:    return some('`')
  of Key.Tilde:          return some('~')
  of Key.LessThan:       return some('<')
  of Key.GreaterThan:    return some('>')
  of Key.Pipe:           return some('|')
  of Key.Zero:           return some('0')
  of Key.One:            return some('1')
  of Key.Two:            return some('2')
  of Key.Three:          return some('3')
  of Key.Four:           return some('4')
  of Key.Five:           return some('5')
  of Key.Six:            return some('6')
  of Key.Seven:          return some('7')
  of Key.Eight:          return some('8')
  of Key.Nine:           return some('9')
  else: discard
  return none(char)

# =============================================================================
# Word wrapping
# =============================================================================

proc wrapLines(text: string, width: int): seq[string] =
  ## Word-wrap text to `width`, preserving existing newlines.
  if width <= 0: return @[text]
  for para in text.split('\n'):
    if para.strip().len == 0:
      result.add("")
      continue
    var cur = ""
    for word in para.splitWhitespace():
      if cur.len == 0:
        cur = word
      elif cur.len + 1 + word.len <= width:
        cur &= " " & word
      else:
        result.add(cur)
        cur = word
    if cur.len > 0:
      result.add(cur)

# =============================================================================
# Render chat messages into RenderedLine seq
# =============================================================================

proc rebuildRendered(state: var AppState) =
  ## Flatten all messages into wrapped RenderedLine entries.
  let theme = state.settings.theme
  let w = terminalWidth() - 6  # leave 3-char margin each side
  let wrapW = if state.settings.wordWrap: max(20, w) else: 9999

  state.rendered.setLen(0)

  for msg in state.messages:
    let ts = if state.settings.showTimestamps: msg.timestamp.format(" HH:mm") else: ""

    case msg.role
    of crUser:
      # Label line
      state.rendered.add RenderedLine(
        text: "You" & ts,
        fg: theme.userLabel, bright: true, bg: bgNone, isLabel: true,
      )
      for line in wrapLines(msg.text, wrapW):
        state.rendered.add RenderedLine(
          text: "  " & line,
          fg: theme.userText, bright: false, bg: bgNone,
        )
      state.rendered.add RenderedLine(text: "", fg: fgNone, bright: false, bg: bgNone)

    of crAssistant:
      let label = msg.name & ts
      state.rendered.add RenderedLine(
        text: label,
        fg: theme.assistantLabel, bright: true, bg: bgNone, isLabel: true,
      )
      for line in wrapLines(msg.text, wrapW):
        state.rendered.add RenderedLine(
          text: "  " & line,
          fg: theme.assistantText, bright: false, bg: bgNone,
        )
      # Stats line
      if state.settings.showStats and (msg.tokens > 0 or msg.elapsed > DurationZero):
        let ms = msg.elapsed.inMilliseconds
        state.rendered.add RenderedLine(
          text: &"  {ms}ms | {msg.tokens} tok",
          fg: theme.statFg, bright: true, bg: bgNone,
        )
      state.rendered.add RenderedLine(text: "", fg: fgNone, bright: false, bg: bgNone)

    of crTool:
      if state.settings.showDebug:
        state.rendered.add RenderedLine(
          text: "  > " & msg.text,
          fg: theme.toolFg, bright: false, bg: bgNone,
        )

    of crError:
      state.rendered.add RenderedLine(
        text: "ERROR: " & msg.text,
        fg: theme.errorFg, bright: true, bg: bgNone,
      )
      state.rendered.add RenderedLine(text: "", fg: fgNone, bright: false, bg: bgNone)

    of crMeta:
      state.rendered.add RenderedLine(
        text: "  " & msg.text,
        fg: theme.metaFg, bright: true, bg: bgNone,
      )
      state.rendered.add RenderedLine(text: "", fg: fgNone, bright: false, bg: bgNone)

# =============================================================================
# Layout rects
# =============================================================================

type
  Rect = object
    x1, y1, x2, y2: int

proc w(r: Rect): int = max(0, r.x2 - r.x1 + 1)
proc h(r: Rect): int = max(0, r.y2 - r.y1 + 1)

proc inset(r: Rect, dx, dy: int): Rect =
  Rect(x1: r.x1+dx, y1: r.y1+dy, x2: r.x2-dx, y2: r.y2-dy)

# =============================================================================
# Drawing helpers
# =============================================================================

proc fillRect(tb: var TerminalBuffer, r: Rect, ch = " ") =
  for y in r.y1 .. r.y2:
    for x in r.x1 .. r.x2:
      tb.write(x, y, ch)

proc writeClipped(tb: var TerminalBuffer, x, y: int, s: string, maxW: int) =
  if maxW <= 0: return
  let t = if s.len > maxW: s[0 ..< maxW] else: s
  tb.write(x, y, t)

# =============================================================================
# Draw: header
# =============================================================================

proc drawHeader(tb: var TerminalBuffer, r: Rect, state: AppState) =
  let theme = state.settings.theme
  tb.setBackgroundColor(theme.headerBg)
  tb.setForegroundColor(theme.headerFg, bright = true)
  tb.fill(r.x1, r.y1, r.x2, r.y2, " ")

  let title = &" Chat: {state.agentName} "
  tb.write(r.x1 + 1, r.y1, title)

  let clock = now().format("HH:mm:ss")
  tb.write(r.x2 - clock.len - 1, r.y1, clock)

  # Mode indicator
  let mode = case state.inputMode
    of imNormal:  ""
    of imCompose: " [COMPOSE] "
  if mode.len > 0:
    tb.setForegroundColor(fgYellow, bright = true)
    tb.write(r.x1 + title.len + 2, r.y1, mode)

  if state.searchMode:
    tb.setForegroundColor(fgYellow, bright = true)
    tb.write(r.x1 + title.len + mode.len + 2, r.y1, " [SEARCH] ")

  tb.resetAttributes()

# =============================================================================
# Draw: footer / status bar
# =============================================================================

proc drawFooter(tb: var TerminalBuffer, r: Rect, state: AppState) =
  let theme = state.settings.theme
  tb.setBackgroundColor(theme.footerBg)
  tb.setForegroundColor(theme.footerFg)
  tb.fill(r.x1, r.y1, r.x2, r.y2, " ")

  let hints = " Ctrl+P:Palette  Ctrl+O:Compose  Ctrl+S:Save  ?:Help  Ctrl+Q:Quit "
  tb.setForegroundColor(fgCyan, bright = true)
  tb.writeClipped(r.x1 + 1, r.y1, hints, w(r) - 2)

  # Toast
  if toastActive(state):
    tb.setBackgroundColor(bgYellow)
    tb.setForegroundColor(fgBlack, bright = true)
    let msg = " " & state.toastMsg & " "
    let x = clampI(r.x2 - msg.len - 1, r.x1 + 1, r.x2 - 1)
    tb.write(x, r.y1, msg)

  tb.resetAttributes()

# =============================================================================
# Draw: chat area (scrollable)
# =============================================================================

proc drawChatArea(tb: var TerminalBuffer, r: Rect, state: AppState) =
  let theme = state.settings.theme
  let inner = inset(r, 1, 0)
  let visibleH = h(inner)
  if visibleH <= 0: return

  let totalLines = state.rendered.len
  let maxScroll = max(0, totalLines - visibleH)
  let scroll = clampI(state.chatScroll, 0, maxScroll)

  # We display from bottom: the newest content is at the bottom of the view
  let startLine = max(0, totalLines - visibleH - scroll)
  let endLine = min(totalLines, startLine + visibleH)

  var y = inner.y1
  for i in startLine ..< endLine:
    let rl = state.rendered[i]
    tb.setForegroundColor(rl.fg, bright = rl.bright)
    if rl.bg != bgNone:
      tb.setBackgroundColor(rl.bg)
    tb.writeClipped(inner.x1, y, rl.text, w(inner))
    tb.resetAttributes()
    inc y

  # Scroll indicator on right edge
  if totalLines > visibleH:
    let barH = max(1, (visibleH * visibleH) div totalLines)
    let barPos = if maxScroll > 0:
      ((maxScroll - scroll) * (visibleH - barH)) div maxScroll
    else: 0

    for sy in 0 ..< visibleH:
      let ch = if sy >= barPos and sy < barPos + barH: "█" else: "│"
      tb.setForegroundColor(fgBlack, bright = true)
      tb.write(r.x2, r.y1 + sy, ch)

  # Thinking indicator
  if state.thinking:
    let spinChars = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    let frame = state.thinkFrame mod spinChars.len
    let thinkY = min(inner.y2, inner.y1 + endLine - startLine)
    tb.setForegroundColor(theme.assistantLabel, bright = true)
    tb.write(inner.x1, thinkY, spinChars[frame] & " " & state.agentName & " is thinking...")

  tb.resetAttributes()

# =============================================================================
# Draw: input area
# =============================================================================

proc drawInputArea(tb: var TerminalBuffer, r: Rect, state: AppState) =
  let theme = state.settings.theme
  let inner = inset(r, 1, 0)

  # Border line above input
  tb.setForegroundColor(theme.borderFg)
  tb.drawHorizLine(r.x1, r.x2, r.y1)

  case state.inputMode
  of imNormal:
    # Prompt symbol
    tb.setForegroundColor(theme.userLabel, bright = true)
    tb.write(inner.x1, inner.y1 + 1, "> ")

    # Input text with cursor
    let inputW = w(inner) - 3
    let displayStart = max(0, state.inputCursor - inputW + 1)
    let visible = state.inputBuf[displayStart ..< min(state.inputBuf.len, displayStart + inputW)]

    tb.setForegroundColor(theme.inputFg)
    tb.write(inner.x1 + 2, inner.y1 + 1, padRight(visible, inputW))

    # Cursor (block highlight)
    let cursorScreenX = inner.x1 + 2 + (state.inputCursor - displayStart)
    if cursorScreenX <= inner.x2:
      let ch = if state.inputCursor < state.inputBuf.len:
        $state.inputBuf[state.inputCursor]
      else: " "
      tb.setBackgroundColor(bgWhite)
      tb.setForegroundColor(fgBlack)
      tb.write(cursorScreenX, inner.y1 + 1, ch)

  of imCompose:
    tb.setForegroundColor(fgYellow, bright = true)
    tb.write(inner.x1, inner.y1 + 1, "COMPOSE (Ctrl+Enter to send, Esc to cancel)")

    # Show last few compose lines
    let availH = h(inner) - 2
    let startIdx = max(0, state.composeLines.len - availH)
    var cy = inner.y1 + 2
    for i in startIdx ..< state.composeLines.len:
      tb.setForegroundColor(theme.inputFg)
      tb.writeClipped(inner.x1 + 2, cy, state.composeLines[i], w(inner) - 3)
      inc cy

    # Current line being typed
    if cy <= inner.y2:
      tb.setForegroundColor(theme.inputFg)
      tb.write(inner.x1, cy, "> ")
      tb.writeClipped(inner.x1 + 2, cy, state.inputBuf, w(inner) - 3)

  tb.resetAttributes()

# =============================================================================
# Draw: help overlay
# =============================================================================

proc drawHelpOverlay(tb: var TerminalBuffer, root: Rect) =
  let ww = min(72, w(root) - 4)
  let hh = min(22, h(root) - 4)
  if ww < 30 or hh < 10: return

  let x1 = root.x1 + (w(root) - ww) div 2
  let y1 = root.y1 + (h(root) - hh) div 2
  let box = Rect(x1: x1, y1: y1, x2: x1 + ww - 1, y2: y1 + hh - 1)

  # Background
  tb.setBackgroundColor(bgBlack)
  tb.setForegroundColor(fgWhite)
  tb.fill(box.x1, box.y1, box.x2, box.y2, " ")

  # Border
  var bb = newBoxBuffer(tb.width, tb.height)
  bb.drawRect(box.x1, box.y1, box.x2, box.y2, doubleStyle = true)
  tb.setForegroundColor(fgCyan, bright = true)
  tb.write(bb)
  tb.resetAttributes()

  let inner = inset(box, 2, 1)
  var y = inner.y1
  tb.setForegroundColor(fgWhite, bright = true)
  tb.write(inner.x1, y, "Keyboard Shortcuts  (? or Esc to close)")
  y += 2

  let shortcuts = @[
    ("Enter",         "Send message"),
    ("Ctrl+O",        "Compose multi-line (Ctrl+Enter to send)"),
    ("Ctrl+P",        "Command palette"),
    ("Ctrl+S",        "Save transcript"),
    ("Ctrl+D",        "Toggle debug (tool calls)"),
    ("Ctrl+T",        "Toggle stats"),
    ("Ctrl+L",        "Clear chat"),
    ("Ctrl+F",        "Search messages"),
    ("Ctrl+Q / Esc",  "Quit (Esc also closes overlays)"),
    ("Up/Down",       "Input history (TODO)"),
    ("PgUp/PgDn",     "Scroll chat history"),
    ("Mouse Scroll",  "Scroll chat history"),
    ("Home/End",      "Cursor to start/end of input"),
    ("?",             "This help screen"),
  ]

  tb.setForegroundColor(fgWhite)
  for (key, desc) in shortcuts:
    if y > inner.y2: break
    tb.setForegroundColor(fgYellow, bright = true)
    tb.writeClipped(inner.x1, y, padRight(key, 18), 18)
    tb.setForegroundColor(fgWhite)
    tb.writeClipped(inner.x1 + 18, y, desc, w(inner) - 18)
    y += 1

  tb.resetAttributes()

# =============================================================================
# Draw: command palette
# =============================================================================

proc drawPalette(tb: var TerminalBuffer, root: Rect, state: AppState) =
  let ww = min(70, w(root) - 6)
  let hh = min(16, h(root) - 6)
  if ww < 30 or hh < 8: return

  let x1 = root.x1 + (w(root) - ww) div 2
  let y1 = root.y1 + (h(root) - hh) div 3
  let box = Rect(x1: x1, y1: y1, x2: x1 + ww - 1, y2: y1 + hh - 1)

  tb.setBackgroundColor(bgBlack)
  tb.setForegroundColor(fgWhite)
  tb.fill(box.x1, box.y1, box.x2, box.y2, " ")

  var bb = newBoxBuffer(tb.width, tb.height)
  bb.drawRect(box.x1, box.y1, box.x2, box.y2, doubleStyle = true)
  tb.setForegroundColor(fgMagenta, bright = true)
  tb.write(bb)
  tb.resetAttributes()

  let inner = inset(box, 2, 1)
  let cmds = filterCommands(state.paletteQuery)
  let idxMax = max(0, cmds.len - 1)
  let idx = clampI(state.paletteIdx, 0, idxMax)

  tb.setForegroundColor(fgWhite, bright = true)
  tb.write(inner.x1, inner.y1, "Command Palette  (Esc to close, Enter to run)")

  tb.setForegroundColor(fgCyan)
  tb.write(inner.x1, inner.y1 + 1, "> " & state.paletteQuery & "_")

  let listY1 = inner.y1 + 3
  let visible = max(0, inner.y2 - listY1 + 1)

  for i in 0 ..< visible:
    let y = listY1 + i
    if i < cmds.len:
      let isSel = (i == idx)
      if isSel:
        tb.setBackgroundColor(bgMagenta)
        tb.setForegroundColor(fgWhite, bright = true)
      else:
        tb.setBackgroundColor(bgNone)
        tb.setForegroundColor(fgWhite)

      let left = padRight(cmds[i].title, max(0, w(inner) - 14))
      let right = padRight(cmds[i].key, 12)
      tb.writeClipped(inner.x1, y, left & right, w(inner))
      tb.resetAttributes()
    else:
      tb.write(inner.x1, y, ' '.repeat(w(inner)))

  tb.resetAttributes()

# =============================================================================
# Draw: search bar (inline at top of chat area)
# =============================================================================

proc drawSearchBar(tb: var TerminalBuffer, r: Rect, state: AppState) =
  tb.setBackgroundColor(bgYellow)
  tb.setForegroundColor(fgBlack, bright = true)
  tb.fill(r.x1, r.y1, r.x2, r.y1, " ")
  let label = &" Search: {state.searchQuery}_ ({state.searchHits.len} hits) "
  tb.writeClipped(r.x1, r.y1, label, w(r))
  tb.resetAttributes()

# =============================================================================
# Draw: save-path prompt overlay
# =============================================================================

proc drawSavePrompt(tb: var TerminalBuffer, root: Rect, state: AppState) =
  let ww = min(60, w(root) - 4)
  let hh = 5
  let x1 = root.x1 + (w(root) - ww) div 2
  let y1 = root.y1 + (h(root) - hh) div 2
  let box = Rect(x1: x1, y1: y1, x2: x1 + ww - 1, y2: y1 + hh - 1)

  tb.setBackgroundColor(bgBlack)
  tb.setForegroundColor(fgWhite)
  tb.fill(box.x1, box.y1, box.x2, box.y2, " ")

  var bb = newBoxBuffer(tb.width, tb.height)
  bb.drawRect(box.x1, box.y1, box.x2, box.y2, doubleStyle = true)
  tb.setForegroundColor(fgCyan, bright = true)
  tb.write(bb)
  tb.resetAttributes()

  let inner = inset(box, 2, 1)
  tb.setForegroundColor(fgWhite, bright = true)
  tb.write(inner.x1, inner.y1, "Save transcript to (Enter to confirm, Esc to cancel):")
  tb.setForegroundColor(fgWhite)
  tb.write(inner.x1, inner.y1 + 2, "> " & state.savePathBuf & "_")
  tb.resetAttributes()

# =============================================================================
# Transcript saving
# =============================================================================

proc saveTranscript(state: AppState, path: string) =
  var md = &"# Chat with {state.agentName}\n"
  md &= &"_Saved {now().format(\"yyyy-MM-dd HH:mm:ss\")}_\n\n---\n\n"
  for msg in state.messages:
    let ts = msg.timestamp.format("HH:mm:ss")
    case msg.role
    of crUser:
      md &= &"**You** _{ts}_\n\n{msg.text}\n\n"
    of crAssistant:
      md &= &"**{msg.name}** _{ts}_"
      if msg.tokens > 0:
        md &= &" ({msg.tokens} tokens, {msg.elapsed.inMilliseconds}ms)"
      md &= &"\n\n{msg.text}\n\n"
    of crError:
      md &= &"> Error: {msg.text}\n\n"
    of crTool:
      md &= &"    {msg.text}\n\n"
    of crMeta:
      md &= &"_{msg.text}_\n\n"
    md &= "---\n\n"
  writeFile(path, md)

# =============================================================================
# Search
# =============================================================================

proc updateSearch(state: var AppState) =
  state.searchHits.setLen(0)
  if state.searchQuery.strip().len == 0: return
  let q = state.searchQuery.toLowerAscii()
  for i, msg in state.messages:
    if msg.text.toLowerAscii().contains(q):
      state.searchHits.add(i)

# =============================================================================
# SQLite history loading
# =============================================================================

proc loadHistoryFromDb(state: var AppState, agentStore: AgentStore, agentName: string) =
  ## Load prior chat history from the AgentStore SQLite database.
  ## Converts ChatHistoryRow records into ChatMessage display objects.
  ## Rows are returned newest-first from the DB, so we reverse for display.
  if agentStore.isNil:
    return

  let limit = if state.settings.maxHistoryLoad > 0: state.settings.maxHistoryLoad else: 500
  let rows = agentStore.getChatHistory(limit)

  if rows.len == 0:
    return

  # rows are newest-first; reverse to chronological for display
  var chatMsgs: seq[ChatMessage]
  for i in countdown(rows.high, 0):
    let row = rows[i]
    let role = case row.role
      of "user":      crUser
      of "assistant":  crAssistant
      of "error":      crError
      else:            crMeta

    # Parse timestamp from ISO string, fallback to now()
    var ts = now()
    try:
      ts = parse(row.ts, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
    except CatchableError:
      try:
        ts = parse(row.ts, "yyyy-MM-dd HH:mm:ss", utc())
      except CatchableError:
        discard

    chatMsgs.add ChatMessage(
      role:      role,
      name:      if role == crAssistant: agentName else: "",
      text:      row.content,
      timestamp: ts,
      tokens:    row.tokensUsed,
      elapsed:   initDuration(milliseconds = row.elapsedMs),
    )

  if chatMsgs.len > 0:
    # Separator between loaded history and new messages
    state.messages.add ChatMessage(
      role: crMeta, timestamp: now(),
      text: &"── Loaded {chatMsgs.len} messages from previous sessions ──",
    )
    for msg in chatMsgs:
      state.messages.add msg
    state.messages.add ChatMessage(
      role: crMeta, timestamp: now(),
      text: "── End of history ──",
    )

# =============================================================================
# Process a TickResult into chat messages
# =============================================================================

proc processTickResult(state: var AppState, res: TickResult) =
  # Tool events
  if state.settings.showDebug:
    for ev in res.events:
      case ev.kind
      of aekToolCall:
        state.messages.add ChatMessage(
          role: crTool, timestamp: now(),
          text: &"CALL {ev.callToolName}({ev.callToolArgs})",
        )
      of aekToolResult:
        let icon = if ev.resultOk: "OK" else: "ERR"

        let raw = $ev.resultOutput
        let preview = raw[0 ..< min(raw.len, 80)].replace("\n", " ")
        state.messages.add ChatMessage(
          role: crTool, timestamp: now(),
          text: &"  {icon}: {preview}",
        )
      else: discard

  # Main response
  if res.error.isSome:
    state.messages.add ChatMessage(
      role: crError, timestamp: now(),
      text: res.error.get(),
    )
  elif res.text.len > 0:
    state.messages.add ChatMessage(
      role: crAssistant,
      name: state.agentName,
      text: res.text,
      timestamp: now(),
      tokens: res.tokensUsed,
      elapsed: res.elapsed,
    )

  # NOTE: We do NOT need to persist here — chatTurn() in tick.nim already
  # writes user/assistant/error entries to the AgentStore SQLite database.

  state.rebuildRendered()
  state.chatScroll = 0  # snap to bottom on new message

# =============================================================================
# Execute a palette command
# =============================================================================

proc runPaletteCommand(state: var AppState, cmdId: string) =
  case cmdId
  of "debug":
    state.settings.showDebug = not state.settings.showDebug
    state.setToast("Debug: " & (if state.settings.showDebug: "ON" else: "OFF"))
    state.rebuildRendered()
  of "stats":
    state.settings.showStats = not state.settings.showStats
    state.setToast("Stats: " & (if state.settings.showStats: "ON" else: "OFF"))
    state.rebuildRendered()
  of "timestamps":
    state.settings.showTimestamps = not state.settings.showTimestamps
    state.setToast("Timestamps: " & (if state.settings.showTimestamps: "ON" else: "OFF"))
    state.rebuildRendered()
  of "wrap":
    state.settings.wordWrap = not state.settings.wordWrap
    state.setToast("Word wrap: " & (if state.settings.wordWrap: "ON" else: "OFF"))
    state.rebuildRendered()
  of "clear":
    state.messages.setLen(0)
    state.rendered.setLen(0)
    state.chatScroll = 0
    state.setToast("Chat cleared")
  of "save":
    state.overlay = okSavePrompt
    state.savePathBuf = "chat_" & now().format("yyyyMMdd-HHmmss") & ".md"
  of "paste":
    state.inputMode = imCompose
    state.composeLines.setLen(0)
    state.inputBuf = ""
    state.setToast("Compose mode — type freely, Ctrl+Enter sends")
  of "help":
    state.overlay = okHelp
  of "quit":
    state.running = false
  else:
    state.setToast("Unknown command: " & cmdId)

# =============================================================================
# Input handling
# =============================================================================

proc handleInputNormal(state: var AppState, key: Key): Option[string] =
  ## Handle keys in normal single-line input mode.
  ## Returns Some(text) if user submitted a message.
  case key
  of Key.Enter:
    let text = state.inputBuf.strip()
    if text.len > 0:
      state.inputBuf = ""
      state.inputCursor = 0
      return some(text)

  of Key.Backspace:
    if state.inputCursor > 0:
      state.inputBuf.delete(state.inputCursor - 1 ..< state.inputCursor)
      dec state.inputCursor

  of Key.Delete:
    if state.inputCursor < state.inputBuf.len:
      state.inputBuf.delete(state.inputCursor ..< state.inputCursor + 1)

  of Key.Left:
    state.inputCursor = max(0, state.inputCursor - 1)

  of Key.Right:
    state.inputCursor = min(state.inputBuf.len, state.inputCursor + 1)

  of Key.Home:
    state.inputCursor = 0

  of Key.End:
    state.inputCursor = state.inputBuf.len

  of Key.CtrlA:
    state.inputCursor = 0

  of Key.CtrlE:
    state.inputCursor = state.inputBuf.len

  of Key.CtrlU:
    # Kill line before cursor
    state.inputBuf = state.inputBuf[state.inputCursor ..< state.inputBuf.len]
    state.inputCursor = 0

  of Key.CtrlK:
    # Kill line after cursor
    state.inputBuf = state.inputBuf[0 ..< state.inputCursor]

  of Key.CtrlW:
    # Delete word backwards
    var pos = state.inputCursor
    while pos > 0 and state.inputBuf[pos - 1] == ' ': dec pos
    while pos > 0 and state.inputBuf[pos - 1] != ' ': dec pos
    state.inputBuf.delete(pos ..< state.inputCursor)
    state.inputCursor = pos

  else:
    let chOpt = keyToChar(key)
    if chOpt.isSome:
      state.inputBuf.insert($chOpt.get, state.inputCursor)
      inc state.inputCursor

  return none(string)

proc handleInputCompose(state: var AppState, key: Key): Option[string] =
  ## Handle keys in multi-line compose mode.
  case key
  of Key.Escape:
    state.inputMode = imNormal
    state.inputBuf = ""
    state.composeLines.setLen(0)
    state.setToast("Compose cancelled")
    return none(string)

  of Key.Enter:
    # In compose, plain Enter adds a line
    state.composeLines.add(state.inputBuf)
    state.inputBuf = ""
    state.inputCursor = 0
    return none(string)

  of Key.CtrlJ:
    # Ctrl+Enter / Ctrl+J: submit the composed text
    if state.inputBuf.strip().len > 0:
      state.composeLines.add(state.inputBuf)
    let text = state.composeLines.join("\n").strip()
    state.inputMode = imNormal
    state.inputBuf = ""
    state.inputCursor = 0
    state.composeLines.setLen(0)
    if text.len > 0:
      return some(text)
    return none(string)

  of Key.Backspace:
    if state.inputBuf.len > 0:
      state.inputBuf.delete(max(0, state.inputBuf.len - 1) ..< state.inputBuf.len)
    elif state.composeLines.len > 0:
      state.inputBuf = state.composeLines[^1]
      state.composeLines.setLen(state.composeLines.len - 1)
      state.inputCursor = state.inputBuf.len
    return none(string)

  else:
    let chOpt = keyToChar(key)
    if chOpt.isSome:
      state.inputBuf.insert($chOpt.get, state.inputBuf.len)
      state.inputCursor = state.inputBuf.len
    return none(string)

proc handleOverlayKeys(state: var AppState, key: Key) =
  case state.overlay
  of okHelp:
    if key in {Key.Escape, Key.QuestionMark, Key.Enter}:
      state.overlay = okNone

  of okPalette:
    let cmds = filterCommands(state.paletteQuery)
    let idxMax = max(0, cmds.len - 1)
    case key
    of Key.Escape:
      state.overlay = okNone
    of Key.Up:
      state.paletteIdx = clampI(state.paletteIdx - 1, 0, idxMax)
    of Key.Down:
      state.paletteIdx = clampI(state.paletteIdx + 1, 0, idxMax)
    of Key.Enter:
      if cmds.len > 0:
        let idx = clampI(state.paletteIdx, 0, idxMax)
        state.runPaletteCommand(cmds[idx].id)
      state.overlay = okNone
    of Key.Backspace:
      if state.paletteQuery.len > 0:
        state.paletteQuery.setLen(state.paletteQuery.len - 1)
        state.paletteIdx = 0
    else:
      let chOpt = keyToChar(key)
      if chOpt.isSome:
        state.paletteQuery.add(chOpt.get)
        state.paletteIdx = 0

  of okSavePrompt:
    case key
    of Key.Escape:
      state.overlay = okNone
    of Key.Enter:
      try:
        state.saveTranscript(state.savePathBuf)
        state.setToast("Saved to " & state.savePathBuf)
      except CatchableError as e:
        state.setToast("Save failed: " & e.msg)
      state.overlay = okNone
    of Key.Backspace:
      if state.savePathBuf.len > 0:
        state.savePathBuf.setLen(state.savePathBuf.len - 1)
    else:
      let chOpt = keyToChar(key)
      if chOpt.isSome:
        state.savePathBuf.add(chOpt.get)

  of okNone:
    discard

proc handleSearchKeys(state: var AppState, key: Key) =
  case key
  of Key.Escape, Key.Enter:
    state.searchMode = false
  of Key.Backspace:
    if state.searchQuery.len > 0:
      state.searchQuery.setLen(state.searchQuery.len - 1)
      state.updateSearch()
  else:
    let chOpt = keyToChar(key)
    if chOpt.isSome:
      state.searchQuery.add(chOpt.get)
      state.updateSearch()

proc handleGlobalKeys(state: var AppState, key: Key) =
  ## Global shortcuts that apply regardless of input mode.
  case key
  of Key.CtrlQ:
    state.running = false
  of Key.CtrlP:
    state.overlay = okPalette
    state.paletteQuery = ""
    state.paletteIdx = 0
  of Key.CtrlO:
    state.inputMode = imCompose
    state.composeLines.setLen(0)
    state.inputBuf = ""
    state.setToast("Compose mode")
  of Key.CtrlS:
    state.overlay = okSavePrompt
    state.savePathBuf = "chat_" & now().format("yyyyMMdd-HHmmss") & ".md"
  of Key.CtrlD:
    state.runPaletteCommand("debug")
  of Key.CtrlT:
    state.runPaletteCommand("stats")
  of Key.CtrlL:
    state.runPaletteCommand("clear")
  of Key.CtrlF:
    state.searchMode = true
    state.searchQuery = ""
    state.searchHits.setLen(0)
  of Key.QuestionMark:
    if state.inputMode == imNormal and state.inputBuf.len == 0:
      state.overlay = okHelp
  of Key.PageUp:
    state.chatScroll = min(state.chatScroll + 10, max(0, state.rendered.len - 5))
  of Key.PageDown:
    state.chatScroll = max(0, state.chatScroll - 10)
  of Key.Up:
    state.chatScroll = min(state.chatScroll + 3, max(0, state.rendered.len - 5))
  of Key.Down:
    state.chatScroll = max(0, state.chatScroll - 3)
  else:
    discard

proc handleMouse(state: var AppState, mi: MouseInfo) =
  if mi.scroll:
    let delta = if mi.scrollDir == sdUp: 3 else: -3
    state.chatScroll = clampI(
      state.chatScroll + delta,
      0,
      max(0, state.rendered.len - 5)
    )

# =============================================================================
# Main chat REPL
# =============================================================================

proc exitProc() {.noconv.} =
  try:
    illwillDeinit()
  except CatchableError:
    discard
  showCursor()
  quit(0)

proc chatRepl*(
  a:         Agent,
  firstMsg:  string       = "",
  settings:  ReplSettings = defaultSettings(),
) =
  ## Opens a fullscreen illwill chat TUI with the agent.
  ##
  ## Features:
  ##   - SQLite-backed chat history (loads prior sessions on startup)
  ##   - Scrollable chat history with word wrapping
  ##   - Full line editor (Home/End, Ctrl+A/E/U/K/W, cursor movement)
  ##   - Multi-line compose mode (Ctrl+O)
  ##   - Command palette (Ctrl+P)
  ##   - Search through messages (Ctrl+F)
  ##   - Tool-call debug view (Ctrl+D)
  ##   - Token/latency stats (Ctrl+T)
  ##   - Transcript saving (Ctrl+S)
  ##   - Mouse scroll
  ##   - Animated thinking indicator
  ##   - Help overlay (?)
  ##   - Customizable theme

  # Initialize illwill
  illwillInit(fullscreen = true, mouse = true)
  setControlCHook(exitProc)
  hideCursor()

  var state: AppState
  state.running = true
  state.settings = settings
  state.agentName = a.cfg.name
  state.inputBuf = ""
  state.inputCursor = 0
  state.inputMode = imNormal
  state.overlay = okNone

  # Load prior chat history from SQLite if enabled
  if state.settings.loadHistory and not a.state.agentStore.isNil:
    state.loadHistoryFromDb(a.state.agentStore, a.cfg.name)

  # Welcome meta message
  state.messages.add ChatMessage(
    role: crMeta, timestamp: now(),
    text: &"Connected to {a.cfg.name}. Type a message and press Enter.",
  )

  # Handle firstMsg
  var pendingFuture: Option[Future[TickResult]] = none(Future[TickResult])

  if firstMsg.len > 0:
    state.messages.add ChatMessage(
      role: crUser, timestamp: now(), text: firstMsg,
    )
    state.thinking = true
    # chatTurn persists user + assistant messages to SQLite
    pendingFuture = some(a.chatTurn(firstMsg))

  state.rebuildRendered()

  # ---------- Main loop ----------
  while state.running:
    let tNow = epochTime()

    # Advance thinking animation
    if state.thinking:
      state.thinkFrame += 1

    # Check if agent finished
    if pendingFuture.isSome and pendingFuture.get.finished:
      state.thinking = false
      let res = pendingFuture.get.read()
      state.processTickResult(res)
      pendingFuture = none(Future[TickResult])

    # Poll async if we have a pending future
    if pendingFuture.isSome:
      try:
        asyncdispatch.poll(0)
      except CatchableError:
        discard

    # ---------- Render ----------
    var tb = newTerminalBuffer(terminalWidth(), terminalHeight())

    let root = Rect(x1: 0, y1: 0, x2: tb.width - 1, y2: tb.height - 1)
    let headerH = 1
    let footerH = 1
    let inputH = if state.inputMode == imCompose:
      clampI(state.composeLines.len + 4, 5, max(5, h(root) div 3))
    else: 3

    # Layout regions
    let headerR = Rect(x1: root.x1, y1: root.y1, x2: root.x2, y2: root.y1 + headerH - 1)
    let footerR = Rect(x1: root.x1, y1: root.y2 - footerH + 1, x2: root.x2, y2: root.y2)
    let inputR  = Rect(x1: root.x1, y1: footerR.y1 - inputH, x2: root.x2, y2: footerR.y1 - 1)

    var chatY1 = headerR.y2 + 1
    if state.searchMode:
      chatY1 += 1  # make room for search bar

    let chatR = Rect(x1: root.x1, y1: chatY1, x2: root.x2, y2: inputR.y1 - 1)

    # Draw
    drawHeader(tb, headerR, state)

    if state.searchMode:
      let searchR = Rect(x1: root.x1, y1: headerR.y2 + 1, x2: root.x2, y2: headerR.y2 + 1)
      drawSearchBar(tb, searchR, state)

    drawChatArea(tb, chatR, state)
    drawInputArea(tb, inputR, state)
    drawFooter(tb, footerR, state)

    # Overlays (drawn last, on top)
    case state.overlay
    of okHelp:        drawHelpOverlay(tb, root)
    of okPalette:     drawPalette(tb, root, state)
    of okSavePrompt:  drawSavePrompt(tb, root, state)
    of okNone:        discard

    tb.display()

    # ---------- Input ----------
    let key = getKey()

    if key == Key.Mouse:
      let mi = getMouse()
      handleMouse(state, mi)
    elif key != Key.None:
      # Overlays consume input first
      if state.overlay != okNone:
        handleOverlayKeys(state, key)
      elif state.searchMode:
        handleSearchKeys(state, key)
      else:
        # Check global shortcuts first
        var handled = false
        case key
        of Key.CtrlQ, Key.CtrlP, Key.CtrlO, Key.CtrlS,
           Key.CtrlD, Key.CtrlT, Key.CtrlL, Key.CtrlF,
           Key.PageUp, Key.PageDown, Key.Up, Key.Down:

          handleGlobalKeys(state, key)
          handled = true
        of Key.QuestionMark:
          if state.inputMode == imNormal and state.inputBuf.len == 0:
            handleGlobalKeys(state, key)
            handled = true
        of Key.Escape:
          if state.inputMode == imCompose:
            discard  # let compose handler deal with it
          else:
            state.running = false
            handled = true
        else:
          discard

        if not handled and not state.thinking:
          # Route to input handler
          let submitted = case state.inputMode
            of imNormal:  handleInputNormal(state, key)
            of imCompose: handleInputCompose(state, key)

          if submitted.isSome:
            let text = submitted.get
            state.messages.add ChatMessage(
              role: crUser, timestamp: now(), text: text,
            )
            state.rebuildRendered()
            state.chatScroll = 0

            # Start agent turn
            # chatTurn() handles all SQLite persistence (user msg, assistant msg, events)
            state.thinking = true
            state.thinkFrame = 0
            pendingFuture = some(a.chatTurn(text))

    # Frame cap
    sleep(16)  # ~60 FPS

  # Cleanup
  illwillDeinit()
  showCursor()

  # Print farewell to restored terminal
  echo ""
  echo &"  Session ended. {state.messages.len} messages exchanged."
  echo ""

# =============================================================================
# Feedback session variant
# =============================================================================

proc feedback*(a: Agent, firstMsg: string = "") =
  const feedbackPrefix = """
## IMPORTANT: User Feedback Session

The user is providing direct feedback. This information is HIGH PRIORITY
and should be stored in memory.

For EVERY piece of feedback:
1. Acknowledge it
2. Store it using the memory tool
3. Confirm what you stored
"""
  let original = a.cfg.systemPrompt
  a.cfg.systemPrompt = a.cfg.systemPrompt & "\n\n" & feedbackPrefix

  var settings = defaultSettings()
  settings.showStats = true
  settings.showDebug = true

  chatRepl(a, firstMsg, settings)

  a.cfg.systemPrompt = original