//! std/_kernel/regex_host.l — .NET kernel boundary for System.Text.RegularExpressions.
//!
//! Provides hostCompile, hostIsMatch, hostMatchOne, and hostReplace over the
//! BCL Regex class.  Every compiled pattern carries a 1-second match timeout
//! by default (via the Regex(string, RegexOptions, TimeSpan) overload).  A
//! catastrophic-backtracking pattern like `(a+)+$` against adversarial input
//! will throw RegexMatchTimeoutException instead of hanging indefinitely.
//!
//! Functions are prefixed `host*` following the Std.HttpHost convention so
//! that the public wrapper `std/regex.l` can call `RxHost.hostCompile(...)` etc.
//! without triggering name-shadowing recursion when its own functions share the
//! clean (unprefixed) names.
//!
//! This is the kernel boundary file.  The public Lyric API lives in
//! `std/regex.l` (Std.Regex); import that module in application code.
//! Import Std.RegexHost only in stdlib internals that need the raw BCL types.
@axiom("System.Text.RegularExpressions.Regex / .Match conform to their documented .NET contracts")
package Std.RegexHost

import Std.Core

extern type Regex = "System.Text.RegularExpressions.Regex"

extern type Match = "System.Text.RegularExpressions.Match"

extern type TimeSpan = "System.TimeSpan"

extern type RegexOptions = "System.Text.RegularExpressions.RegexOptions"

// ─── Private BCL bindings ────────────────────────────────────────────────────
// TimeSpan.FromSeconds(double) — creates a timeout duration.
func timeSpanFromSeconds(seconds: in Double): TimeSpan {
  TimeSpan.FromSeconds(seconds)
}

// RegexOptions.None (flags value 0).
func regexOptionsNone(): RegexOptions {
  RegexOptions.None
}

// 3-argument Regex constructor: pattern, options, matchTimeout.
// Overload scoring picks this ctor over the 1-arg form by exact arity.
func hostCompileRaw(pattern: in String, options: in RegexOptions, timeout: in TimeSpan): Regex {
  Regex.new(pattern, options, timeout)
}

// ─── Public API ──────────────────────────────────────────────────────────────
/// Compile a regex pattern with a default 1-second match timeout.
///
/// Match operations that run for more than one second throw
/// RegexMatchTimeoutException instead of hanging.  Use `hostCompileWithTimeout`
/// to override for known-safe patterns.
@stable(since = "1.0")
pub func hostCompile(pattern: in String): Regex {
  hostCompileRaw(pattern, regexOptionsNone(), timeSpanFromSeconds(1.0))
}

/// Compile a regex pattern with a custom timeout in seconds.
///
/// `seconds` must be positive.  Typical values: 5.0 for interactive
/// workloads, 60.0 for batch pipelines.
@stable(since = "1.0")
pub func hostCompileWithTimeout(pattern: in String, seconds: in Double): Regex
  requires: seconds > 0.0
{
  hostCompileRaw(pattern, regexOptionsNone(), timeSpanFromSeconds(seconds))
}

pub func hostIsMatch(r: in Regex, input: in String): Bool {
  r.IsMatch(input)
}

pub func hostMatchOne(r: in Regex, input: in String): Match {
  r.Match(input)
}

pub func hostReplace(r: in Regex, input: in String, replacement: in String): String {
  r.Replace(input, replacement)
}

// ─── Match inspection ────────────────────────────────────────────────────────
//
// Direct method-style works on a `Match` value obtained from `hostMatchOne`:
//   m.success  — Match.Success (Bool)
//   m.value    — Match.Value   (String — full match text)
//   m.length   — Match.Length  (Int)
//   m.index    — Match.Index   (Int)
//
// Group access (m.Groups[i]) needs an indexer into a non-array container
// and is deferred until GroupCollection.get_Item is wired cleanly.
