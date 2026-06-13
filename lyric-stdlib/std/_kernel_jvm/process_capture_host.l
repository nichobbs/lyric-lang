//! std/_kernel_jvm/process_capture_host.l — JVM host boundary for piped
//! process execution (stdout + stderr capture, exit code, timeout flag).
//!
//! Mirrors _kernel/process_capture_host.l for the JVM target.  Used by
//! the self-hosted verifier (`Lyric.Verifier`) to invoke z3/cvc5 and
//! by the source-generator runtime when running under `--target jvm`.
//!
//! BLOCKED on a JVM codegen defect (#3307); see the gap note below.
//!
//! The production design for this kernel is **pure JVM auto-FFI against the
//! JDK** — no F# host shim and no external Java helper JAR, consistent with
//! the `_kernel_jvm/hash_host.l` precedent (M-9) and the project's no-new-shim
//! rule.  The intended implementation spawns the child via
//! `java.lang.Runtime.getRuntime().exec(String)`, drains stdout/stderr
//! incrementally inside the wait loop (`InputStream.available()`-bounded reads
//! into a `java.io.ByteArrayOutputStream`, so a >pipe-buffer child cannot
//! deadlock a single-threaded drainer), enforces the wall-clock cap by polling
//! `Process.isAlive()` against `System.currentTimeMillis()`
//! (`java.util.concurrent.TimeUnit` is an enum the auto-FFI resolver skips, so
//! `Process.waitFor(long, TimeUnit)` is unavailable), kills the child via
//! `Process.destroyForcibly()` on timeout, and returns a Lyric
//! `ProcessCaptureResult` record structurally identical to the .NET kernel's.
//!
//! That implementation was written and validated against the JDK API surface,
//! but it cannot land yet: every required drain/poll loop carries a
//! `Process` / `InputStream` / `ByteArrayOutputStream` extern handle across the
//! loop back-edge, and the JVM backend currently types extern-type locals as
//! `java/lang/Object` in the `StackMapTable` frame at a loop boundary, so the
//! emitted `invokevirtual` fails bytecode verification (`VerifyError: Bad type
//! on operand stack`).  Tracked as #3307 (`lyric-compiler/jvm/codegen/*`).  Once
//! #3307 is fixed, these stubs are replaced by the pure-auto-FFI body — the
//! signatures and `ProcessCaptureResult` shape below are already final.
//!
//! Internal: only Std.ProcessCapture and Std.Process should import this.
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
// (#1023 / #743).  The pure-auto-FFI body (see the file header) enforces the
// cap with an `isAlive()` / `currentTimeMillis()` poll and `destroyForcibly()`,
// returning `exitCode = -2` on timeout — but is blocked on the extern-local
// stackmap codegen defect #3307 (#1065).
@externTarget("lyric.stdlib.jvm.ProcessCaptureHost.runCaptureWithTimeout")
pub func hostRunCaptureTimeout(
  executable: in String, arguments: in String, stdinContent: in String, timeoutMs: in Int
): ProcessCaptureResult = ()
