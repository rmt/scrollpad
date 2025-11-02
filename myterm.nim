import std/terminal
import std/os
import std/strutils
import std/exitprocs
import key

type
  TextBuffer = ref object
    lines: seq[string]
  TextView = ref object
    buf: TextBuffer

  StatusBar = ref object
    text: string
    bgColor = bgBlack
    fgColor = fgWhite

  EditBar = ref object
    prompt: string
    altPrompt: string
    pos: int
    replaceMode: bool
    history: seq[string]
    historyPos: int
    origBuf: string

  Window = ref object
    height: int
    width: int
    textView: TextView
    statusBar: StatusBar
    editBar: EditBar

var
  backBuf: array[120, string]
  alwaysRefresh: bool


proc buf(s: EditBar): string =
  return s.history[s.historyPos]

proc `buf=`(s: EditBar, text: string) =
  s.history[s.historyPos] = text

proc draw(tv: TextView; row, height, width: int) =
  for i, line in tv.buf.lines:
    if alwaysRefresh or line != backBuf[i+row]:
      setCursorPos(0, i+row)
      stdout.styledWriteLine(fgWhite, line)
      backBuf[i+row] = line

proc draw(s: StatusBar; w: Window, row, width: int) =
  setCursorPos(0, row)
  stdout.styledWriteLine(s.bgColor, ' '.repeat width)
  setCursorPos(0, row)
  stdout.styledWriteLine(s.bgColor, "[" & $w.editBar.pos & "] " & s.text)

proc draw(s: EditBar; row, width: int) =
  setCursorPos(0, row)
  eraseLine()
  var bufFirst = 0
  var prompt = s.prompt
  var cursorPos = len(prompt) + s.pos
  let jump = int(width / 3)
  while cursorPos >= width:
    bufFirst += jump
    cursorPos -= jump
    prompt = s.altPrompt
  let bufLast = min(len(s.buf)-1, bufFirst+width-len(prompt)-1)
  stdout.styledWrite(fgBlue, prompt)
  stdout.styledWrite(fgWhite, s.buf[bufFirst..bufLast])
  stdout.flushFile()
  if s.replaceMode:
    stdout.write("\e[1 q")
  else:
    stdout.write("\e[3 q")
  setCursorPos(cursorPos, row)
  s.history[s.historyPos] = s.buf
  stdout.flushFile()

proc addText(s: EditBar; text: string) =
  if len(s.buf) == 0:
    s.buf = text
  elif s.replaceMode:
    s.buf = s.buf[0..max(0, s.pos-1)] & text & s.buf[s.pos+1..^1]
  elif s.pos == 0:
    s.buf = text & s.buf
  else:
    s.buf = s.buf[0..max(0, s.pos-1)] & text & s.buf[s.pos..^1]
  s.pos += len(text)

proc goLeft(s: EditBar) =
  if s.pos > 0:
    s.pos -= 1

proc goRight(s: EditBar) =
  if s.pos < len(s.buf):
    s.pos += 1

proc goUp(s: EditBar) =
  if s.historyPos+1 >= len(s.history):
    return
  else:
    s.historyPos += 1
    s.buf = s.history[s.historyPos]
    s.origBuf = s.history[s.historyPos]
    s.pos = len(s.buf)

proc goDown(s: EditBar) =
  if s.historyPos == 0:
    return
  else:
    s.historyPos -= 1
    s.origBuf = s.history[s.historyPos]
    s.buf = s.history[s.historyPos]
    s.pos = len(s.buf)

proc submit(s: EditBar): string =
  result = s.buf
  if s.historyPos != 0 and s.origBuf != "" and s.origBuf != s.buf:
    s.history[s.historyPos] = s.origBuf  # restore original, add new history entry
    s.history[0] = result
  s.historyPos = 0
  if s.buf != "":
      var newHistory = @[s.buf]
      newHistory.add(s.history)
      s.history = newHistory
  s.buf = ""

proc goHome(s: EditBar) =
  s.pos = 0

proc goEnd(s: EditBar) =
  s.pos = len(s.buf)

proc goLeftWord(s: EditBar) =
  if s.pos > 0:
    s.pos -= 1
  while s.pos > 0:
    s.pos -= 1
    var c = s.buf[s.pos]
    if c == ' ' and s.pos < len(s.buf):
      s.pos += 1
      break
    if c == ' ' or c == '/' or c == '[' or c == ']' or c == '(' or c == ')':
      break

proc deleteUntilSpace(s: EditBar) =
  var pos = s.pos
  while pos < len(s.buf):
    var c = s.buf[pos]
    pos += 1
    if c == ' ' or c == '/' or c == '[' or c == ']' or c == '(' or c == ')':
      break
  if s.pos == 0:
    s.buf = s.buf[pos..^1]
  else:
    s.buf = s.buf[0..s.pos-1] & s.buf[pos..^1]

proc backspaceUntilSpace(s: EditBar) =
  var pos = s.pos
  while pos > 0:
    pos -= 1
    var c = s.buf[pos]
    if c == ' ' or c == '/' or c == '[' or c == ']' or c == '(' or c == ')':
      break
  s.buf = s.buf[0..pos-1] & s.buf[s.pos..^1]
  s.pos = pos

proc goRightWord(s: EditBar) =
  while s.pos < len(s.buf):
    s.pos += 1
    if s.pos == len(s.buf):
      break
    var c = s.buf[s.pos]
    if c == ' ' and s.pos < len(s.buf):
      s.pos += 1
      break
    if c == '/' or c == '[' or c == ']':
      break

proc deleteCurrentCharacter(s: EditBar) =
  if s.pos < len(s.buf):
    s.buf = s.buf[0..s.pos-1] & s.buf[s.pos+1..^1]

proc deleteToStartOfLine(s: EditBar) =
  if s.pos == 0:
    return
  s.buf = s.buf[s.pos..^1]
  s.pos = 0

proc deleteToEndOfLine(s: EditBar) =
  if s.pos == 0:
    s.buf = ""
  else:
    s.buf = s.buf[0..s.pos-1]

proc deletePreviousCharacter(s: EditBar) =
  if s.pos > 0:
    s.buf = s.buf[0..s.pos-2] & s.buf[s.pos..^1]
    s.pos -= 1

proc setText(s: EditBar; text: string) =
  s.buf = text
  s.pos = len(s.buf)


proc draw(w: Window) =
  w.textView.draw(0, w.height-2, w.width)
  w.statusBar.draw(w, w.height-2, w.width)
  w.editBar.draw(w.height-1, w.width)
  w.width = terminalWidth()
  w.height = terminalHeight()
  stdout.write("\e[3J")
  stdout.flushFile()


proc stringToOrdinals(s: string): seq[int] =
  result = @[]
  for ch in s:
    result.add(ord(ch))

when isMainModule:
  # enable raw mode, ensuring we disable it on quit
  enable_raw_mode()
  exitprocs.addExitProc(proc() {.noconv.} =
      disable_raw_mode()
      stdout.write("\e[2J\e[1 q")
      stdout.resetAttributes()
      stdout.flushFile()
      echo ""
  )

  var tbuf = TextBuffer(lines: newSeq[string]())
  var edit = EditBar(
    prompt: ">>> ",
    altPrompt: "... ",
    history: @[""]
  )
  var win = Window(
    width: terminalWidth(), height: terminalHeight(),
    textView: TextView(buf: tbuf),
    statusBar: StatusBar(),
    editBar: edit)

  win.editBar.setText("d1 $ boom tss boom tss")

  eraseScreen()
  win.draw()
  var done = false
  while not done:
    os.sleep(20)
    for k in getKey():
      win.statusBar.text = k # $stringToOrdinals(k)
      if k == "ESC":
        done = true
      elif k == "FF":
        alwaysRefresh = true
      elif k == "DEL":
        edit.deletePreviousCharacter()
      elif k == "ESC[3~":
        edit.deleteCurrentCharacter()
      elif k == "NL" or k == "ESC\n":
        tbuf.lines.add(edit.submit())
        edit.setText("")
      elif k == "ESC[H" or k == "SOH": # home key or ^A
        edit.goHome()
      elif k == "ESC[F" or k == "ENQ": # end key or ^E
        edit.goEnd()
      elif k == "ESC[D": # left key
        edit.goLeft()
      elif k == "ESC[C": # right key
        edit.goRight()
      elif k == "ESC[A": # up key
        edit.goUp()
      elif k == "ESC[B": # down key
        edit.goDown()
      elif k == "ESC[2~": # insert key
        edit.replaceMode = not edit.replaceMode
      elif k == "NAK": # control-u
        edit.deleteToStartOfLine()
      elif k == "VT": # control-k
        edit.deleteToEndOfLine()
      elif k == "ESC[3;5~" or k == "ESC[3;3~": # control-DEL or alt-DEL
        edit.deleteUntilSpace()
      #elif k == "BS": # actually seems to be control backspace
      elif k == "ESC\x7f": # Alt-Backspace
        edit.backspaceUntilSpace()
      elif k == "ESC[1;5D":  # control-left
        edit.goLeftWord()
      elif k == "ESC[1;5C":  # control-right
        edit.goRightWord()
      elif len(k) == 1:
        edit.addText(k)
      win.draw()
      alwaysRefresh = false
