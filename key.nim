# MIT licensed, from https://github.com/genotrance/snip/

var KCH*: Channel[seq[string]]
KCH.open()

const asciicharnames = @["NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS", "HT", "NL", "VT", "FF", "CR", "SO", "SI", "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN+", "ETB", "CAN+", "EM", "SUB", "ESC", "FS", "GS", "RS", "US"]

when defined(windows):
  proc getch(): char {.header: "<conio.h>", importc: "getch".}
  proc kbhit(): int {.header: "<conio.h>", importc: "kbhit".}
  proc enable_raw_mode*() = discard
  proc disable_raw_mode*() = discard
  proc cleanExit*() = discard
else:
  {.compile: "getch.c".}
  proc enable_raw_mode*() {.importc.}
  proc disable_raw_mode*() {.importc.}
  proc getch*(): char {.importc.}
  proc kbhit*(): int {.importc.}
  proc cleanExit*() =
    disable_raw_mode()

proc getKey*(): seq[string] {.inline.} =
  result = @[]

  var
    lchr: char
    code = ""

  while kbhit() != 0:
    lchr = getch()
    if lchr.int < 32 or lchr.int > 126:
      if lchr.int < 32:
        code = asciicharnames[lchr.int]
      elif lchr.int == 127:
        code = "DEL"
      else:
        code = $(lchr.int)
      if lchr.int in {0, 22, 24, 27, 224}:
        while kbhit() != 0 or lchr.int == 24:  # CTRL+X (24/CAN) and CTRL+V (22/VAN) are treated as prefix-keys
          lchr = getch()
          if lchr.int < 32:
            code &= asciicharnames[lchr.int]
          elif lchr.int == 127:
            code &= "DEL"
          else:
            code &= $lchr
      result.add(code)
    else:
      result.add($lchr)


when isMainModule:
  var exit = false
  try:
    while not exit:
      enable_raw_mode()
      stdout.write("\x1b[>1u"); stdout.flushFile() # enable kitty-keyboard protocol for kitty & iterm2
      for code in getKey():
        if code != "":
          echo "code (" & $code & ")"
        if code == "ESC" or code == "ESC[27u":
          exit = true
          break
  finally:
    stdout.write("\x1b[<1u"); stdout.flushFile() # disable kitty-keyboard protocol
    disable_raw_mode()
