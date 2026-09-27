//! stdlib/tests/process_tests.l — tests for Std.Process piped-capture API.
//!
//! Covers: successful stdout capture, non-zero exit code, stderr capture,
//! stdin passthrough via `runCaptureWithInput`, and timeout enforcement.
//! All subprocess invocations use `sh -c "..."` and are therefore
//! POSIX-only.  On Windows (`Std.Environment.isWindows()`) the body of
//! `main` returns 0 with an informational println, so the file is a no-op
//! there instead of failing with `sh: not found`; Windows fixtures were
//! declined in #1116.
package Std.Process.Tests

import Std.Core
import Std.Collections
import Std.Environment
import Std.Errors
import Std.Process
import Std.Testing
import Std.Time

func makeShArgs(cmd: in String): List[String] {
  val args: List[String] = newList()
  args.add("-c")
  args.add(cmd)
  args
}

func testCaptureStdout(): Unit {
  val args = makeShArgs("printf 'hello world'")
  match runCapture("sh", args, 5000) {
    case Ok(r) -> {
      assertEqual(r.stdout, "hello world", "stdout captured correctly")
      assertEqualInt(r.exitCode, 0, "exit code is 0")
      assertTrue(not r.timedOut, "process did not time out")
    }
    case Err(e) -> assertTrue(false, "runCapture failed: " + e)
  }
}

func testCaptureNonZeroExit(): Unit {
  val args = makeShArgs("exit 42")
  match runCapture("sh", args, 5000) {
    case Ok(r) -> assertEqualInt(r.exitCode, 42, "non-zero exit code propagated")
    case Err(e) -> assertTrue(false, "runCapture failed: " + e)
  }
}

func testCaptureStderr(): Unit {
  val args = makeShArgs("printf 'err output' >&2")
  match runCapture("sh", args, 5000) {
    case Ok(r) -> {
      assertEqual(r.stderr, "err output", "stderr captured correctly")
      assertEqual(r.stdout, "", "stdout is empty when only stderr written")
      assertEqualInt(r.exitCode, 0, "exit code is 0")
    }
    case Err(e) -> assertTrue(false, "runCapture failed: " + e)
  }
}

func testCaptureStdinPassthrough(): Unit {
  val args = makeShArgs("cat")
  match runCaptureWithInput("sh", args, "passed in\n", 5000) {
    case Ok(r) -> {
      assertEqual(r.stdout, "passed in\n", "stdin passed through cat to stdout")
      assertEqualInt(r.exitCode, 0, "exit code is 0")
    }
    case Err(e) -> assertTrue(false, "runCaptureWithInput failed: " + e)
  }
}

func testCaptureTimeout(): Unit {
  val args = makeShArgs("sleep 30")
  match runCapture("sh", args, 200) {
    case Ok(r) -> assertTrue(r.timedOut, "process must have timed out")
    case Err(e) -> assertTrue(false, "runCapture failed: " + e)
  }
}

func testCaptureBothStreams(): Unit {
  val args = makeShArgs("printf 'out'; printf 'err' >&2")
  match runCapture("sh", args, 5000) {
    case Ok(r) -> {
      assertEqual(r.stdout, "out", "stdout captured while stderr present")
      assertEqual(r.stderr, "err", "stderr captured while stdout present")
    }
    case Err(e) -> assertTrue(false, "runCapture failed: " + e)
  }
}

func testCaptureSpawnFailure(): Unit {
  // A deliberately nonexistent executable must return Err, not Ok with exitCode = -1.
  val args: List[String] = newList()
  match runCapture("__lyric_definitely_nonexistent_exe_xyz__", args, 5000) {
    case Ok(_) -> assertTrue(false, "nonexistent executable must return Err")
    case Err(_) -> assertTrue(true, "spawn failure returns Err")
  }
}

func testRunExitCode(): Unit {
  match run("sh", makeShArgs("exit 7")) {
    case Ok(code) -> assertEqualInt(code, 7, "run returns the child's exit code")
    case Err(e) -> assertTrue(false, "run failed: " + IOError.message(e))
  }
}

func testRunSpawnFailure(): Unit {
  // Every target reports an executable that cannot be started as Err, not as
  // an exit code (the native twin would otherwise see execvp's 127).
  val args: List[String] = newList()
  match run("__lyric_definitely_nonexistent_exe_xyz__", args) {
    case Ok(code) -> assertTrue(false, "nonexistent executable must return Err, got exit code " + code.toString())
    case Err(_) -> assertTrue(true, "spawn failure returns Err")
  }
}

// #7251: a negative timeout is a programmer error, rejected before any child
// is spawned.  Zero stays legal ("kill at the first pump").
func testNegativeTimeoutRejected(): Unit {
  assertPanics("runCapture with a negative timeout", { -> val _ = runCapture("sh", makeShArgs("true"), -1) })
  assertPanics(
    "runCaptureWithInput with a negative timeout",
    { -> val _ = runCaptureWithInput("sh", makeShArgs("cat"), "x", -1) }
  )
  match spawnPiped("sh", makeShArgs("cat")) {
    case Ok(p) -> {
      assertPanics("pipedWaitExit with a negative timeout", { -> val _ = pipedWaitExit(p, -1) })
      assertPanics("pipedReadLineWithin with a negative timeout", { -> val _ = pipedReadLineWithin(p, -1) })
      pipedKill(p)
    }
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
  }
}

// #7451: a silent child makes a bounded read time out instead of blocking,
// and a line that arrives after the deadline is returned by the next read.
func testPipedReadLineWithinTimesOut(): Unit {
  match spawnPiped("cat", newList()) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      val start = monotonicNanos()
      match pipedReadLineWithin(p, 150) {
        case Ok(PipedTimedOut) -> ()
        case Ok(other) -> assertTrue(false, "a silent child must time out")
        case Err(e) -> assertTrue(false, "bounded read failed: " + e)
      }
      val waitedMs = (monotonicNanos() - start) / 1000000i64
      assertTrue(waitedMs >= 100i64, "the bounded read waited for its deadline")
      assertTrue(waitedMs < 10000i64, "the bounded read returned promptly after its deadline")
      match pipedWriteLine(p, "late line") {
        case Err(e) -> assertTrue(false, "write failed: " + e)
        case Ok(_) -> ()
      }
      match pipedReadLineWithin(p, 5000) {
        case Ok(PipedLine(line)) -> assertEqual(line, "late line", "the late line is delivered by the next read")
        case Ok(_) -> assertTrue(false, "expected the late line")
        case Err(e) -> assertTrue(false, "bounded read failed: " + e)
      }
      pipedWriteLine(p, "unbounded")
      match pipedReadLine(p) {
        case Ok(Some(line)) -> assertEqual(line, "unbounded", "an unbounded read still works after a timeout")
        case _ -> assertTrue(false, "expected 'unbounded'")
      }
      pipedCloseStdin(p)
      match pipedReadLineWithin(p, 5000) {
        case Ok(PipedEndOfStream) -> ()
        case Ok(_) -> assertTrue(false, "expected end of stream after the child exits")
        case Err(e) -> assertTrue(false, "bounded read failed: " + e)
      }
      pipedKill(p)
      pipedWaitExit(p, 3000)
      pipedClose(p)
    }
  }
}

// A timeout that falls mid-line keeps the partial line: the next read joins
// it with the rest instead of dropping or splitting it.
func testPipedReadLineWithinKeepsPartialLine(): Unit {
  match spawnPiped("sh", makeShArgs("printf abc; sleep 1; printf 'def\\n'")) {
    case Err(e) -> assertTrue(false, "spawnPiped failed: " + IOError.message(e))
    case Ok(p) -> {
      match pipedReadLineWithin(p, 300) {
        case Ok(PipedTimedOut) -> ()
        case Ok(_) -> assertTrue(false, "the line is incomplete at the deadline")
        case Err(e) -> assertTrue(false, "bounded read failed: " + e)
      }
      match pipedReadLineWithin(p, 10000) {
        case Ok(PipedLine(line)) -> assertEqual(line, "abcdef", "the partial line is completed, not split")
        case Ok(_) -> assertTrue(false, "expected the completed line")
        case Err(e) -> assertTrue(false, "bounded read failed: " + e)
      }
      pipedWaitExit(p, 5000)
      pipedClose(p)
    }
  }
}

func main(): Int {
  if isWindows() {
    // Every test below uses `sh -c "..."`, which is not present on a
    // stock Windows runner.
    println("process_tests: skipped on Windows (the fixtures use sh) — ok")
    return 0
  }
  testCaptureStdout()
  testCaptureNonZeroExit()
  testCaptureStderr()
  testCaptureStdinPassthrough()
  testCaptureTimeout()
  testCaptureBothStreams()
  testCaptureSpawnFailure()
  testRunExitCode()
  testRunSpawnFailure()
  testNegativeTimeoutRejected()
  testPipedReadLineWithinTimesOut()
  testPipedReadLineWithinKeepsPartialLine()
  println("process_tests: ok")
  return 0
}
