#
## A scrollable TUI very similar to OpenAI-codex.
##
## This is designed to be included in your main module.
## If you have background threads, then you should call
## scrollpad.isScrollpadRunning() to determine
## if the scrollpad thread is still running.

import std/[atomics, os, strutils, terminal, times]
import key

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
    inputHistory: seq[string] # Stores up to 500 previous input strings
    inputHistoryIndex: int    # -1 means not browsing history

  EditorLayout = object
    lines: seq[string]
    cursorRow: int
    cursorCol: int

  SpinLock = object
    state: Atomic[int32]

  SubmitCallback* = proc(text: string) {.nimcall.}

  ThreadEntry = ref object
    thr: Thread[void]

  Scrollpad = object
    width: int
    height: int
    status: string
    debugStatus: string
    editor: Editor
    bottomHeight: int
    stickyHeight: int
    submitCallback: SubmitCallback
    threads: seq[ThreadEntry]

const
  keyPollIntervalMs = 12
  resizePollIntervalMs = 100
  fillToEOL = "\e[0K"
  ansiReset = "\e[0m"

var
  editorColorSeq* = "\e[48;5;235m\e[38;5;252m" ## dark grey bg + white fg for editor
  editorHistoryColorSeq* = "\e[48;5;233m\e[38;5;252m" ## very dark gray bg + white fg for editor history
  scrollbackColorSeq* = "\e[48;5;16m\e[38;5;252m" ## normal scrollback bg + fg color
  errorColorSeq* = "\e[48;5;52m\e[38;5;15m" ## dark red with white foreground
  editorPrompt* = "› "                    ## first-line prompt
  editorPrompt2* = "  "                     ## second-line prompt
  editorPromptLen* = 2                      ## display length of editorPrompt & editorPrompt2

  showInputHistory* = true ## should submitted input appear in scrollback with highlighting
  shouldEscapeStop* = true ## should pressing the escape key call stopScrollpad() to quit?
  termLock: SpinLock
  eventCh: Channel[UiEvent]
  running: Atomic[bool]
  lastBottomHeight: int = 4
  pad: Scrollpad

#
# SpinLock primitives
#
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

#
# post and pop events to/from the event channel
#
proc postEvent(event: UiEvent) =
  var msg = event
  eventCh.send(msg)

proc tryPopEvent(event: var UiEvent): bool =
  let received = eventCh.tryRecv()
  if received.dataAvailable:
    event = received.msg
    return true
  false

#
# editor related procs
#
proc initEditor(): Editor =
  result.lines = @[""]
  result.cursorLine = 0
  result.cursorCol = 0
  result.preferredCol = 0
  result.inputHistory = @[]
  result.inputHistoryIndex = -1

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
  ## move cursor one word to the left
  if e.cursorCol == 0 and e.cursorLine == 0:
    return
  if e.cursorCol == 0:
    dec e.cursorLine
    e.cursorCol = e.lines[e.cursorLine].len
  if e.cursorCol == 0:
    e.setPreferredCol()
    return
  dec e.cursorCol
  while e.cursorCol > 0 and not isWordBoundary(e.lines[e.cursorLine][
      e.cursorCol - 1]):
    dec e.cursorCol
  e.setPreferredCol()

proc moveRightWord(e: var Editor) =
  ## move cursor one word to the right
  let maxLine = e.lines[e.cursorLine].len
  if e.cursorCol == maxLine:
    if e.cursorLine == e.lines.len - 1:
      return
    inc e.cursorLine
    e.cursorCol = 0
    while e.cursorCol < e.lines[e.cursorLine].len and isWordBoundary(e.lines[
        e.cursorLine][e.cursorCol]):
      inc e.cursorCol
    e.setPreferredCol()
    return
  inc e.cursorCol
  while e.cursorCol < e.lines[e.cursorLine].len and not isWordBoundary(e.lines[
      e.cursorLine][e.cursorCol]):
    inc e.cursorCol
  while e.cursorCol < e.lines[e.cursorLine].len and isWordBoundary(e.lines[
      e.cursorLine][e.cursorCol]):
    inc e.cursorCol
  e.setPreferredCol()

proc insertText(e: var Editor; text: string) =
  ## insert text at the current cursor position
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

proc deleteToNextWordSeparator(e: var Editor) =
  ## Deletes from cursor to the next word separator (non-alphanumeric),
  ## but does NOT delete the separator itself unless starting on a separator,
  ## in which case all contiguous separators are deleted.
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

proc deleteToPrevWordSeparator(e: var Editor) =
  ## Deletes from cursor to the previous word separator (non-alphanumeric),
  ## or to the start of line. If starting on a separator, deletes all contiguous separators before the cursor.
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

proc previousInputHistory(e: var Editor) =
  if e.inputHistory.len > 0:
    if e.inputHistoryIndex == -1:
      e.inputHistoryIndex = e.inputHistory.len - 1
    elif e.inputHistoryIndex > 0:
      dec e.inputHistoryIndex
    e.resetEditorToText(e.inputHistory[e.inputHistoryIndex])

proc nextInputHistory(e: var Editor) =
  if e.inputHistory.len > 0 and e.inputHistoryIndex != -1:
    if e.inputHistoryIndex < e.inputHistory.len - 1:
      inc e.inputHistoryIndex
      e.resetEditorToText(e.inputHistory[e.inputHistoryIndex])
    else:
      e.inputHistoryIndex = -1
      e.clearEditor()

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

proc prepareBottom(pad: var Scrollpad): tuple[layout: EditorLayout,
    desiredHeight: int] =
  pad.width = terminalWidth()
  pad.height = terminalHeight()
  let contentWidth = max(1, pad.width - editorPromptLen)
  result.layout = computeLayout(pad.editor, contentWidth)
  result.desiredHeight = bottomPadding(result.layout)

  if pad.editor.lines.len == 1 and pad.editor.lines[0].len == 0:
    if pad.stickyHeight == 0:
      pad.stickyHeight = result.desiredHeight
  else:
    if result.desiredHeight > pad.stickyHeight:
      pad.stickyHeight = result.desiredHeight

  let effectiveSticky =
    if pad.stickyHeight == 0: result.desiredHeight else: pad.stickyHeight
  pad.bottomHeight = max(result.desiredHeight, effectiveSticky)

proc drawBottomUnlocked(pad: var Scrollpad; sequential = false) =
  let bottomInfo = prepareBottom(pad)
  let layout = bottomInfo.layout
  let desiredHeight = bottomInfo.desiredHeight
  let useSequential = sequential
  let baseRow = max(0, pad.height - pad.bottomHeight)
  let extraPad = max(0, pad.bottomHeight - desiredHeight)
  let layoutRow = baseRow + extraPad
  let greyBlank = editorColorSeq & fillToEOL & ansiReset
  lastBottomHeight = pad.bottomHeight

  if useSequential:
    for _ in 0 ..< extraPad:
      stdout.write(greyBlank)
      stdout.write("\n")
    stdout.write(greyBlank)
    stdout.write("\n")
    for i, line in layout.lines:
      stdout.write(editorColorSeq)
      if i == 0:
        stdout.write(editorPrompt)
      else:
        # write spaces matching the prompt length so wrapped lines align
        stdout.write(editorPrompt2)
      stdout.write(line)
      stdout.write(fillToEOL)
      stdout.write(ansiReset)
      stdout.write("\n")
    stdout.write(greyBlank)
    stdout.write("\n")
    var statusText = pad.status
    if statusText == "":
      statusText = pad.debugStatus
    if statusText.len > pad.width:
      statusText = statusText[0 ..< pad.width]
    stdout.write("\e[0m\e[48;5;16m\e[38;5;238m")
    stdout.write(statusText)
    stdout.write("\e[0K")
    stdout.write(ansiReset)
  else:
    for idx in 0 ..< pad.bottomHeight:
      setCursorPos(0, baseRow + idx)
      eraseLine()

    for padIdx in 0 ..< extraPad:
      setCursorPos(0, baseRow + padIdx)
      stdout.write(greyBlank)

    setCursorPos(0, layoutRow)
    stdout.write(greyBlank)

    for i, line in layout.lines:
      setCursorPos(0, layoutRow + 1 + i)
      stdout.write(editorColorSeq)
      if i == 0:
        stdout.write(editorPrompt)
        stdout.write(line)
      else:
        # show the editor prompt2 on wrapped lines
        stdout.write(editorPrompt2)
        stdout.write(line)
      stdout.write("\e[0K")
      stdout.write(ansiReset)

    setCursorPos(0, layoutRow + 1 + layout.lines.len)
    stdout.write(greyBlank)

    setCursorPos(0, layoutRow + 2 + layout.lines.len)
    var statusText = pad.status
    if statusText == "":
      statusText = pad.debugStatus
    if statusText.len > pad.width:
      statusText = statusText[0 ..< pad.width]
    stdout.write("\e[0m\e[48;5;16m\e[38;5;238m")
    stdout.write(statusText)
    stdout.write("\e[0K")
    stdout.write(ansiReset)

  let cursorRow = layoutRow + 1 + layout.cursorRow
  let cursorCol =
    if layout.cursorRow == 0: min(pad.width - 1, editorPromptLen +
        layout.cursorCol)
    else: min(pad.width - 1, editorPromptLen + layout.cursorCol)
  setCursorPos(cursorCol, cursorRow)
  stdout.flushFile()

proc drawBottom(pad: var Scrollpad) =
  acquireSpin(termLock)
  try:
    drawBottomUnlocked(pad)
  finally:
    releaseSpin(termLock)

proc clearFooterRegion(baseRow, height, width: int) =
  for row in baseRow ..< height:
    setCursorPos(0, row)
    stdout.write(ansiReset)
    stdout.write(fillToEOL)

proc appendDisplayUnlocked(pad: var Scrollpad; lines: openArray[string]) =
  if lines.len == 0:
    return
  let height = terminalHeight()
  let width = terminalWidth()
  let span = max(pad.bottomHeight, max(pad.stickyHeight, 4))
  let footerTop = max(0, height - span)
  clearFooterRegion(footerTop, height, width)
  setCursorPos(0, footerTop)
  for line in lines:
    stdout.write(ansiReset)
    stdout.write(scrollbackColorSeq)
    if line.len <= width:
      stdout.write(line)
      if line.len < width:
        stdout.write(fillToEOL)
    else:
      stdout.write(line)
    stdout.write(ansiReset)
    stdout.write("\n")
  stdout.flushFile()
  drawBottomUnlocked(pad, sequential = true)

proc appendEditorHistoryUnlocked(pad: var Scrollpad; lines: openArray[string]) =
  # Similar to appendDisplayUnlocked but uses editor background/foreground styling
  if lines.len == 0:
    return
  let height = terminalHeight()
  let width = terminalWidth()
  let span = max(pad.bottomHeight, max(pad.stickyHeight, 4))
  let footerTop = max(0, height - span)
  clearFooterRegion(footerTop, height, width)
  setCursorPos(0, footerTop)
  stdout.write(ansiReset & fillToEOL & "\n")
  for line in lines:
    stdout.write(ansiReset & editorHistoryColorSeq)
    if line.len <= width:
      stdout.write(line)
    else:
      stdout.write(line)
    stdout.write("\e[0K" & ansiReset)
    stdout.write("\n")
  stdout.write(ansiReset & fillToEOL & "\n")
  stdout.flushFile()
  drawBottomUnlocked(pad, sequential = true)

proc appendDisplay(pad: var Scrollpad; lines: openArray[string]) =
  if lines.len == 0:
    return
  acquireSpin(termLock)
  try:
    appendDisplayUnlocked(pad, lines)
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

proc submitInput(pad: var Scrollpad) =
  let payload = pad.editor.currentText()
  if payload.len > 0:
    let submitted = payload.splitLines()
    # Add to input history, avoid duplicates in a row
    if pad.editor.inputHistory.len == 0 or pad.editor.inputHistory[^1] != payload:
      pad.editor.inputHistory.add(payload)
      if pad.editor.inputHistory.len > 500:
        pad.editor.inputHistory.delete(0)
    pad.editor.inputHistoryIndex = -1
    # Call submitCallback if configured
    {.gcsafe.}:
      if not isNil(pad.submitCallback):
        pad.submitCallback(payload)
    # Clear editor first so redraw shows fresh prompt immediately.
    pad.editor.clearEditor()
    pad.stickyHeight = 0
    if showInputHistory:
      # Build history block: blank pad, each submitted line wrapped to the
      # same content width the editor uses and prefixed with editorPrompt for
      # the first visual row and editorPrompt2 for wrapped continuation rows.
      pad.width = terminalWidth()
      let contentWidth = max(1, pad.width - editorPromptLen)
      var historyLines: seq[string] = @[]
      historyLines.add("")
      for ln in submitted:
        let segments = wrapLine(ln, contentWidth)
        for j, seg in segments:
          let sliceStart = seg.start
          let sliceEnd = min(seg.start + seg.len, ln.len)
          let segText = if sliceStart >= sliceEnd: "" else: ln[sliceStart ..< sliceEnd]
          let prefix = if j == 0: editorPrompt else: editorPrompt2
          historyLines.add(prefix & segText)
      historyLines.add("")
      appendEditorHistoryUnlocked(pad, historyLines)
      pad.debugStatus = "Submitted text (history enabled)"
    else:
      appendDisplayUnlocked(pad, submitted)
      pad.debugStatus = "Submitted text"
  else:
    pad.debugStatus = "Nothing to submit"

proc handleKey(pad: var Scrollpad; key: string) =
  ## handleKey is called by the mainloop to process new keystroke events
  ## generated by the keyLoop thread
  acquireSpin(termLock)
  try:
    var needsRedraw = true
    case key
    of "ESC":
      if shouldEscapeStop:
        running.store(false)
      return
    of "DEL":
      pad.editor.deletePrevChar()
      pad.debugStatus = "Backspace"
    of "ESC[3~":
      pad.editor.deleteCurrentChar()
      pad.debugStatus = "Delete"
    of "ESC[3;5~": # Ctrl-Delete
      pad.editor.deleteToNextWordSeparator()
      pad.debugStatus = "Delete to next word separator"
    of "BS": # Ctrl-Backspace
      pad.editor.deleteToPrevWordSeparator()
      pad.debugStatus = "Delete to previous word separator"
    of "VT": # Ctrl-K
      pad.editor.deleteToEndOfLine()
      pad.debugStatus = "Delete to end of line"
    of "NAK": # Ctrl-U
      pad.editor.deleteToStartOfLine()
      pad.debugStatus = "Delete to start of line"
    of "NL", "ESC\n", "ESC\r":
      submitInput(pad)
      needsRedraw = false
    of "ESC[5~": # PageUp - previous input
      pad.editor.previousInputHistory()
      pad.debugStatus = "Recalled previous input"
    of "ESC[6~": # PageDown - next input
      pad.editor.nextInputHistory()
      if pad.editor.inputHistoryIndex == -1:
        pad.debugStatus = "Input cleared"
      else:
        pad.debugStatus = "Recalled next input"
    of "ESC[H", "SOH":
      pad.editor.moveHome()
      pad.debugStatus = "Home"
    of "ESC[F", "ENQ":
      pad.editor.moveEnd()
      pad.debugStatus = "End"
    of "ESC[A":
      pad.editor.moveUp()
      pad.debugStatus = "Cursor up"
    of "ESC[B":
      pad.editor.moveDown()
      pad.debugStatus = "Cursor down"
    of "ESC[D":
      pad.editor.moveLeft()
      pad.debugStatus = "Cursor left"
    of "ESC[C":
      pad.editor.moveRight()
      pad.debugStatus = "Cursor right"
    of "ESC[1;5D":
      pad.editor.moveLeftWord()
      pad.debugStatus = "Word left"
    of "ESC[1;5C":
      pad.editor.moveRightWord()
      pad.debugStatus = "Word right"
    else:
      if key.len == 1:
        pad.editor.insertText(key)
        pad.debugStatus = "Typing"
      else:
        pad.debugStatus = "Unhandled: " & key
    if needsRedraw:
      drawBottomUnlocked(pad, false)
  finally:
    releaseSpin(termLock)

# the keyLoop thread processes keyboard input
proc keyLoop() {.thread.} =
  while running.load():
    let keys = getKey()
    for keyEvent in keys:
      postEvent(UiEvent(kind: evKey, key: keyEvent))
    if keys.len == 0:
      sleep(keyPollIntervalMs)


proc mainLoop(pad: var Scrollpad) =
  drawBottom(pad)

  var resizeTicker = epochTime()
  # drain all pending events before quitting
  while true:
    var event: UiEvent
    if tryPopEvent(event):
      case event.kind
      of evKey:
        handleKey(pad, event.key)
      of evAppend:
        appendDisplay(pad, event.lines)
      of evStatus:
        pad.status = event.status
        drawBottom(pad)
    elif not running.load():
      break
    else:
      let nowTime = epochTime()
      if (nowTime - resizeTicker) * 1000 >= resizePollIntervalMs.float:
        resizeTicker = nowTime
        let currentW = terminalWidth()
        let currentH = terminalHeight()
        if currentW != pad.width or currentH != pad.height:
          drawBottom(pad)
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
  stdout.write(fillToEOL)
  stdout.flushFile()

proc newScrollpad(): Scrollpad =
  result.width = terminalWidth()
  result.height = terminalHeight()
  result.status = ""
  result.debugStatus = ""
  result.editor = initEditor()
  result.bottomHeight = 4
  result.stickyHeight = 4
  result.submitCallback = nil

proc print*(items: varargs[string, `$`]) =
  ## Format arguments similar to Nim's echo and post them to the UI via postEvent.
  var parts: seq[string] = @[]
  for i in items:
    # Use $ to stringify values similar to echo
    parts.add($i)
  let line = parts.join(" ")
  postEvent(UiEvent(kind: evAppend, lines: @[line]))

proc printError*(items: varargs[string, `$`]) =
  ## print to pad, similar to echo
  var parts: seq[string] = @[]
  for i in items:
    parts.add($i)
  let line = errorColorSeq & parts.join(" ")
  postEvent(UiEvent(kind: evAppend, lines: @[line]))

proc setInputCallback*(cb: SubmitCallback) =
  ## Register an input handler
  pad.submitCallback = cb

proc runScrollpad*() =
  ## Start the Scrollpad & input thread, etc.  Call stopScrollpad() to stop it
  running.store(true)
  var rawEnabled = false
  enable_raw_mode()
  rawEnabled = true
  var keyThread: Thread[void]
  createThread(keyThread, keyLoop)
  try:
    mainLoop(pad)
  finally:
    running.store(false)
    joinThread(keyThread)
    shutdown(rawEnabled)

proc isScrollpadRunning*(): bool =
  ## check if scrollpad is still in a running state
  running.load()

proc stopScrollpad*() =
  ## stop scrollpad execution and return from runScrollpad()
  running.store(false)

proc setScrollpadStatusBar*(status: string) =
  ## set the string shown in the statusBar
  pad.status = status

proc getScrollpadWidth*(): int =
  ## return the width of the scrollpad (terminal width)
  pad.width

proc getScrollpadHeight*(): int =
  ## return the height of the scrollpad (terminal height)
  pad.height

# Initialize spin locks and create the main scrollpad
initSpinLock(termLock)
pad = newScrollpad()
pad.debugStatus = "Scrollpad TUI - Press ESC to exit"
eventCh.open()

when isMainModule:
  import strformat
  const
    feedIntervalMs = 800
    feedSleepSliceMs = 40
  proc sampleFeedLoop() {.thread.} =
    var counter = 1
    while isScrollpadRunning():
      var remaining = feedIntervalMs
      while remaining > 0 and isScrollpadRunning():
        let chunk = min(feedSleepSliceMs, remaining)
        sleep(chunk.int)
        remaining -= chunk
      if not isScrollpadRunning():
        break
      let timeStamp = now().format("HH:mm:ss")
      let line = &"({timeStamp}) background event #{counter}"
      inc counter
      print(line)

  #showInputHistory = false
  setInputCallback(proc(text: string) {.nimcall.} =
    if text == "/quit":
      print "See you later, alligator!"
      running.store(false)
      return
    setScrollpadStatusBar("You submitted some text...")
    print "Hi there!  You submitted:", text
    printError "This is an error message."
  )
  var t: Thread[void]
  createThread(t, sampleFeedLoop)
  try:
    runScrollpad()
  finally:
    joinThread(t)
