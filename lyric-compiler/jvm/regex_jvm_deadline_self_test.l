//! regex_jvm_deadline_self_test.l — CI gate for the JVM regex kernel's
//! inline deadline (#7283).
//!
//! `_kernel_jvm/regex_host.l` bounds every match operation by running it on
//! the calling thread over a `CharSequence` whose `charAt` checks the clock
//! and panics past the deadline. These cases pin what that design must
//! guarantee:
//!   - a catastrophically backtracking match is stopped near its deadline
//!     and reports `TimedOut`;
//!   - consecutive timeouts, well past the removed design's cap of 64
//!     outstanding matches, each report `TimedOut` and leave the kernel
//!     able to run a benign match straight after (this replaces #6711's
//!     permit-leak test for the removed `matchSemaphore`);
//!   - a match-time fault inside the engine (an out-of-range `$n` in a
//!     replacement) still surfaces as a fault, never as a timeout;
//!   - the `Matcher` returned by `hostMatchOne` stays usable after its
//!     deadline has passed.
//!
//!   lyric test --target jvm lyric-compiler/jvm/regex_jvm_deadline_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.RegexJvmDeadlineSelfTest

import Std.Core
import Std.Testing
import Std.Time
import Std.Regex as Rx
import Std.RegexSafe as Safe
import Std.RegexHost as Host

// `((a+)+)+$` against a run of 'a's ending in 'b' is exponential on the JDK
// engine (see regex_redos_jvm_main.l).
func hostileInput(): String {
  var s = ""
  var i = 0
  while i < 30 {
    s = s + "a"
    i = i + 1
  }
  s + "b"
}

func isTimedOut(e: in Rx.RegexError): Bool {
  match e {
    case Rx.TimedOut(_) -> true
    case _ -> false
  }
}

test "a runaway match is stopped near its deadline and reports TimedOut" {
  val r = Rx.compileWithTimeout("((a+)+)+$", 0.2)
  val started = nowEpochMillis()
  match Rx.tryIsMatch(r, hostileInput()) {
    case Ok(_) -> assertTrue(false, "the hostile match must time out")
    case Err(e) -> assertTrue(isTimedOut(e), "expected TimedOut, got: " + Rx.errorMessage(e))
  }
  val elapsed = nowEpochMillis() - started
  assertTrue(elapsed < 2000i64, "stopped within 2s of a 200ms deadline, took " + elapsed.toString() + "ms")
}

test "many consecutive timeouts each report TimedOut" {
  val r = Rx.compileWithTimeout("((a+)+)+$", 0.01)
  val input = hostileInput()
  var timedOut = 0
  var i = 0
  while i < 100 {
    match Rx.tryIsMatch(r, input) {
      case Ok(_) -> ()
      case Err(e) -> if isTimedOut(e) { timedOut = timedOut + 1 }
    }
    i = i + 1
  }
  assertEqualInt(timedOut, 100, "every hostile match times out")
  assertTrue(Rx.isMatch(Rx.compile("a+b"), "xxaab!"), "a benign match succeeds straight after")
}

test "a match-time fault surfaces as a fault, not a timeout" {
  val r = Rx.compile("a+b")
  var faults = 0
  var i = 0
  while i < 200 {
    match Rx.tryReplace(r, "xxaab!", "$5") {
      case Ok(_) -> assertTrue(false, "an out-of-range $5 group reference must fault")
      case Err(e) -> if not isTimedOut(e) { faults = faults + 1 }
    }
    i = i + 1
  }
  assertEqualInt(faults, 200, "every call reports the group-reference fault")
}

test "the Matcher from matchOne is usable after its deadline has passed" {
  val r = Host.hostCompileWithTimeout("b+", 0.05)
  match Safe.tryMatchOne(r, "aabbbcc") {
    case Ok(m) -> {
      sleepMillis(100)
      val text: String = m.group()
      assertEqual(text, "bbb", "group() of the first match")
    }
    case Err(e) -> assertTrue(false, "tryMatchOne failed: " + Safe.errorMessage(e))
  }
}
