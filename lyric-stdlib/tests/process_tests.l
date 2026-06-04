//! stdlib/tests/process_tests.l — tests for Std.Process piped-capture API.
//!
//! Covers: successful stdout capture, non-zero exit code, stderr capture,
//! stdin passthrough via `runCaptureWithInput`, and timeout enforcement.
//! All subprocess invocations use `sh -c "..."` and are therefore
//! POSIX-only.  On Windows the body of `main` short-circuits to
//! `exit 0` (with an informational println) so the file remains a
//! no-op there instead of breaking the harness with `sh: not found`.
//! Windows-compatible fixtures (`cmd /c` equivalents, or a portable
//! helper executable) are tracked in #1116.
package Std.Process.Tests

import Std.Core
import Std.Collections
import Std.Process
import Std.Testing

// Cross-platform OS gate — wraps `System.OperatingSystem.IsWindows()`
// directly so the test file doesn't depend on a non-existent
// `Std.Os` module.  The extern lives here (not in a stdlib package)
// because there is no good public home for platform-detection yet
// and this is the only consumer.  See #1116 for the proper module.
@externTarget("System.OperatingSystem.IsWindows")
func runningOnWindows(): Bool = ()

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

func main(): Int {
  if runningOnWindows() {
    // Every test below uses `sh -c "..."`, which is not present on a
    // stock Windows runner.  Skip-with-ok so the harness still
    // observes a success token, and surface the skip reason so the
    // gap (#1116) shows up in CI logs.
    println("process_tests: skipped on Windows pending cross-platform fixtures (#1116) — ok")
    return 0
  }
  testCaptureStdout()
  testCaptureNonZeroExit()
  testCaptureStderr()
  testCaptureStdinPassthrough()
  testCaptureTimeout()
  testCaptureBothStreams()
  testCaptureSpawnFailure()
  println("process_tests: ok")
  return 0
}
