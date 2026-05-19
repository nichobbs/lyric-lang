// std/_kernel_jvm/process_capture_host.l — JVM host boundary for piped
// process execution (stdout capture).
//
// Mirrors _kernel/process_capture_host.l for the JVM target.  Used by
// the self-hosted verifier (`Lyric.Verifier`) to invoke z3/cvc5 and
// read their output, so `lyric prove --target jvm` depends on this
// shim.
//
// Routes through lyric.stdlib.jvm.ProcessCaptureHost, which wraps
// java.lang.ProcessBuilder + I/O capture: it sets `redirectErrorStream`
// (stderr → stdout), writes `stdinContent` to the child's stdin,
// closes stdin, and reads the child's stdout to completion via
// java.io.InputStreamReader.  Returns "" on spawn failure or I/O error.
//
// Internal: only Std.ProcessCapture should import this.

@axiom("lyric.stdlib.jvm.ProcessCaptureHost piped stdout capture")
package Std.ProcessCaptureHost

import Std.Core

// Run `executable` with a pre-formed `arguments` string (whitespace-
// split by the JVM shim), write `stdinContent` to the child's stdin,
// close stdin, and return the child's stdout text.  Returns "" on
// spawn failure or I/O error.
@externTarget("lyric.stdlib.jvm.ProcessCaptureHost.runCapture")
pub func hostRunCapture(executable: in String, arguments: in String, stdinContent: in String): String = ()
