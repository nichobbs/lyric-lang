//! regex_jvm_semaphore_leak_self_test.l — CI gate for #6711: the JVM
//! regex kernel's `matchSemaphore` (#6576) must release its permit on
//! EVERY exit path from the raced background match, fault included, not
//! just success/timeout.
//!
//! `_kernel_jvm/regex_host.l`'s `raceWithDeadline` bounds the number of
//! concurrently-outstanding background match computations with a
//! process-wide `matchSemaphore` (capacity `maxConcurrentMatches`,
//! `Runtime.availableProcessors() * 16` floored at 64). Before #6711, the
//! permit-releasing `matchSemaphore.release()` call sat as a plain
//! statement AFTER the `try { action() } catch Bug as b { ... } }` block
//! rather than inside a `defer` — so anything that unwound past the
//! `catch` arm entirely would skip the release and leak the permit
//! forever, permanently shrinking capacity by one per occurrence. Fixed
//! by moving the release into `defer { matchSemaphore.release() }`,
//! registered before the `try`/`catch`, so it runs on every exit path
//! (docs/01-language-reference.md §4.3 — `defer` runs on "success or
//! failure" on every managed target, JVM included).
//!
//! This test forces a REAL fault through the raced closure via the
//! public `Std.Regex` API: an out-of-range `$n` back-reference in a
//! `replace` replacement string is accepted by `Pattern.compile` (valid
//! syntax) but throws `IndexOutOfBoundsException` from
//! `Matcher.replaceAll` — i.e. AT MATCH TIME, inside `raceWithDeadline`'s
//! raced closure, not at pattern-compile time (which the pre-existing
//! "classifies invalid patterns" test already covers via a different,
//! non-raced code path). Forcing this fault far more times than
//! `maxConcurrentMatches`'s floor (64) and asserting every single call
//! still reports the SAME "no such group" fault — never the distinct
//! `saturationMessage` wording a leaked-to-zero semaphore would start
//! producing — proves the permit is released on the fault path every
//! time, not just on success/timeout.
//!
//! Run via the native test runner on the JVM target (JVM-only: the
//! semaphore-based concurrency cap this pins is a JVM-kernel-specific
//! mechanism, `_kernel/regex_host.l`'s `.NET` twin has no equivalent):
//!
//!   lyric test --target jvm lyric-compiler/jvm/regex_jvm_semaphore_leak_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.RegexJvmSemaphoreLeakSelfTest

import Std.Core
import Std.Testing
import Std.Regex as Rx

// Comfortably above `maxConcurrentMatches`'s floor (64) — if even one
// permit leaked per faulting call, capacity would be visibly exhausted
// well before this many iterations, and later calls would report the
// distinct `saturationMessage` wording instead of the expected fault.
val faultIterations: Int = 200

test "repeated match-time faults (#6711) never exhaust matchSemaphore" {
  val r = Rx.compile("a+b")
  var i = 0
  var sawSaturation = false
  var sawExpectedFault = 0
  while i < faultIterations {
    match Rx.tryReplace(r, "xxaab!", "$5") {
      case Ok(_) -> {
        assertTrue(false, "an out-of-range $5 group reference must fault, not succeed, at i=" + i.toString())
      }
      case Err(e) -> {
        val msg = Rx.errorMessage(e)
        if msg.indexOf("in flight") >= 0 or msg.indexOf("system-wide cap") >= 0 {
          sawSaturation = true
        } else {
          sawExpectedFault = sawExpectedFault + 1
        }
      }
    }
    i = i + 1
  }
  assertFalse(
    sawSaturation,
    "matchSemaphore must never report saturation after repeated match-time faults (#6711 permit leak)"
  )
  assertEqualInt(
    sawExpectedFault,
    faultIterations,
    "every iteration must report the real fault (group-reference), not a saturation rejection"
  )
}

test "a normal match still succeeds immediately after the fault-path hammering above" {
  val r = Rx.compile("a+b")
  assertTrue(Rx.isMatch(r, "xxaab!"), "matchSemaphore has capacity for a normal match right after the fault-path test")
}
