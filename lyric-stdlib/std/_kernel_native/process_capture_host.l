//! std/_kernel_native/process_capture_host.l — native-target piped
//! process execution.
//!
//! The `--target native` twin of `_kernel/process_capture_host.l`,
//! selected by the native source loader by basename.  Implements the
//! list-argv Result seam (issue #4752) that `Std.Process` delegates to,
//! over lyric-rt's `lyric_process_run` (fork + execvp, never a shell —
//! the argv list is passed through verbatim with no quoting or word
//! splitting).
//!
//! Deferred (issue #4752): `lyric_process_run` has no stdin pipe and no
//! timeout kill yet, so a non-empty `stdinContent` is an explicit `Err`
//! rather than a silent drop, `timeoutMs` is ignored, and `timedOut` is
//! always false.
@axiom("fork/execvp piped process capture via lyric-rt conforms to its documented contract")
package Std.ProcessCaptureHost

import Std.Core
import Std.Collections

// ── Public result record ───────────────────────────────────────────────────
pub record ProcessCaptureResult {
  stdout: String
  stderr: String
  exitCode: Int
  timedOut: Bool
}

// Field accessors — the same surface the managed twin exports for
// Std.ProcessCapture and Std.Process.
pub func pcResultStdout(r: in ProcessCaptureResult): String {
  r.stdout
}

pub func pcResultStderr(r: in ProcessCaptureResult): String {
  r.stderr
}

pub func pcResultExitCode(r: in ProcessCaptureResult): Int {
  r.exitCode
}

pub func pcResultTimedOut(r: in ProcessCaptureResult): Bool {
  r.timedOut
}

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

// `args` is the raw kernel handle of a Std.Collections `List[String]`
// (LyricList*): collection values ride extern `NativePtr[Byte]`
// parameters as their kernel pointers (N4.5 argument adaptation).
extern func rtProcessRun(path: NativePtr[Byte], args: NativePtr[Byte], outCode: NativePtr[Int], outStdout: NativePtr[String], outStderr: NativePtr[String]): Int = "lyric_process_run"

@unsafe_ffi
pub func hostRunCaptureList(
  executable: in String, args: in List[String], stdinContent: in String, timeoutMs: in Int
): Result[ProcessCaptureResult, String] {
  if stdinContent.length > 0 {
    return Err(error = "the native process runner does not support writing to the child's stdin yet (issue #4752)")
  }
  var code: Int = 0
  var outText: String = ""
  var errText: String = ""
  val c = toC(executable)
  val rc = rtProcessRun(c, args, nativeAddrOf(code), nativeAddrOf(outText), nativeAddrOf(errText))
  freeC(c)
  if rc == 0 {
    Ok(value = ProcessCaptureResult(stdout = outText, stderr = errText, exitCode = code, timedOut = false))
  } else {
    Err(error = "failed to spawn process: " + executable)
  }
}
