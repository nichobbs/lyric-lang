//! process_stdin_self_test.l — `Std.Process.runCaptureWithInput` with stdin
//! larger than a pipe buffer (#7262).
//!
//! The .NET and JVM kernels used to write all of stdin before they started
//! draining the child's output. A child that fills its stdout pipe (~64 KB)
//! before it has read all of its input, such as `cat` on a large input, then
//! blocked on write while the parent blocked on the stdin write, and the
//! timeout was never reached. The native kernel already interleaves, and
//! lyric-rt's C tests pin the same three cases there.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/process_stdin_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/process_stdin_self_test.l
//! POSIX-only (`/bin/cat`, `/bin/sh`, `/bin/sleep`), like the CI runners.
@test_module
package Lyric.ProcessStdinSelfTest

import Std.Core
import Std.Collections
import Std.String
import Std.Process
import Std.Testing

// 256 KiB: far beyond the pipe buffer in both directions.
func bigInput(): String {
  val sb = StringBuilder.new()
  var i = 0
  while i < 4096 {
    sb.append("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!?")
    i += 1
  }
  sb.toString()
}

func noArgs(): List[String] {
  newList()
}

test "a large stdin round-trips through cat without deadlocking" {
  val input = bigInput()
  match runCaptureWithInput("/bin/cat", noArgs(), input, 30000) {
    case Ok(r) -> {
      assertFalse(r.timedOut, "cat finished within the timeout")
      assertEqualInt(r.exitCode, 0, "cat exit code")
      assertEqualInt(r.stdout.length, input.length, "all input echoed back")
      assertTrue(r.stdout == input, "echoed content matches")
    }
    case Err(e) -> assertTrue(false, "spawn failed: " + e)
  }
}

test "a child that exits without reading its stdin still completes" {
  val args: List[String] = newList()
  args.add("-c")
  args.add("echo done")
  match runCaptureWithInput("/bin/sh", args, bigInput(), 30000) {
    case Ok(r) -> {
      assertFalse(r.timedOut, "no timeout")
      assertEqualInt(r.exitCode, 0, "sh exit code")
      assertTrue(r.stdout.contains("done"), "child output captured")
    }
    case Err(e) -> assertTrue(false, "spawn failed: " + e)
  }
}

test "a child that never reads its stdin times out instead of hanging" {
  val args: List[String] = newList()
  args.add("30")
  match runCaptureWithInput("/bin/sleep", args, bigInput(), 1500) {
    case Ok(r) -> assertTrue(r.timedOut, "timed out")
    case Err(e) -> assertTrue(false, "spawn failed: " + e)
  }
}
