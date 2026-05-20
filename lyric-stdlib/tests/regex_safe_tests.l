// Tests for Std.RegexSafe (#330) and Std.Regex (#632).  Uses the
// `func main(): Unit` + `println "ok"` shape that `StdlibLyricTests.fs`
// runs (the `test "..." {}` block syntax is for `lyric test`, not this
// runner).

package Std.RegexSafe.Tests

import Std.Core
import Std.Regex as Re
import Std.RegexSafe as Rx
import Std.Testing

func testErrorMessageTimedOut(): Unit {
  val msg = Rx.errorMessage(TimedOut(message = "x"))
  assertTrue(msg == "regex match timed out: x", "TimedOut renders")
}

func testErrorMessageRegexBug(): Unit {
  val msg = Rx.errorMessage(RegexBug(message = "y"))
  assertTrue(msg == "regex error: y", "RegexBug renders")
}

func testCompileOk(): Unit {
  match Rx.tryCompile("hello") {
    case Ok(_)  -> ()
    case Err(_) -> assertTrue(false, "tryCompile('hello') should succeed")
  }
}

func testCompileInvalid(): Unit {
  match Rx.tryCompile("(unclosed") {
    case Ok(_) -> assertTrue(false, "tryCompile('(unclosed') should fail")
    case Err(e) -> match e {
      case RegexBug(_)  -> ()
      case TimedOut(_)  -> assertTrue(false, "invalid pattern should not be a timeout")
    }
  }
}

func testIsMatchSuccess(): Unit {
  match Rx.tryCompile("h.llo") {
    case Err(_) -> assertTrue(false, "tryCompile failed")
    case Ok(r)  -> match Rx.tryIsMatch(r, "hello world") {
      case Ok(b)  -> assertTrue(b, "h.llo matches 'hello world'")
      case Err(_) -> assertTrue(false, "tryIsMatch should not error on a benign pattern")
    }
  }
}

func testReplaceSuccess(): Unit {
  match Rx.tryCompile("foo") {
    case Err(_) -> assertTrue(false, "tryCompile failed")
    case Ok(r)  -> match Rx.tryReplace(r, "foofoo", "bar") {
      case Ok(s)  -> assertTrue(s == "barbar", "replace produced 'barbar'")
      case Err(_) -> assertTrue(false, "replace should not error")
    }
  }
}

// Smoke test that compileWithTimeout produces a usable Regex.
// Confirms the 3-arg ctor binding and that `isMatch` works against it.
func testCompileWithTimeoutSmoke(): Unit {
  val r = Re.compileWithTimeout("h.llo", 5.0)
  assertTrue(Re.isMatch(r, "hello world"), "compileWithTimeout produces a working regex")
}

// ReDoS regression: a catastrophic-backtracking pattern with a short
// timeout must surface an Err (rather than hang).  We accept either
// TimedOut or RegexBug because the BCL's RegexMatchTimeoutException.Message
// is locale-sensitive and the classifier in `Std.RegexSafe.isTimeout`
// only handles the en-US "time-out" phrasing.  The important guarantee
// is that the match returns rather than running for minutes.
//
// Uses `Re.compileWithTimeout(0.1)` rather than the 1-second default
// so the test costs ~100 ms in CI instead of ~1 s (#832).
func testReDoSTimeoutFires(): Unit {
  // 60-character string of 'a's followed by 'b' — non-matching suffix
  // forces the (a+)+$ backtrack explosion.
  var hostile = ""
  var i = 0
  while i < 60 {
    hostile = hostile + "a"
    i = i + 1
  }
  hostile = hostile + "b"
  val r = Re.compileWithTimeout("(a+)+$", 0.1)
  try {
    val matched = Re.isMatch(r, hostile)
    assertTrue(false, "ReDoS match unexpectedly returned " + toString(matched))
  } catch Bug as _ {
    ()
  }
}

func main(): Unit {
  testErrorMessageTimedOut()
  testErrorMessageRegexBug()
  testCompileOk()
  testCompileInvalid()
  testIsMatchSuccess()
  testReplaceSuccess()
  testCompileWithTimeoutSmoke()
  testReDoSTimeoutFires()
  println("regex_safe_tests: ok")
}
