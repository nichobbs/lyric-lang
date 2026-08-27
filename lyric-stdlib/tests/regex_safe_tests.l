//! Tests for Std.RegexSafe (#330) and Std.Regex (#632).  Uses the
//! `func main(): Unit` + `println "ok"` shape run via `lyric run` in the
//! "Stdlib runtime suites on dotnet" CI step (.github/workflows/ci.yml),
//! not `lyric test` (the `test "..." {}` block syntax is for `lyric test`,
//! not this convention).
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
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "tryCompile('hello') should succeed")
  }
}

func testCompileInvalid(): Unit {
  match Rx.tryCompile("(unclosed") {
    case Ok(_) -> assertTrue(false, "tryCompile('(unclosed') should fail")
    case Err(e) -> match e { case RegexBug(_) -> (); case TimedOut(_) -> assertTrue(false, "invalid pattern should not be a timeout") }
  }
}

func testIsMatchSuccess(): Unit {
  match Rx.tryCompile("h.llo") {
    case Err(_) -> assertTrue(false, "tryCompile failed")
    case Ok(r) -> match Rx.tryIsMatch(r, "hello world") { case Ok(b) -> assertTrue(b, "h.llo matches 'hello world'"); case Err(_) -> assertTrue(false, "tryIsMatch should not error on a benign pattern") }
  }
}

func testReplaceSuccess(): Unit {
  match Rx.tryCompile("foo") {
    case Err(_) -> assertTrue(false, "tryCompile failed")
    case Ok(r) -> match Rx.tryReplace(r, "foofoo", "bar") { case Ok(s) -> assertTrue(s == "barbar", "replace produced 'barbar'"); case Err(_) -> assertTrue(false, "replace should not error") }
  }
}

// Smoke test that compileWithTimeout produces a usable Regex.
// Confirms the 3-arg ctor binding and that `isMatch` works against it.
func testCompileWithTimeoutSmoke(): Unit {
  val r = Re.compileWithTimeout("h.llo", 5.0)
  assertTrue(Re.isMatch(r, "hello world"), "compileWithTimeout produces a working regex")
}

// ReDoS regression: a catastrophic-backtracking pattern with a short
// timeout must surface an Err (rather than hang) -- `Re.isMatch` throws a
// `Bug` on timeout (see std/regex.l), so a hard assertion that the `Bug`
// actually fires is the real guard here, not just "the call returned".
//
// #843: a `try { … } catch Bug as _` block would silently swallow a
// failing `assertTrue(false, …)` (assertions panic as a Bug too).  We
// guard against the false-pass by setting a `caught` flag in the catch
// arm and asserting it after — that way an assertion thrown from the
// try-body propagates instead of being swallowed.
//
// #1103 shipped a real ReDoS-timeout mechanism on BOTH targets:
// `java.util.regex.Pattern` has no timeout of its own, so
// `std/_kernel_jvm/regex_host.l`'s `hostIsMatch` races the match on a
// daemon thread against `r.timeoutMs` and `panic`s (raises `Bug`) when the
// deadline is hit -- functionally the same "match returns via a thrown
// Bug" contract .NET's 3-arg `Regex` ctor gives for free. A single-nested
// `(a+)+$` doesn't reliably exercise that path on JVM though:
// `java.util.regex.Pattern` neutralizes it via an internal loop-collapse
// optimization (verified by direct experiment -- completes in single-digit
// ms even at 70 'a's), so this uses the triple-nested `((a+)+)+$` form and
// the 30-'a' / 1.5s budget `lyric-compiler/jvm/regex_redos_jvm_main.l`
// (the strict JVM-only acceptance check for #1103) proved genuinely
// exponential on JVM (~3-4s at 25 'a's) -- and .NET's classic backtracking
// engine has no such loop-collapse optimization to begin with, so the same
// pattern blows up there too.
func testReDoSTimeoutFires(): Unit {
  // 30-character string of 'a's followed by 'b' — non-matching suffix
  // forces the ((a+)+)+$ backtrack explosion.
  var hostile = ""
  var i = 0
  while i < 30 {
    hostile = hostile + "a"
    i = i + 1
  }
  hostile = hostile + "b"
  val r = Re.compileWithTimeout("((a+)+)+$", 1.5)
  var caught = false
  try {
    val matched = Re.isMatch(r, hostile)
    // If we reach here the engine returned without timing out.  On a
    // fast host that's not a bug but it's also not a real ReDoS-guard
    // test — print so a CI failure on slower hardware is debuggable.
    println("testReDoSTimeoutFires: match returned " + toString(matched) + " (no timeout on this host)")
  } catch Bug as _ {
    caught = true
  }
  assertTrue(caught, "ReDoS-timeout: expected a Bug from the engine (timeout) — got a clean return instead")
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
