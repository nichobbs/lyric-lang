//! process_capture_jvm_self_test.l — CI gate for #1065: JVM implementation of
//! `Std.ProcessCaptureHost` using pure JDK auto-FFI (ProcessBuilder + Process +
//! stream draining).
//!
//! Exercises the full `Std.ProcessCapture` public API against real POSIX
//! subprocesses.  Each test spawns a real child process (echo, cat, sh, true,
//! false) and asserts the captured output and exit code.  This covers:
//!
//!   - Argument round-trip: `buildArgString` → `parseArgString` → `ProcessBuilder`
//!   - Stdout capture via `InputStream.available()` drain loop into BAOS
//!   - Stdin delivery via `OutputStream.write(byte[])` + close
//!   - Exit-code projection and `CaptureResult` field accessors
//!   - Timeout path (destroyForcibly + exitCode = -2, timedOut = true)
//!   - Multi-word arguments with interior spaces (quoting round-trip)
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/process_capture_jvm_self_test.l
//!
//! Requires POSIX utilities at standard paths (/bin/echo, /bin/cat, /bin/sh,
//! /bin/true, /bin/false).  Imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ProcessCaptureJvmSelfTest

import Std.Core
import Std.Testing
import Std.Collections
import Std.ProcessCapture

test "echo hello: stdout captured with trailing newline (#1065)" {
  val args: List[String] = newList()
  args.add("hello")
  val captured = runCapture("/bin/echo", args, "")
  assertEqual(captured, "hello\n", "echo hello stdout")
}

test "echo with two arguments (#1065)" {
  val args: List[String] = newList()
  args.add("foo")
  args.add("bar")
  val captured = runCapture("/bin/echo", args, "")
  assertEqual(captured, "foo bar\n", "echo foo bar stdout")
}

test "echo with multi-word argument preserves interior space (quoting round-trip) (#1065)" {
  val args: List[String] = newList()
  args.add("hello world")
  val captured = runCapture("/bin/echo", args, "")
  assertEqual(captured, "hello world\n", "echo 'hello world' preserves space in arg")
}

test "cat: stdin content returned on stdout (#1065)" {
  val noArgs: List[String] = newList()
  val captured = runCapture("/bin/cat", noArgs, "hello from stdin\n")
  assertEqual(captured, "hello from stdin\n", "cat echoes stdin to stdout")
}

test "exit code 0 from /bin/true (#1065)" {
  val noArgs: List[String] = newList()
  val result = runCaptureWithDiagnostics("/bin/true", noArgs, "")
  assertEqualInt(result.exitCode, 0, "true exits 0")
  assertFalse(result.timedOut, "true does not time out")
}

test "exit code 1 from /bin/false (#1065)" {
  val noArgs: List[String] = newList()
  val result = runCaptureWithDiagnostics("/bin/false", noArgs, "")
  assertEqualInt(result.exitCode, 1, "false exits 1")
  assertFalse(result.timedOut, "false does not time out")
}

test "exit code 42 from sh -c 'exit 42' (#1065)" {
  val args: List[String] = newList()
  args.add("-c")
  args.add("exit 42")
  val result = runCaptureWithDiagnostics("/bin/sh", args, "")
  assertEqualInt(result.exitCode, 42, "sh -c 'exit 42' exits 42")
  assertFalse(result.timedOut, "shell exit does not time out")
}

test "stderr captured separately from stdout (#1065)" {
  val args: List[String] = newList()
  args.add("-c")
  args.add("echo stdout_line; echo stderr_line >&2")
  val result = runCaptureWithDiagnostics("/bin/sh", args, "")
  assertEqual(result.stdout, "stdout_line\n", "stdout contains only the stdout line")
  assertEqual(result.stderr, "stderr_line\n", "stderr captured separately")
}

test "empty stdout when command produces no output (#1065)" {
  val noArgs: List[String] = newList()
  val result = runCaptureWithDiagnostics("/bin/true", noArgs, "")
  assertEqual(result.stdout, "", "true produces no stdout")
  assertEqual(result.stderr, "", "true produces no stderr")
}

test "timeout fires: timedOut = true and exitCode = -2 (#1065)" {
  val args: List[String] = newList()
  args.add("-c")
  args.add("sleep 60")
  val result = runCaptureWithDiagnosticsTimeout("/bin/sh", args, "", 300)
  assertTrue(result.timedOut, "sleep 60 timed out within 300 ms")
  assertEqualInt(result.exitCode, -2, "timed-out process returns exitCode -2")
}
