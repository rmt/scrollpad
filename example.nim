import std/[times, os, strformat]
import scrollpad

when isMainModule:
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

  showInputHistory = false
  shouldEscapeStop = false
  editorPrompt = ">>> "
  editorPrompt2 = "... "
  editorPromptLen = editorPrompt.len
  setInputCallback(proc(text: string) {.nimcall.} =
    if text == "/quit":
      print "See you later, alligator!"
      stopScrollpad()
      return
    setScrollpadStatusBar("Type /quit to quit.")
    print "Hi there!  You submitted:", text
    printError ""
    printError "This is an error message."
    printError ""
  )
  var t: Thread[void]
  createThread(t, sampleFeedLoop)
  try:
    runScrollpad()
  finally:
    joinThread(t)
