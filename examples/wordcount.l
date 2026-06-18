// Word + line + character counts on an inline document.
//
// Bootstrap-grade `wc(1)`: walks one character at a time, tracking
// "am I currently inside a run of non-whitespace?" to count words,
// and tallies newlines + total chars.  No file I/O yet — extern
// package wiring for `Std.File` is still WIP — so the document is
// embedded.
//
// Run: lyric run examples/wordcount.l

package Wc

func isWs(c: in Char): Bool {
  c == ' ' or c == '\t' or c == '\n' or c == '\r'
}

func main(): Unit {
  val doc = "alpha beta gamma\nThe quick brown fox\n  jumps over\nthe lazy dog\n"
  val n = doc.length

  var chars = 0
  var lines = 0
  var words = 0
  var inWord = false

  var i = 0
  while i < n {
    val c = doc[i]
    chars += 1
    if c == '\n' {
      lines += 1
    }
    if isWs(c) {
      inWord = false
    } else {
      if not inWord {
        words += 1
      }
      inWord = true
    }
    i += 1
  }

  println("chars: " + chars)
  println("lines: " + lines)
  println("words: " + words)
}
