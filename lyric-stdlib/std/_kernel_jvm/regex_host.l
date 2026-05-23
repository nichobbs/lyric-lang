// std/_kernel_jvm/regex_host.l — JVM kernel boundary for regex.
//
// Mirrors _kernel/regex_host.l for the JVM target.  All operations route
// through lyric.stdlib.jvm.RegexHost, which wraps java.util.regex.Pattern
// inside a JvmPattern envelope that carries the match timeout.
//
// java.util.regex.Pattern has no native match timeout.  The Phase 6
// lyric.stdlib.jvm.RegexHost shim implements timeout enforcement via a
// daemon thread that interrupts Matcher.find() after the configured deadline.
// The interrupted Matcher throws RuntimeException (message contains "time-out")
// so the Std.Regex isTimeout classifier treats it identically to the .NET
// RegexMatchTimeoutException.
//
// Functions are prefixed `host*` following the Std.HttpHost convention so
// that the public wrapper `std/regex.l` can call `RxHost.hostCompile(...)` etc.
// without triggering name-shadowing recursion.
//
// JvmPattern stores both the compiled Pattern and the timeout duration so
// match operations can enforce the deadline without extra parameters.
//
// The public Lyric API lives in std/regex.l (Std.Regex).  Import
// Std.RegexHost only in stdlib internals that need the raw JVM types.

@axiom("lyric.stdlib.jvm.RegexHost operations conform to their documented JVM / java.util.regex contracts")
package Std.RegexHost

import Std.Core

// JvmPattern wraps java.util.regex.Pattern + a timeout duration.
// Compiled by RegexHost.hostCompile / RegexHost.hostCompileWithTimeout.
extern type Regex = "lyric.stdlib.jvm.JvmPattern"
extern type Match = "lyric.stdlib.jvm.JvmMatcher"

// ─── Compilation ─────────────────────────────────────────────────────────────

// Default 1-second match timeout.
@externTarget("lyric.stdlib.jvm.RegexHost.compile")
pub func hostCompile(pattern: in String): Regex = ()

// Custom timeout in seconds (must be positive).
@externTarget("lyric.stdlib.jvm.RegexHost.compileWithTimeout")
pub func hostCompileWithTimeout(pattern: in String, seconds: in Double): Regex
  requires: seconds > 0.0
  = ()

// ─── Match operations ────────────────────────────────────────────────────────
//
// Each operation extracts the timeout from the JvmPattern envelope and runs
// Matcher.find() / replaceAll() on a daemon thread, interrupting after the
// deadline.  On timeout the shim throws RuntimeException with a message
// containing "time-out" so the isTimeout detector in Std.Regex classifies it.

// Returns true when the pattern matches anywhere in input.
@externTarget("lyric.stdlib.jvm.RegexHost.isMatch")
pub func hostIsMatch(r: in Regex, input: in String): Bool = ()

// Returns the first match as a JvmMatcher.  Callers check m.success.
@externTarget("lyric.stdlib.jvm.RegexHost.matchOne")
pub func hostMatchOne(r: in Regex, input: in String): Match = ()

// Replaces all non-overlapping occurrences of the pattern.
@externTarget("lyric.stdlib.jvm.RegexHost.replace")
pub func hostReplace(r: in Regex, input: in String, replacement: in String): String = ()

// ─── Match inspection ────────────────────────────────────────────────────────
//
// After hostMatchOne(r, input), inspect the JvmMatcher via:
//   m.success  — whether find() returned true
//   m.value    — Matcher.group()   (full matched text)
//   m.index    — Matcher.start()   (byte offset of match start)
//   m.length   — Matcher.end() - Matcher.start()
//
// Group access (Matcher.group(int)) is a Phase 6 follow-up.
