// stdlib/tests/regex_safe_tests.l — Tests for Std.RegexSafe (#330).
//
// Covers: error-message rendering and the public tryCompile /
// tryIsMatch / tryReplace paths against benign inputs.  We
// deliberately do NOT trigger the 1-second match timeout —
// constructing an adversarial input large enough would slow the
// test suite without adding coverage beyond what the BCL itself
// guarantees.
//
// Uses the `func main(): Unit` + `println "ok"` pattern that
// `StdlibLyricTests.fs` expects.  Other stdlib test files
// (json_tests.l, format_tests.l, …) follow the same shape.  The
// `test "..." { }` block syntax used by `lyric-proto/tests/` runs
// through `lyric test`, not through `StdlibLyricTests`.

package Std.RegexSafe.Tests

import Std.Core
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

func main(): Unit {
  testErrorMessageTimedOut()
  testErrorMessageRegexBug()
  testCompileOk()
  testCompileInvalid()
  testIsMatchSuccess()
  testReplaceSuccess()
  println("regex_safe_tests: ok")
}
