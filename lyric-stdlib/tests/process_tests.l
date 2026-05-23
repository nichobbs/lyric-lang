// stdlib/tests/process_tests.l — tests for Std.Process piped-capture API.
//
// Covers: successful stdout capture, non-zero exit code, stderr capture,
// stdin passthrough via `runCaptureWithInput`, and timeout enforcement.
// All subprocess invocations use `sh -c "..."` so the tests are portable
// across Linux and macOS CI environments.

package Std.Process.Tests

import Std.Core
import Std.Collections
import Std.Process
import Std.Testing

func makeArgs(a: in String): List[String] {
  val args: List[String] = newList()
  args.add(a)
  args
}

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

func main(): Int {
  testCaptureStdout()
  testCaptureNonZeroExit()
  testCaptureStderr()
  testCaptureStdinPassthrough()
  testCaptureTimeout()
  testCaptureBothStreams()
  println("process_tests: ok")
  return 0
}
