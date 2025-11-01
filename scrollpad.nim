#
## A scrollable TUI like OpenAI-codex, but in nim
## This was mostly generated with OpenAI-codex.
#

import std/[atomics, os, strformat, strutils, terminal, times]
import key

const
  editorIndent = "  "
  keyPollIntervalMs = 12
  resizePollIntervalMs = 100
  feedIntervalMs = 800
  feedSleepSliceMs = 40
  editorBgSeq = "\e[48;5;235m"
  editorFgSeq = "\e[38;5;252m"
  editorHistoryBgSeq = "\e[48;5;233m" # Even darker than editorBgSeq, but not black
  scrollbackBgSeq = "\e[48;5;16m"
  scrollbackFgSeq = "\e[38;5;252m"
  fillToEOL = "\e[0K"
  ansiReset = "\e[0m"

var
  showInputHistory* = true  # Feature flag: if true, submitted input appears in scrollback with editor highlighting

type
  EventKind = enum
    evKey, evAppend, evStatus

  UiEvent = object
    case kind: EventKind
    of evKey:
      key: string
    of evAppend:
      lines: seq[string]
    of evStatus:
      status: string

  Segment = object
    start: int
    len: int

  Editor = object
    lines: seq[string]
    cursorLine: int
    cursorCol: int
    preferredCol: int

  EditorLayout = object
    lines: seq[string]
    cursorRow: int
    cursorCol: int

  SpinLock = object
    state: Atomic[int32]

  UiState = object
    width: int
    height: int
    status: string
    editor: Editor
    bottomHeight: int
    running: bool
    stickyHeight: int
    inputHistory: seq[string]   # Stores up to 500 previous input strings
    inputHistoryIndex: int      # -1 means not browsing history

var
  termLock: SpinLock
  eventCh: Channel[UiEvent]
  running: Atomic[bool]
  lastBottomHeight: int = 4

proc initSpinLock(lock: var SpinLock) =
  lock.state.store(0)

proc acquireSpin(lock: var SpinLock) =
  while true:
    var expected = 0'i32
    if lock.state.compareExchange(expected, 1'i32):
      break
    sleep(1)

proc releaseSpin(lock: var SpinLock) =
  lock.state.store(0'i32)

proc postEvent(event: UiEvent) =
  var msg = event
  eventCh.send(msg)

proc tryPopEvent(event: var UiEvent): bool =
  let received = eventCh.tryRecv()
  if received.dataAvailable:
    event = received.msg
    return true
  false

proc initEditor(): Editor =
  result.lines = @[""]
  result.cursorLine = 0
  result.cursorCol = 0
  result.preferredCol = 0


proc setPreferredCol(e: var Editor) =
  e.preferredCol = e.cursorCol

proc resetEditorToText(e: var Editor, text: string) =
  e.lines = text.splitLines()
  e.cursorLine = e.lines.len - 1
  e.cursorCol = if e.lines.len > 0: e.lines[^1].len else: 0
  e.setPreferredCol()

proc moveLeft(e: var Editor) =
  if e.cursorCol > 0:
    dec e.cursorCol
  elif e.cursorLine > 0:
    dec e.cursorLine
    e.cursorCol = e.lines[e.cursorLine].len
  e.setPreferredCol()

proc moveRight(e: var Editor) =
  if e.cursorCol < e.lines[e.cursorLine].len:
    inc e.cursorCol
  elif e.cursorLine < e.lines.len - 1:
    inc e.cursorLine
    e.cursorCol = 0
  e.setPreferredCol()

proc moveUp(e: var Editor) =
  if e.cursorLine == 0:
    return
  dec e.cursorLine
  e.cursorCol = min(e.lines[e.cursorLine].len, e.preferredCol)

proc moveDown(e: var Editor) =
  if e.cursorLine >= e.lines.len - 1:
    return
  inc e.cursorLine
  e.cursorCol = min(e.lines[e.cursorLine].len, e.preferredCol)

proc moveHome(e: var Editor) =
  e.cursorCol = 0
  e.setPreferredCol()

proc moveEnd(e: var Editor) =
  e.cursorCol = e.lines[e.cursorLine].len
  e.setPreferredCol()

proc isWordBoundary(ch: char): bool =
  ch in {' ', '\t', '/', '\\', '-', '[', ']', '(', ')', '{', '}', '.', ','}

proc moveLeftWord(e: var Editor) =
  if e.cursorCol == 0 and e.cursorLine == 0:
    return
  if e.cursorCol == 0:
    dec e.cursorLine
    e.cursorCol = e.lines[e.cursorLine].len
  if e.cursorCol == 0:
    e.setPreferredCol()
    return
  dec e.cursorCol
  while e.cursorCol > 0 and not isWordBoundary(e.lines[e.cursorLine][e.cursorCol - 1]):
    dec e.cursorCol
  e.setPreferredCol()

proc moveRightWord(e: var Editor) =
  let maxLine = e.lines[e.cursorLine].len
  if e.cursorCol == maxLine:
    if e.cursorLine == e.lines.len - 1:
      return
    inc e.cursorLine
    e.cursorCol = 0
    while e.cursorCol < e.lines[e.cursorLine].len and isWordBoundary(e.lines[e.cursorLine][e.cursorCol]):
      inc e.cursorCol
    e.setPreferredCol()
    return
  inc e.cursorCol
  while e.cursorCol < e.lines[e.cursorLine].len and not isWordBoundary(e.lines[e.cursorLine][e.cursorCol]):
    inc e.cursorCol
  while e.cursorCol < e.lines[e.cursorLine].len and isWordBoundary(e.lines[e.cursorLine][e.cursorCol]):
    inc e.cursorCol
  e.setPreferredCol()

proc insertText(e: var Editor; text: string) =
  if text.len == 0:
    return
  let lineIdx = e.cursorLine
  let colIdx = e.cursorCol
  var segments = text.splitLines(keepEol = true)
  if segments.len == 1:
    e.lines[lineIdx].insert(text, colIdx)
    e.cursorCol += text.len
  else:
    var current = e.lines[lineIdx]
    let head = current[0 ..< colIdx]
    let tail = current[colIdx .. ^1]
    e.lines[lineIdx] = head & segments[0]
    var insertAt = lineIdx + 1
    for i in 1 ..< segments.len - 1:
      e.lines.insert(segments[i], insertAt)
      inc insertAt
    let lastSegment = segments[^1]
    e.lines.insert(lastSegment & tail, insertAt)
    e.cursorLine = insertAt
    e.cursorCol = lastSegment.len
  e.setPreferredCol()

proc deletePrevChar(e: var Editor) =
  if e.cursorCol > 0:
    e.lines[e.cursorLine].delete((e.cursorCol - 1) .. (e.cursorCol - 1))
    dec e.cursorCol
  elif e.cursorLine > 0:
    let prevLen = e.lines[e.cursorLine - 1].len
    e.lines[e.cursorLine - 1] &= e.lines[e.cursorLine]
    e.lines.delete(e.cursorLine)
    dec e.cursorLine
    e.cursorCol = prevLen
  e.setPreferredCol()

proc deleteCurrentChar(e: var Editor) =
  if e.cursorCol < e.lines[e.cursorLine].len:
    e.lines[e.cursorLine].delete(e.cursorCol .. e.cursorCol)
  elif e.cursorLine < e.lines.len - 1:
    e.lines[e.cursorLine] &= e.lines[e.cursorLine + 1]
    e.lines.delete(e.cursorLine + 1)
  e.setPreferredCol()

# Deletes from cursor to the next word separator (non-alphanumeric),
# but does NOT delete the separator itself unless starting on a separator,
# in which case all contiguous separators are deleted.
proc deleteToNextWordSeparator(e: var Editor) =
  let line = e.lines[e.cursorLine]
  var i = e.cursorCol
  if i < line.len and not line[i].isAlphaNumeric:
    # Starting on a separator: delete all contiguous separators
    while i < line.len and not line[i].isAlphaNumeric:
      inc i
    if i > e.cursorCol:
      e.lines[e.cursorLine].delete(e.cursorCol ..< i)
  else:
    # Starting on a word: delete up to (not including) next separator
    while i < line.len and line[i].isAlphaNumeric:
      inc i
    if i > e.cursorCol:
      e.lines[e.cursorLine].delete(e.cursorCol ..< i)

# Deletes from cursor to the previous word separator (non-alphanumeric),
# or to the start of line. If starting on a separator, deletes all contiguous separators before the cursor.
proc deleteToPrevWordSeparator(e: var Editor) =
  let line = e.lines[e.cursorLine]
  var i = e.cursorCol
  if i == 0: return
  var start = i
  # If starting on a separator, delete all contiguous separators before cursor
  if i > 0 and not line[i-1].isAlphaNumeric:
    while start > 0 and not line[start-1].isAlphaNumeric:
      dec start
    if start < i:
      e.lines[e.cursorLine].delete(start ..< i)
      e.cursorCol = start
      e.setPreferredCol()
      return
  # Otherwise, delete all contiguous word characters before cursor
  while start > 0 and line[start-1].isAlphaNumeric:
    dec start
  if start < i:
    e.lines[e.cursorLine].delete(start ..< i)
    e.cursorCol = start
    e.setPreferredCol()


proc clearEditor(e: var Editor) =
  e.lines = @[""]
  e.cursorLine = 0
  e.cursorCol = 0
  e.setPreferredCol()

proc currentText(e: Editor): string =
  result = e.lines.join("\n")

proc wrapLine(line: string; width: int): seq[Segment] =
  let effectiveWidth = max(width, 1)
  if line.len == 0:
    return @[Segment(start: 0, len: 0)]
  var start = 0
  while start < line.len:
    var breakPos = min(start + effectiveWidth, line.len)
    if breakPos < line.len:
      var lastSpace = -1
      for i in start ..< breakPos:
        if line[i] == ' ':
          lastSpace = i
      if lastSpace >= start:
        breakPos = lastSpace + 1
    let length = max(1, breakPos - start)
    result.add Segment(start: start, len: length)
    start += length

proc computeLayout(e: Editor; contentWidth: int): EditorLayout =
  var row = 0
  for lineIdx, line in e.lines:
    let segments = wrapLine(line, contentWidth)
    for segIdx, seg in segments:
      let sliceStart = seg.start
      let sliceEnd = min(seg.start + seg.len, line.len)
      if sliceStart >= sliceEnd:
        result.lines.add("")
      else:
        result.lines.add(line[sliceStart ..< sliceEnd])
      if lineIdx == e.cursorLine:
        let cursorTarget = e.cursorCol
        let segEndExclusive = seg.start + seg.len
        let lastSegment = segIdx == segments.len - 1
        if (cursorTarget >= seg.start and cursorTarget < segEndExclusive) or
           (lastSegment and cursorTarget == segEndExclusive):
          result.cursorRow = row
          result.cursorCol = max(0, cursorTarget - seg.start)
      inc row
  if result.lines.len == 0:
    result.lines.add("")
    result.cursorRow = 0
    result.cursorCol = 0

proc bottomPadding(layout: EditorLayout): int =
  layout.lines.len + 3

proc prepareBottom(state: var UiState): tuple[layout: EditorLayout, desiredHeight: int] =
  state.width = terminalWidth()
  state.height = terminalHeight()
  let contentWidth = max(1, state.width - editorIndent.len)
  result.layout = computeLayout(state.editor, contentWidth)
  result.desiredHeight = bottomPadding(result.layout)

  if state.editor.lines.len == 1 and state.editor.lines[0].len == 0:
    if state.stickyHeight == 0:
      state.stickyHeight = result.desiredHeight
  else:
    if result.desiredHeight > state.stickyHeight:
      state.stickyHeight = result.desiredHeight

  let effectiveSticky =
    if state.stickyHeight == 0: result.desiredHeight else: state.stickyHeight
  state.bottomHeight = max(result.desiredHeight, effectiveSticky)

proc drawBottomUnlocked(state: var UiState; sequential = false) =
  let bottomInfo = prepareBottom(state)
  let layout = bottomInfo.layout
  let desiredHeight = bottomInfo.desiredHeight
  let useSequential = sequential
  let baseRow = max(0, state.height - state.bottomHeight)
  let extraPad = max(0, state.bottomHeight - desiredHeight)
  let layoutRow = baseRow + extraPad
  let greyBlank = editorBgSeq & editorFgSeq & fillToEOL & ansiReset
  lastBottomHeight = state.bottomHeight

  if useSequential:
    for _ in 0 ..< extraPad:
      stdout.write(greyBlank)
      stdout.write("\n")
    stdout.write(greyBlank)
    stdout.write("\n")
    for i, line in layout.lines:
      stdout.write(editorBgSeq & editorFgSeq)
      if i == 0:
        stdout.write("› ")
      else:
        stdout.write(editorIndent)
      stdout.write(line)
      stdout.write(fillToEOL)
      stdout.write(ansiReset)
      stdout.write("\n")
    stdout.write(greyBlank)
    stdout.write("\n")
    var statusText = if state.status.len == 0: "Ready" else: state.status
    if statusText.len > state.width:
      statusText = statusText[0 ..< state.width]
    stdout.write("\e[0m\e[48;5;16m\e[38;5;238m")
    stdout.write(statusText)
    stdout.write("\e[0K")
    stdout.write(ansiReset)
  else:
    for idx in 0 ..< state.bottomHeight:
      setCursorPos(0, baseRow + idx)
      eraseLine()

    for padIdx in 0 ..< extraPad:
      setCursorPos(0, baseRow + padIdx)
      stdout.write(greyBlank)

    setCursorPos(0, layoutRow)
    stdout.write(greyBlank)

    for i, line in layout.lines:
      setCursorPos(0, layoutRow + 1 + i)
      stdout.write(editorBgSeq)
      stdout.write(editorFgSeq)
      if i == 0:
        stdout.write("› ")
        stdout.write(line)
      else:
        stdout.write(editorIndent)
        stdout.write(line)
      stdout.write("\e[0K")
      stdout.write(ansiReset)

    setCursorPos(0, layoutRow + 1 + layout.lines.len)
    stdout.write(greyBlank)

    setCursorPos(0, layoutRow + 2 + layout.lines.len)
    var statusText = if state.status.len == 0: "Ready" else: state.status
    if statusText.len > state.width:
      statusText = statusText[0 ..< state.width]
    stdout.write("\e[0m\e[48;5;16m\e[38;5;238m")
    stdout.write(statusText)
    stdout.write("\e[0K")
    stdout.write(ansiReset)

  let cursorRow = layoutRow + 1 + layout.cursorRow
  let cursorCol =
    if layout.cursorRow == 0: min(state.width - 1, 2 + layout.cursorCol)
    else: min(state.width - 1, editorIndent.len + layout.cursorCol)
  setCursorPos(cursorCol, cursorRow)
  stdout.flushFile()

proc drawBottom(state: var UiState) =
  acquireSpin(termLock)
  try:
    drawBottomUnlocked(state)
  finally:
    releaseSpin(termLock)

proc clearFooterRegion(baseRow, height, width: int) =
  for row in baseRow ..< height:
    setCursorPos(0, row)
    stdout.write(ansiReset)
    stdout.write(scrollbackBgSeq)
    stdout.write(scrollbackFgSeq)
    stdout.write("\e[0K")
    stdout.write(ansiReset)

proc appendDisplayUnlocked(state: var UiState; lines: openArray[string]) =
  if lines.len == 0:
    return
  let height = terminalHeight()
  let width = terminalWidth()
  let span = max(state.bottomHeight, max(state.stickyHeight, 4))
  let footerTop = max(0, height - span)
  clearFooterRegion(footerTop, height, width)
  setCursorPos(0, footerTop)
  for line in lines:
    stdout.write(ansiReset)
    stdout.write(scrollbackBgSeq)
    stdout.write(scrollbackFgSeq)
    if line.len <= width:
      stdout.write(line)
      if line.len < width:
        stdout.write("\e[0K")
        #stdout.write(' '.repeat(width - line.len))
    else:
      stdout.write(line)
    stdout.write(ansiReset)
    stdout.write("\n")
  stdout.flushFile()
  drawBottomUnlocked(state, sequential = true)

proc appendEditorHistoryUnlocked(state: var UiState; lines: openArray[string]) =
  # Similar to appendDisplayUnlocked but uses editor background/foreground styling
  if lines.len == 0:
    return
  let height = terminalHeight()
  let width = terminalWidth()
  let span = max(state.bottomHeight, max(state.stickyHeight, 4))
  let footerTop = max(0, height - span)
  clearFooterRegion(footerTop, height, width)
  setCursorPos(0, footerTop)
  stdout.write("\n")
  for line in lines:
    stdout.write(ansiReset & editorHistoryBgSeq & editorFgSeq)
    if line.len <= width:
      stdout.write(line)
    else:
      stdout.write(line)
    stdout.write("\e[0K" & ansiReset)
    stdout.write("\n")
  stdout.write("\n")
  stdout.flushFile()
  drawBottomUnlocked(state, sequential = true)

proc appendDisplay(state: var UiState; lines: openArray[string]) =
  if lines.len == 0:
    return
  acquireSpin(termLock)
  try:
    appendDisplayUnlocked(state, lines)
  finally:
    releaseSpin(termLock)

# helper functions for the editor go here

proc deleteToStartOfLine(e: var Editor) =
  if e.cursorCol > 0:
    e.lines[e.cursorLine].delete(0 ..< e.cursorCol)
    e.cursorCol = 0
  e.setPreferredCol()

proc deleteToEndOfLine(e: var Editor) =
  if e.cursorCol < e.lines[e.cursorLine].len:
    e.lines[e.cursorLine].delete(e.cursorCol ..< e.lines[e.cursorLine].len)

proc handleKey(state: var UiState; key: string) =
  acquireSpin(termLock)
  try:
    var needsRedraw = true
    case key
    of "ESC":
      state.running = false
      running.store(false)
      return
    of "DEL":
      state.editor.deletePrevChar()
      state.status = "Backspace"
    of "ESC[3~":
      state.editor.deleteCurrentChar()
      state.status = "Delete"
    of "ESC[3;5~":  # Ctrl-Delete
      state.editor.deleteToNextWordSeparator()
      state.status = "Delete to next word separator"
    of "BS": # Ctrl-Backspace
      state.editor.deleteToPrevWordSeparator()
      state.status = "Delete to previous word separator"
    of "VT": # Ctrl-K
      state.editor.deleteToEndOfLine()
      state.status = "Delete to end of line"
    of "NAK": # Ctrl-U
      state.editor.deleteToStartOfLine()
      state.status = "Delete to start of line"
    of "NL", "ESC\n", "ESC\r":
      let payload = state.editor.currentText()
      if payload.len > 0:
        let submitted = payload.splitLines()
        # Add to input history, avoid duplicates in a row
        if state.inputHistory.len == 0 or state.inputHistory[^1] != payload:
          state.inputHistory.add(payload)
          if state.inputHistory.len > 500:
            state.inputHistory.delete(0)
        state.inputHistoryIndex = -1
        # Clear editor first so redraw shows fresh prompt immediately.
        state.editor.clearEditor()
        state.stickyHeight = 0
        if showInputHistory:
          # Build history block: blank pad, each line with proper prompt/indent, blank pad.
          var historyLines: seq[string] = @[]
          historyLines.add("")
          for i, ln in submitted:
            let prefix = if i == 0: "› " else: editorIndent
            historyLines.add(prefix & ln)
          historyLines.add("")
          appendEditorHistoryUnlocked(state, historyLines)
          state.status = "Submitted text (history enabled)"
        else:
          appendDisplayUnlocked(state, submitted)
          state.status = "Submitted text"
        needsRedraw = false
      else:
        state.status = "Nothing to submit"
    of "ESC[5~": # PageUp - previous input
      if state.inputHistory.len > 0:
        if state.inputHistoryIndex == -1:
          state.inputHistoryIndex = state.inputHistory.len - 1
        elif state.inputHistoryIndex > 0:
          dec state.inputHistoryIndex
        state.editor.resetEditorToText(state.inputHistory[state.inputHistoryIndex])
        state.status = "Recalled previous input"
    of "ESC[6~": # PageDown - next input
      if state.inputHistory.len > 0 and state.inputHistoryIndex != -1:
        if state.inputHistoryIndex < state.inputHistory.len - 1:
          inc state.inputHistoryIndex
          state.editor.resetEditorToText(state.inputHistory[state.inputHistoryIndex])
          state.status = "Recalled next input"
        else:
          state.inputHistoryIndex = -1
          state.editor.clearEditor()
          state.status = "Input cleared"
    of "ESC[H", "SOH":
      state.editor.moveHome()
      state.status = "Home"
    of "ESC[F", "ENQ":
      state.editor.moveEnd()
      state.status = "End"
    of "ESC[A":
      state.editor.moveUp()
      state.status = "Cursor up"
    of "ESC[B":
      state.editor.moveDown()
      state.status = "Cursor down"
    of "ESC[D":
      state.editor.moveLeft()
      state.status = "Cursor left"
    of "ESC[C":
      state.editor.moveRight()
      state.status = "Cursor right"
    of "ESC[1;5D":
      state.editor.moveLeftWord()
      state.status = "Word left"
    of "ESC[1;5C":
      state.editor.moveRightWord()
      state.status = "Word right"
    else:
      if key.len == 1:
        state.editor.insertText(key)
        state.status = "Typing"
      else:
        state.status = "Unhandled: " & key
    if needsRedraw:
      drawBottomUnlocked(state, false)
  finally:
    releaseSpin(termLock)

proc keyLoop() {.thread.} =
  while running.load():
    let keys = getKey()
    for keyEvent in keys:
      postEvent(UiEvent(kind: evKey, key: keyEvent))
    if keys.len == 0:
      sleep(keyPollIntervalMs)

proc sampleFeedLoop() {.thread.} =
  var counter = 1
  while running.load():
    var remaining = feedIntervalMs
    while remaining > 0 and running.load():
      let chunk = min(feedSleepSliceMs, remaining)
      sleep(chunk.int)
      remaining -= chunk
    if not running.load():
      break
    if not running.load():
      break
    let timeStamp = now().format("HH:mm:ss")
    let line = &"({timeStamp}) background event #{counter}"
    inc counter
    postEvent(UiEvent(kind: evAppend, lines: @[line]))

proc mainLoop() =
  var state = UiState(
    width: terminalWidth(),
    height: terminalHeight(),
    status: "Ready",
    editor: initEditor(),
    bottomHeight: 4,
    running: true,
    stickyHeight: 4
  )
  drawBottom(state)

  var resizeTicker = epochTime()
  while state.running:
    var event: UiEvent
    if tryPopEvent(event):
      case event.kind
      of evKey:
        handleKey(state, event.key)
      of evAppend:
        appendDisplay(state, event.lines)
      of evStatus:
        state.status = event.status
        drawBottom(state)
    else:
      let nowTime = epochTime()
      if (nowTime - resizeTicker) * 1000 >= resizePollIntervalMs.float:
        resizeTicker = nowTime
        let currentW = terminalWidth()
        let currentH = terminalHeight()
        if currentW != state.width or currentH != state.height:
          drawBottom(state)
      sleep(10)

proc shutdown(termWasRaw: bool) =
  if termWasRaw:
    let height = terminalHeight()
    let width = terminalWidth()
    let bottom = max(3, lastBottomHeight)
    let baseRow = max(0, height - bottom)
    clearFooterRegion(baseRow, height, width)
    setCursorPos(0, baseRow)
    disable_raw_mode()
  stdout.write(ansiReset)
  stdout.flushFile()

when isMainModule:
  initSpinLock(termLock)
  eventCh.open()
  running.store(true)
  var rawEnabled = false
  enable_raw_mode()
  rawEnabled = true
  var keyThread, feedThread: Thread[void]
  createThread(keyThread, keyLoop)
  createThread(feedThread, sampleFeedLoop)
  try:
    mainLoop()
  finally:
    running.store(false)
    joinThread(keyThread)
    joinThread(feedThread)
    shutdown(rawEnabled)
