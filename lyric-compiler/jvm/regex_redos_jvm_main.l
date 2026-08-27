//! regex_redos_jvm_main.l — `Std.Regex` ReDoS-timeout acceptance check for
//! `--target jvm` (#330 / #1103).
//!
//! Not a `@test_module` and not a `@cfg(feature = "jvm")`-gated function
//! inside `lyric-stdlib/tests/regex_tests.l`: `lyric run` (which drives
//! that suite in CI) has no `--features` flag, so a feature-gated function
//! there would never actually run — the prior state, tracked in #1165. This
//! is a standalone program (mirrors `entry_args_jvm_main.l` / a plain
//! `func main(): Int` exit-code check), built and run directly.
//!
//! Asserts a catastrophic-backtracking pattern against adversarial input
//! returns `Err(TimedOut)` — not `Ok`, and not a hang — within the
//! compiled-in timeout, proving `std/_kernel_jvm/regex_host.l`'s
//! daemon-thread-race shim actually enforces the deadline it accepts.
//! Prints "ok" and exits 0 on success; prints a diagnostic and exits 1 on
//! any other outcome (including "the process is still running past a
//! generous wall-clock budget", which would mean the shim regressed to
//! blocking forever rather than merely leaking a background thread).
package Main

import Std.Core
import Std.Console
import Std.Regex as Re

func main(): Int {
  var hostile = ""
  var i = 0
  while i < 30 {
    hostile = hostile + "a"
    i = i + 1
  }
  hostile = hostile + "b"
  // `((a+)+)+$` (triple-nested), not the more commonly cited `(a+)+$`:
  // verified by direct experiment that this JDK's `java.util.regex.Pattern`
  // neutralizes the doubly-nested form (`(a+)+$` completes in single-digit
  // milliseconds even at n=70, presumably a JEP/internal loop-collapse
  // optimization for that specific shape) — the triple-nested form still
  // exhibits genuine exponential backtracking here (n=20 -> ~0.2s, n=25 ->
  // ~3-4s measured directly against raw `java.util.regex.Pattern`, no
  // Lyric involved), so it reliably exceeds the 1.5s compiled-in timeout
  // below while single-digit `n` keeps the benign-outcome case (a shim
  // regression back to unbounded blocking) bounded by this file's CI
  // wall-clock cap.
  val r = Re.compileWithTimeout("((a+)+)+$", 1.5)
  match Re.tryIsMatch(r, hostile) {
    case Ok(matched) -> {
      println(
        "FAIL: catastrophic pattern returned Ok(" + toString(matched) +
          "); expected Err(TimedOut) (#1103 shim missing or not enforcing)"
      )
      1
    }
    case Err(e) -> {
      match e {
        case TimedOut(msg) -> {
          println("ok: " + Re.errorMessage(TimedOut(message = msg)))
          0
        }
        case InvalidPattern(msg) -> {
          println("FAIL: ReDoS guard surfaced InvalidPattern instead of TimedOut: " + msg)
          1
        }
      }
    }
  }
}
