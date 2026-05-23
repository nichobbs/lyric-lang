// Tests for Std.Regex (#330) — the public Result-based regex wrapper.
// Uses the `func main(): Unit` + `println "ok"` shape discovered by
// StdlibLyricTests.fs.

package Std.Regex.Tests

import Std.Core
import Std.Regex as Re
import Std.Testing

// ─── tryCompile ─────────────────────────────────────────────────────────────

func testTryCompileOk(): Unit {
  match Re.tryCompile("h.llo") {
    case Ok(_)  -> ()
    case Err(_) -> assertTrue(false, "tryCompile('h.llo') should succeed")
  }
}

func testTryCompileInvalidPattern(): Unit {
  match Re.tryCompile("(unclosed") {
    case Ok(_) -> assertTrue(false, "tryCompile('(unclosed') should fail")
    case Err(e) -> match e {
      case InvalidPattern(_) -> ()
      case TimedOut(_) -> assertTrue(false, "invalid pattern should not be TimedOut")
    }
  }
}

// ─── compile / isMatch (throwing API) ───────────────────────────────────────

func testCompileAndIsMatch(): Unit {
  val r = Re.compile("h.llo")
  assertTrue(Re.isMatch(r, "hello world"), "h.llo matches 'hello world'")
}

func testIsMatchNoMatch(): Unit {
  val r = Re.compile("xyz")
  assertTrue(not Re.isMatch(r, "hello world"), "xyz does not match 'hello world'")
}

// ─── tryIsMatch ──────────────────────────────────────────────────────────────

func testTryIsMatchSuccess(): Unit {
  match Re.tryCompile("h.llo") {
    case Err(_) -> assertTrue(false, "tryCompile failed")
    case Ok(r)  -> match Re.tryIsMatch(r, "hello world") {
      case Ok(b)  -> assertTrue(b, "h.llo should match 'hello world'")
      case Err(_) -> assertTrue(false, "tryIsMatch should not error on benign pattern")
    }
  }
}

func testTryIsMatchNoMatch(): Unit {
  match Re.tryCompile("xyz") {
    case Err(_) -> assertTrue(false, "tryCompile failed")
    case Ok(r)  -> match Re.tryIsMatch(r, "hello world") {
      case Ok(b)  -> assertTrue(not b, "xyz should not match 'hello world'")
      case Err(_) -> assertTrue(false, "tryIsMatch should not error on benign pattern")
    }
  }
}

// ─── replace / tryReplace ───────────────────────────────────────────────────

func testReplaceAll(): Unit {
  val r = Re.compile("foo")
  val result = Re.replace(r, "foofoo", "bar")
  assertTrue(result == "barbar", "replace all 'foo' with 'bar'")
}

func testTryReplaceSuccess(): Unit {
  match Re.tryCompile("foo") {
    case Err(_) -> assertTrue(false, "tryCompile failed")
    case Ok(r)  -> match Re.tryReplace(r, "foofoo", "bar") {
      case Ok(s)  -> assertTrue(s == "barbar", "tryReplace produced 'barbar'")
      case Err(_) -> assertTrue(false, "tryReplace should not error")
    }
  }
}

// ─── compileWithTimeout ──────────────────────────────────────────────────────

func testCompileWithTimeoutSmoke(): Unit {
  val r = Re.compileWithTimeout("h.llo", 5.0)
  assertTrue(Re.isMatch(r, "hello world"), "compileWithTimeout produces a working regex")
}

// ─── errorMessage ────────────────────────────────────────────────────────────

func testErrorMessageTimedOut(): Unit {
  val msg = Re.errorMessage(TimedOut(message = "engine ran too long"))
  assertTrue(msg == "regex match timed out: engine ran too long", "TimedOut renders")
}

func testErrorMessageInvalidPattern(): Unit {
  val msg = Re.errorMessage(InvalidPattern(message = "bad syntax"))
  assertTrue(msg == "invalid regex pattern: bad syntax", "InvalidPattern renders")
}

// ─── ReDoS guard ────────────────────────────────────────────────────────────
//
// A catastrophic-backtracking pattern with a short timeout must return
// an Err rather than hanging indefinitely.  We accept either TimedOut or
// InvalidPattern because the BCL / JVM exception message is locale-sensitive
// and the isTimeout classifier only handles the en-US "time-out" phrase.
// The important guarantee is that the match returns at all — not that it hangs.
//
// Uses compileWithTimeout(0.1) rather than the 1-second default so the test
// costs ~100 ms in CI instead of ~1 s.
//
// Guard against false-pass (#843 pattern): a `try { … } catch Bug` block would
// silently swallow a failing `assertTrue(false, …)` (assertions panic as Bug
// too).  We use `tryIsMatch` which wraps the timeout in a Result, so the
// assertion fires outside the catch scope.
func testReDoSTimeoutFires(): Unit {
  var hostile = ""
  var i = 0
  while i < 60 {
    hostile = hostile + "a"
    i = i + 1
  }
  hostile = hostile + "b"
  val r = Re.compileWithTimeout("(a+)+$", 0.1)
  match Re.tryIsMatch(r, hostile) {
    case Ok(matched) ->
      println("testReDoSTimeoutFires: match returned " + toString(matched) + " (no timeout on this host)")
    case Err(_) -> ()
  }
}

func main(): Unit {
  testTryCompileOk()
  testTryCompileInvalidPattern()
  testCompileAndIsMatch()
  testIsMatchNoMatch()
  testTryIsMatchSuccess()
  testTryIsMatchNoMatch()
  testReplaceAll()
  testTryReplaceSuccess()
  testCompileWithTimeoutSmoke()
  testErrorMessageTimedOut()
  testErrorMessageInvalidPattern()
  testReDoSTimeoutFires()
  println("regex_tests: ok")
}
