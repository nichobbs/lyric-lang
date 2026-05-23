// std/_kernel_jvm/process_capture_host.l — JVM host boundary for piped
// process execution (stdout + stderr capture, exit code, timeout flag).
//
// Mirrors _kernel/process_capture_host.l for the JVM target.  Used by
// the self-hosted verifier (`Lyric.Verifier`) to invoke z3/cvc5 and
// by the source-generator runtime when running under `--target jvm`.
//
// Routes through lyric.stdlib.jvm.ProcessCaptureHost, which wraps
// java.lang.ProcessBuilder.  The implementation captures stdout and
// stderr on separate threads to prevent pipe-buffer deadlock, and
// returns a ProcessCaptureResult POJO with `stdout`, `stderr`,
// `exitCode`, and `timedOut` fields.
//
// Internal: only Std.ProcessCapture should import this.

@axiom("lyric.stdlib.jvm.ProcessCaptureHost piped stdout/stderr capture")
package Std.ProcessCaptureHost

import Std.Core

// Opaque handle to the JVM `lyric.stdlib.jvm.ProcessCaptureResult`
// POJO (#1025).  Field accessors below expose the individual fields
// so `Std.ProcessCapture` can project them into the public `CaptureResult`
// Lyric record without leaking the JVM type to callers.
extern type ProcessCaptureResult = "lyric.stdlib.jvm.ProcessCaptureResult"

// ── Field accessors ────────────────────────────────────────────────────────

@externTarget("lyric.stdlib.jvm.ProcessCaptureResult.getStdout")
pub func pcResultStdout(r: in ProcessCaptureResult): String = ()

@externTarget("lyric.stdlib.jvm.ProcessCaptureResult.getStderr")
pub func pcResultStderr(r: in ProcessCaptureResult): String = ()

@externTarget("lyric.stdlib.jvm.ProcessCaptureResult.getExitCode")
pub func pcResultExitCode(r: in ProcessCaptureResult): Int = ()

@externTarget("lyric.stdlib.jvm.ProcessCaptureResult.isTimedOut")
pub func pcResultTimedOut(r: in ProcessCaptureResult): Bool = ()

// ── Subprocess entry point ─────────────────────────────────────────────────

// Run `executable` with a pre-formed `arguments` string (whitespace-
// split by the JVM shim), write `stdinContent` to the child's stdin,
// close stdin, and return a `ProcessCaptureResult` with stdout, stderr,
// exit code, and whether the process was killed by the timeout.  Returns
// a result with empty strings and exitCode = -1 on spawn failure or I/O error.
@externTarget("lyric.stdlib.jvm.ProcessCaptureHost.runCapture")
pub func hostRunCapture(executable: in String, arguments: in String, stdinContent: in String): ProcessCaptureResult = ()

// Variant of `hostRunCapture` with a caller-supplied `timeoutMs` wall-clock
// cap.  Used by `Std.Process.runCapture` and `Std.Process.runCaptureWithInput`
// (#1023 / #743).
//
// JVM parity gap: `lyric.stdlib.jvm.ProcessCaptureHost.runCaptureWithTimeout`
// is tracked in #1065.  The method must drain stdout/stderr in parallel and
// call Process.waitFor(timeoutMs, MILLISECONDS); callers on the JVM target
// will receive a missing-method error until #1065 lands.
@externTarget("lyric.stdlib.jvm.ProcessCaptureHost.runCaptureWithTimeout")
pub func hostRunCaptureTimeout(executable: in String, arguments: in String, stdinContent: in String, timeoutMs: in Int): ProcessCaptureResult = ()
