import std/[asyncdispatch, times, os, strformat]
from scrollpad import print, printError

when isMainModule:
  proc generateEvents(until: int = 7) {.async.} =
    var counter = 1
    await sleepAsync(1)
    while counter <= until and scrollpad.isScrollpadRunning():
      await sleepAsync(1000)
      let timeStamp = now().format("HH:mm:ss")
      let line = &"({timeStamp}) background event #{counter}"
      inc counter
      print line

  scrollpad.showInputHistory = false
  scrollpad.shouldEscapeStop = false
  scrollpad.editorPrompt = ">>> "
  scrollpad.editorPrompt2 = "... "
  scrollpad.editorPromptLen = len(scrollpad.editorPrompt)

  scrollpad.setInputCallback(proc(text: string) {.nimcall.} =
    if text == "/quit":
      print "See you later, alligator!"
      scrollpad.stopScrollpad()
      return
    if text == "/events":
      asyncCheck generateEvents(7)
      return
    scrollpad.setScrollpadStatusBar("Type /quit to quit, or /events to start an async loop")
    printError ""
    printError "Unknown command:", text
    printError ""
  )

  asyncCheck generateEvents(5)
  waitFor scrollpad.runScrollpad()
