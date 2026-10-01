//! stdlib/tests/console_stdin_tests.l — Std.Console's stdin byte reader
//! (`openStdinReader` / `readStdinWithin` / `readStdin`, #7451).
//!
//! Needs a controlled stdin, so it is run by `scripts/ci/console-stdin-test.sh`
//! rather than in the plain suite loop: the script pipes nothing into the
//! program until it creates the marker file named by
//! `LYRIC_STDIN_TEST_MARKER`, then writes `late\n` and closes the pipe. That
//! ordering makes each step deterministic:
//!
//!   1. with stdin silent, a bounded read times out after its deadline;
//!   2. the bytes that arrive afterwards are returned by the next read — the
//!      timed-out read is resumed, not lost;
//!   3. end of stream is reported as such, by both read forms.
//!
//! Runs on every target; `--target native` omits only the negative-timeout
//! check (see `checkNegativeTimeoutRejected`).
package Std.Console.StdinTests

import Std.Core
import Std.Console
import Std.Encoding
import Std.Environment
import Std.File
import Std.Testing
import Std.Time

// `readStdinWithin`'s `requires: timeoutMs >= 0` panics on a negative
// timeout.  Observing that needs a caught panic, which `--target native`
// cannot lower (D-N-003: no unwinding), so the native build leaves it out.
@cfg(target = "dotnet")
func checkNegativeTimeoutRejected(r: in StdinReader): Unit {
  assertPanics("readStdinWithin with a negative timeout", { -> val _ = readStdinWithin(r, -1) })
}

@cfg(target = "jvm")
func checkNegativeTimeoutRejected(r: in StdinReader): Unit {
  assertPanics("readStdinWithin with a negative timeout", { -> val _ = readStdinWithin(r, -1) })
}

@cfg(target = "native")
func checkNegativeTimeoutRejected(r: in StdinReader): Unit {
}

func main(): Int {
  val marker = match getVar("LYRIC_STDIN_TEST_MARKER") {
    case Ok(path) -> path
    case Err(_) -> {
      println("console_stdin_tests: LYRIC_STDIN_TEST_MARKER is not set; run it via scripts/ci/console-stdin-test.sh")
      return 1
    }
  }
  val r = openStdinReader()

  val start = monotonicNanos()
  match readStdinWithin(r, 300) {
    case Ok(StdinTimedOut) -> ()
    case Ok(_) -> assertTrue(false, "stdin is silent until the marker exists, so the read must time out")
    case Err(e) -> assertTrue(false, "bounded read failed: " + IOError.message(e))
  }
  val waitedMs = (monotonicNanos() - start) / 1000000i64
  assertTrue(waitedMs >= 250i64, "the bounded read waited for its deadline")
  assertTrue(waitedMs < 10000i64, "the bounded read returned promptly after its deadline")
  checkNegativeTimeoutRejected(r)

  match writeText(marker, "ready") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "could not create the marker: " + IOError.message(e))
  }

  // Collect everything the writer sends until end of stream; the first read
  // is the one left outstanding by the timeout above.
  var received = ""
  var reading = true
  var ended = false
  while reading {
    match readStdinWithin(r, 30000) {
      case Ok(StdinBytes(bytes)) -> match tryDecodeUtf8(bytes) {
        case Some(text) -> {
          received = received + text
        }
        case None -> {
          assertTrue(false, "stdin bytes are not UTF-8")
          reading = false
        }
      }
      case Ok(StdinEnd) -> {
        ended = true
        reading = false
      }
      case Ok(StdinTimedOut) -> {
        assertTrue(false, "the writer's bytes did not arrive within 30 s")
        reading = false
      }
      case Err(e) -> {
        assertTrue(false, "read failed: " + IOError.message(e))
        reading = false
      }
    }
  }
  assertEqual(received, "late\n", "the bytes sent after the timeout arrive intact and in order")
  assertTrue(ended, "end of stream is reported")
  match readStdin(r) {
    case Ok(None) -> ()
    case Ok(Some(_)) -> assertTrue(false, "no bytes after end of stream")
    case Err(e) -> assertTrue(false, "unbounded read failed: " + IOError.message(e))
  }
  println("console_stdin_tests: ok")
  0
}
