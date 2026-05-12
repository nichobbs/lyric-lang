// std/_kernel/process_capture_host.l — trusted host boundary for piped
// process execution (stdout capture).
//
// Used by the self-hosted verifier (`Lyric.Verifier`) to invoke z3/cvc5
// and read their output.  The implementation lives in
// `Lyric.Emitter.ProcessCapture.runCapture` (always loaded in the
// AppDomain when emitting or running self-hosted Lyric code).
//
// Internal: only Std.ProcessCapture should import this.

@axiom("System.Diagnostics.Process piped stdout capture")
package Std.ProcessCaptureHost

import Std.Core

// Run `executable` with a pre-formed `arguments` string, write
// `stdinContent` to the child's stdin, close stdin, and return the
// child's stdout text.  Returns "" on spawn failure or I/O error.
@externTarget("Lyric.Emitter.ProcessCapture.runCapture")
pub func hostRunCapture(executable: in String, arguments: in String, stdinContent: in String): String = ()
