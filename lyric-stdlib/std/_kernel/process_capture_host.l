// std/_kernel/process_capture_host.l — trusted host boundary for piped
// process execution (stdout + stderr capture, exit code, timeout flag).
//
// Used by the self-hosted verifier (`Lyric.Verifier`) to invoke z3/cvc5
// and by the source-generator runtime (`Lyric.Generator`) to invoke
// generator DLLs.  The implementation lives in
// `Lyric.Emitter.ProcessCapture.runCapture` (always loaded in the
// AppDomain when emitting or running self-hosted Lyric code).
//
// Internal: only Std.ProcessCapture and Std.Process should import this.

@axiom("System.Diagnostics.Process piped stdout/stderr capture")
package Std.ProcessCaptureHost

import Std.Core

// Opaque handle to the F# `Lyric.Emitter.ProcessCapture.CaptureResult`
// record (#1025).  Field accessors below expose the individual fields
// so `Std.ProcessCapture` can project them into the public `CaptureResult`
// Lyric record without leaking the BCL type to callers.
extern type ProcessCaptureResult = "Lyric.Emitter.ProcessCapture+CaptureResult"

// ── Field accessors ────────────────────────────────────────────────────────

@externTarget("Lyric.Emitter.ProcessCapture+CaptureResult.Stdout")
pub func pcResultStdout(r: in ProcessCaptureResult): String = ()

@externTarget("Lyric.Emitter.ProcessCapture+CaptureResult.Stderr")
pub func pcResultStderr(r: in ProcessCaptureResult): String = ()

@externTarget("Lyric.Emitter.ProcessCapture+CaptureResult.ExitCode")
pub func pcResultExitCode(r: in ProcessCaptureResult): Int = ()

@externTarget("Lyric.Emitter.ProcessCapture+CaptureResult.TimedOut")
pub func pcResultTimedOut(r: in ProcessCaptureResult): Bool = ()

// ── Subprocess entry point ─────────────────────────────────────────────────

// Run `executable` with a pre-formed `arguments` string, write
// `stdinContent` to the child's stdin, close stdin, and return a
// `ProcessCaptureResult` with stdout, stderr, exit code, and whether the
// process was killed by the 10-second timeout.  Returns a result with empty
// strings and ExitCode = -1 on spawn failure or I/O error.
@externTarget("Lyric.Emitter.ProcessCapture.runCapture")
pub func hostRunCapture(executable: in String, arguments: in String, stdinContent: in String): ProcessCaptureResult = ()

// Variant of `hostRunCapture` with a caller-supplied `timeoutMs` wall-clock
// cap.  Used by `Std.Process.runCapture` and `Std.Process.runCaptureWithInput`
// (#1023 / #743).
@externTarget("Lyric.Emitter.ProcessCapture.runCaptureWithTimeout")
pub func hostRunCaptureTimeout(executable: in String, arguments: in String, stdinContent: in String, timeoutMs: in Int): ProcessCaptureResult = ()
