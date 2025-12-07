#
## A scrollable TUI very similar to OpenAI-codex.
##
## This is designed to be included in your main module.
## If you have background async tasks, then you should call
## scrollpad.isScrollpadRunning() to determine
## if the scrollpad is still running.

import std/[asyncdispatch, strutils, terminal, times]
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
    draftBuffer: string       # Unsaved in-progress text preserved when entering history navigation

  EditorLayout = object
    lines: seq[string]
    cursorRow: int
    cursorCol: int

  SubmitCallback* = proc(text: string) {.nimcall.}

  Scrollpad = ref object
    width: int
    height: int
    status: string
    debugStatus: string
    editor: Editor
    bottomHeight: int
    stickyHeight: int
    submitCallback: SubmitCallback

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
  eventQueue: seq[UiEvent]
  running: bool = false
  # Start at 0 so first draw will detect growth and scroll the terminal to
  # make room for the editor/footer instead of overwriting existing text.
  lastBottomHeight: int = 0
  pad: Scrollpad

#
# post and pop events to/from the event queue
#
proc postEvent(event: UiEvent) =
  eventQueue.add(event)

proc tryPopEvent(event: var UiEvent): bool =
  if eventQueue.len > 0:
    event = eventQueue[0]
    eventQueue.delete(0)
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
  result.draftBuffer = ""

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

proc splitTextSegments(text: string): seq[string] =
  ## Splits text into logical lines, treating CR, LF, or CRLF as separators.
  if text.len == 0:
    return @[text]
  var current = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    let ch = text[i]
    if ch == '\r':
      result.add(current)
      current.setLen(0)
      if i + 1 < text.len and text[i + 1] == '\n':
        inc i
    elif ch == '\n':
      result.add(current)
      current.setLen(0)
    else:
      current.add(ch)
    inc i
  result.add(current)

proc insertText(e: var Editor; text: string) =
  ## insert text at the current cursor position
  if text.len == 0:
    return
  let lineIdx = e.cursorLine
  let colIdx = e.cursorCol
  let segments = splitTextSegments(text)
  if segments.len == 1:
    e.lines[lineIdx].insert(segments[0], colIdx)
    e.cursorCol += segments[0].len
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
  e.draftBuffer = "" # clearing editor invalidates draft

proc currentText(e: Editor): string =
  result = e.lines.join("\n")

proc previousInputHistory(e: var Editor) =
  if e.inputHistory.len > 0:
    if e.inputHistoryIndex == -1:
      # First time entering history: preserve current unsent text
      let cur = e.currentText()
      if cur.len > 0:
        e.draftBuffer = cur
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
      # Leaving history: restore draft if available
      if e.draftBuffer.len > 0:
        e.resetEditorToText(e.draftBuffer)
      else:
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

proc moveUpVisual(e: var Editor; contentWidth: int) =
  ## Move cursor up one visual row, handling wrapped lines
  let line = e.lines[e.cursorLine]
  let segments = wrapLine(line, contentWidth)
  
  # Find which segment we're currently in
  var currentSegIdx = -1
  for i, seg in segments:
    if e.cursorCol >= seg.start and (e.cursorCol < seg.start + seg.len or 
       (i == segments.len - 1 and e.cursorCol == seg.start + seg.len)):
      currentSegIdx = i
      break
  
  if currentSegIdx > 0:
    # Move to previous segment in same logical line
    let prevSeg = segments[currentSegIdx - 1]
    let relativeCol = e.cursorCol - segments[currentSegIdx].start
    e.cursorCol = min(prevSeg.start + relativeCol, prevSeg.start + prevSeg.len - 1)
    if e.cursorCol < prevSeg.start:
      e.cursorCol = prevSeg.start
  elif e.cursorLine > 0:
    # Move to previous logical line
    dec e.cursorLine
    let prevLine = e.lines[e.cursorLine]
    let prevSegments = wrapLine(prevLine, contentWidth)
    if prevSegments.len > 0:
      let lastSeg = prevSegments[^1]
      let relativeCol = if currentSegIdx >= 0: e.cursorCol - segments[currentSegIdx].start else: 0
      e.cursorCol = min(lastSeg.start + relativeCol, prevLine.len)

proc moveDownVisual(e: var Editor; contentWidth: int) =
  ## Move cursor down one visual row, handling wrapped lines
  let line = e.lines[e.cursorLine]
  let segments = wrapLine(line, contentWidth)
  
  # Find which segment we're currently in
  var currentSegIdx = -1
  for i, seg in segments:
    if e.cursorCol >= seg.start and (e.cursorCol < seg.start + seg.len or 
       (i == segments.len - 1 and e.cursorCol == seg.start + seg.len)):
      currentSegIdx = i
      break
  
  if currentSegIdx >= 0 and currentSegIdx < segments.len - 1:
    # Move to next segment in same logical line
    let nextSeg = segments[currentSegIdx + 1]
    let relativeCol = e.cursorCol - segments[currentSegIdx].start
    e.cursorCol = min(nextSeg.start + relativeCol, line.len)
  elif e.cursorLine < e.lines.len - 1:
    # Move to next logical line
    inc e.cursorLine
    let nextLine = e.lines[e.cursorLine]
    let nextSegments = wrapLine(nextLine, contentWidth)
    if nextSegments.len > 0:
      let firstSeg = nextSegments[0]
      let relativeCol = if currentSegIdx >= 0: e.cursorCol - segments[currentSegIdx].start else: 0
      e.cursorCol = min(firstSeg.start + relativeCol, nextLine.len)

proc moveHomeVisual(e: var Editor; contentWidth: int) =
  ## Move cursor to the start of the current visual line (wrapped segment)
  let line = e.lines[e.cursorLine]
  let segments = wrapLine(line, contentWidth)
  
  # Find which segment we're currently in
  for i, seg in segments:
    if e.cursorCol >= seg.start and (e.cursorCol < seg.start + seg.len or 
       (i == segments.len - 1 and e.cursorCol == seg.start + seg.len)):
      e.cursorCol = seg.start
      e.setPreferredCol()
      return
  
  # Fallback: go to start of line
  e.cursorCol = 0
  e.setPreferredCol()

proc moveEndVisual(e: var Editor; contentWidth: int) =
  ## Move cursor to the end of the current visual line (wrapped segment)
  let line = e.lines[e.cursorLine]
  let segments = wrapLine(line, contentWidth)
  
  # Find which segment we're currently in
  for i, seg in segments:
    if e.cursorCol >= seg.start and (e.cursorCol < seg.start + seg.len or 
       (i == segments.len - 1 and e.cursorCol == seg.start + seg.len)):
      # Move to end of this segment
      if i == segments.len - 1:
        # Last segment: go to end of line
        e.cursorCol = line.len
      else:
        # Not last segment: go to end of segment (just before next segment starts)
        let nextSeg = segments[i + 1]
        e.cursorCol = nextSeg.start - 1
        # Handle trailing spaces that were used for wrapping
        while e.cursorCol > seg.start and e.cursorCol < line.len and line[e.cursorCol] == ' ':
          inc e.cursorCol
        if e.cursorCol >= nextSeg.start:
          e.cursorCol = nextSeg.start - 1
      e.setPreferredCol()
      return
  
  # Fallback: go to end of line
  e.cursorCol = line.len
  e.setPreferredCol()

proc moveAbsoluteHome(e: var Editor) =
  ## Move to the very beginning of the input (first line, first character)
  e.cursorLine = 0
  e.cursorCol = 0
  e.setPreferredCol()

proc moveAbsoluteEnd(e: var Editor) =
  ## Move to the very end of the input (last line, last character)
  e.cursorLine = e.lines.len - 1
  e.cursorCol = e.lines[e.cursorLine].len
  e.setPreferredCol()

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

proc prepareBottom(pad: Scrollpad): tuple[layout: EditorLayout,
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

proc drawBottomUnlocked(pad: Scrollpad; sequential = false) =
  # remember previous bottom height so we can scroll the terminal
  let prevBottom = lastBottomHeight
  let bottomInfo = prepareBottom(pad)
  let layout = bottomInfo.layout
  let desiredHeight = bottomInfo.desiredHeight
  let useSequential = sequential
  let baseRow = max(0, pad.height - pad.bottomHeight)
  let extraPad = max(0, pad.bottomHeight - desiredHeight)
  let layoutRow = baseRow + extraPad
  let greyBlank = editorColorSeq & fillToEOL & ansiReset
  # If the bottom area grew since last draw, scroll the terminal up to make room
  let grow = pad.bottomHeight - prevBottom
  if grow > 0:
    # CSI <n> S — scroll up by n lines (add blank lines at bottom)
    stdout.write("\e[" & $grow & "S")
    stdout.flushFile()
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

proc drawBottom(pad: Scrollpad) =
  drawBottomUnlocked(pad)

proc clearFooterRegion(baseRow, height, width: int) =
  for row in baseRow ..< height:
    setCursorPos(0, row)
    stdout.write(ansiReset)
    stdout.write(fillToEOL)

proc appendDisplayUnlocked(pad: Scrollpad; lines: openArray[string]) =
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

proc appendEditorHistoryUnlocked(pad: Scrollpad; lines: openArray[string]) =
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

proc appendDisplay(pad: Scrollpad; lines: openArray[string]) =
  if lines.len == 0:
    return
  appendDisplayUnlocked(pad, lines)

# helper functions for the editor go here

proc deleteToStartOfLine(e: var Editor) =
  if e.cursorCol > 0:
    e.lines[e.cursorLine].delete(0 ..< e.cursorCol)
    e.cursorCol = 0
  e.setPreferredCol()

proc deleteToEndOfLine(e: var Editor) =
  if e.cursorCol < e.lines[e.cursorLine].len:
    e.lines[e.cursorLine].delete(e.cursorCol ..< e.lines[e.cursorLine].len)

proc submitInput(pad: Scrollpad) =
  let payload = pad.editor.currentText()
  if payload.len > 0:
    let submitted = payload.splitLines()
    # Add to input history, avoid duplicates in a row
    if pad.editor.inputHistory.len == 0 or pad.editor.inputHistory[^1] != payload:
      pad.editor.inputHistory.add(payload)
      if pad.editor.inputHistory.len > 500:
        pad.editor.inputHistory.delete(0)
    pad.editor.inputHistoryIndex = -1
    pad.editor.draftBuffer = "" # draft consumed on successful submit
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
      pad.debugStatus = "Submitted text"
  else:
    pad.debugStatus = "Nothing to submit"

proc handleKey(pad: Scrollpad; key: string) =
  ## handleKey is called by the mainloop to process new keystroke events
  ## generated by the keyLoop async proc
  var needsRedraw = true
  case key
  of "ESC[27;5u":  # control-escape
    running = false
  of "ESC", "ESC[27u", "ESC[27;2u":
    if shouldEscapeStop:
      running = false
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
  of "BS", "ESC[127;5u": # Ctrl-Backspace
    pad.editor.deleteToPrevWordSeparator()
    pad.debugStatus = "Delete to previous word separator"
  of "VT", "ESC[107;5u": # Ctrl-K
    pad.editor.deleteToEndOfLine()
    pad.debugStatus = "Delete to end of line"
  of "NAK", "ESC[117;5u": # Ctrl-U
    pad.editor.deleteToStartOfLine()
    pad.debugStatus = "Delete to start of line"
  of "CAN+NL", "ESC[13;2u":
    pad.editor.insertText("\n")
    pad.debugStatus = "Soft return"
  of "NL", "ESC\n", "ESC\r":
    submitInput(pad)
    needsRedraw = false
  of "ESC[5~", "ESC[5;5~": # PageUp or Ctrl-PageUp
    pad.editor.previousInputHistory()
    pad.debugStatus = "Recalled previous input"
  of "ESC[6~", "ESC[6;5~": # PageDown or Ctrl-PageDown
    pad.editor.nextInputHistory()
    if pad.editor.inputHistoryIndex == -1:
      pad.debugStatus = "Input cleared"
    else:
      pad.debugStatus = "Recalled next input"
  of "ESC[1;5H": # Control-Home - go to absolute start
    pad.editor.moveAbsoluteHome()
    pad.debugStatus = "Start of input"
  of "ESC[1;5F": # Control-End - go to absolute end
    pad.editor.moveAbsoluteEnd()
    pad.debugStatus = "End of input"
  of "ESC[H", "SOH", "ESC[97;5u": # control-A
    let contentWidth = max(1, pad.width - editorPromptLen)
    pad.editor.moveHomeVisual(contentWidth)
    pad.debugStatus = "Home"
  of "ESC[F", "ENQ", "ESC[101;5u": # control-E
    let contentWidth = max(1, pad.width - editorPromptLen)
    pad.editor.moveEndVisual(contentWidth)
    pad.debugStatus = "End"
  of "ESC[1;5A": # Ctrl-Up
    pad.editor.previousInputHistory()
    pad.debugStatus = "Recalled previous input"
  of "ESC[A", "ESC[1;2A":  # Up or Shift-Up
    let contentWidth = max(1, pad.width - editorPromptLen)
    # Check if we're on the first visual line
    let line = pad.editor.lines[pad.editor.cursorLine]
    let segments = wrapLine(line, contentWidth)
    var currentSegIdx = -1
    for i, seg in segments:
      if pad.editor.cursorCol >= seg.start and (pad.editor.cursorCol < seg.start + seg.len or 
         (i == segments.len - 1 and pad.editor.cursorCol == seg.start + seg.len)):
        currentSegIdx = i
        break
    
    # If on first segment of first line (first visual line), trigger history (except shift-up)
    if pad.editor.cursorLine == 0 and currentSegIdx <= 0 and key != "ESC[1;2A":
      pad.editor.previousInputHistory()
      pad.debugStatus = "Recalled previous input"
    else:
      # Move up visually
      pad.editor.moveUpVisual(contentWidth)
      pad.debugStatus = "Cursor up"
  of "ESC[1;5B": # Ctrl-Down
      pad.editor.nextInputHistory()
      if pad.editor.inputHistoryIndex == -1:
        pad.debugStatus = "Input cleared"
      else:
        pad.debugStatus = "Recalled next input"
  of "ESC[B", "ESC[1;2B":  # Down or Shift-Down
    let contentWidth = max(1, pad.width - editorPromptLen)
    # Check if we're on the last visual line
    let lastLine = pad.editor.lines.len - 1
    if pad.editor.cursorLine == lastLine:
      let line = pad.editor.lines[pad.editor.cursorLine]
      let segments = wrapLine(line, contentWidth)
      var currentSegIdx = -1
      for i, seg in segments:
        if pad.editor.cursorCol >= seg.start and (pad.editor.cursorCol < seg.start + seg.len or 
           (i == segments.len - 1 and pad.editor.cursorCol == seg.start + seg.len)):
          currentSegIdx = i
          break
      
      # If on last segment of last line (last visual line), trigger history (except for shift-down)
      if currentSegIdx >= segments.len - 1 and key != "ESC[1;2B":
        pad.editor.nextInputHistory()
        if pad.editor.inputHistoryIndex == -1:
          pad.debugStatus = "Input cleared"
        else:
          pad.debugStatus = "Recalled next input"
      else:
        # Move down visually within the last logical line
        pad.editor.moveDownVisual(contentWidth)
        pad.debugStatus = "Cursor down"
    else:
      # Not on last line: move down visually
      pad.editor.moveDownVisual(contentWidth)
      pad.debugStatus = "Cursor down"
  of "ESC[D", "ESC[1;2D":  # left or shift-left
    pad.editor.moveLeft()
    pad.debugStatus = "Cursor left"
  of "ESC[C", "ESC[1;2C":  # right or shift-right
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

# the keyLoop async proc processes keyboard input
proc keyLoop() {.async.} =
  while running:
    let keys = getKey()
    for keyEvent in keys:
      postEvent(UiEvent(kind: evKey, key: keyEvent))
    if keys.len == 0:
      await sleepAsync(keyPollIntervalMs)


proc mainLoop(pad: Scrollpad) {.async.} =
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
    elif not running:
      break
    else:
      let nowTime = epochTime()
      if (nowTime - resizeTicker) * 1000 >= resizePollIntervalMs.float:
        resizeTicker = nowTime
        let currentW = terminalWidth()
        let currentH = terminalHeight()
        if currentW != pad.width or currentH != pad.height:
          drawBottom(pad)
      await sleepAsync(10)

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
  result = Scrollpad()
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

proc runScrollpad*() {.async.} =
  ## Start the Scrollpad & async input processing, etc.  Call stopScrollpad() to stop it
  running = true
  var rawEnabled = false
  enable_raw_mode()
  stdout.write("\x1b[>1u"); stdout.flushFile()  # enable kitty-keyboard protocol for kitty & iterm2
  rawEnabled = true
  try:
    asyncCheck keyLoop()
    await mainLoop(pad)
  except:
    let e = getCurrentException()
    echo "Error in runScrollpad: ", e.msg
    raise
  finally:
    running = false
    stdout.write("\x1b[<1u"); stdout.flushFile()  # disable kitty-keyboard protocol
    shutdown(rawEnabled)

proc isScrollpadRunning*(): bool =
  ## check if scrollpad is still in a running state
  running

proc stopScrollpad*() =
  ## stop scrollpad execution and return from runScrollpad()
  running = false

proc setScrollpadStatusBar*(status: string) =
  ## set the string shown in the statusBar
  pad.status = status

proc getScrollpadWidth*(): int =
  ## return the width of the scrollpad (terminal width)
  pad.width

proc getScrollpadHeight*(): int =
  ## return the height of the scrollpad (terminal height)
  pad.height

# Initialize the main scrollpad
eventQueue = @[]
pad = newScrollpad()
pad.debugStatus = "Scrollpad TUI - Press ESC to exit"

when isMainModule:
  import strformat
  proc asyncFunction() {.async.} =
    print "1: That was great.  Fantastic."
    await sleepAsync(1000)
    print "2: Eh, I didn't like it"
    await sleepAsync(1000)
    print "1: What would you know, you old fool?"
    await sleepAsync(1000)
    print "2: Don't call me an old fool: I'll give you the evil eye."
    await sleepAsync(1000)
    print "1: Oooh I'm scared.  I'm scaaaared."
    await sleepAsync(5000)

  #showInputHistory = false
  setInputCallback(proc(text: string) {.nimcall.} =
    if text == "/quit":
      print "See you later, alligator!"
      running = false
      return
    setScrollpadStatusBar("You submitted some text...")
    # The submitted text is already added to the editor history/display by
    # submitInput. Avoid printing it again here to prevent duplicate output.
    # If you want to log to stdout instead of the scrollback UI, use `echo`.
    printError "This is an error message."
  )
  let fut = runScrollpad()
  asyncCheck asyncFunction()
  waitFor fut
