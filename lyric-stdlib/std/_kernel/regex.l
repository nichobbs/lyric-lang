// std/_kernel/regex.l — Regex via System.Text.RegularExpressions.
//
// Bootstrap-grade surface: compile a pattern, test for matches,
// extract a captured group, and replace substrings.  More elaborate
// APIs (named groups, match collections, replace with backreferences)
// live behind follow-up FFI work.
//
// All compiled regexes carry a 1-second match timeout by default
// (via the Regex(string, RegexOptions, TimeSpan) overload).  A
// pattern like `(a+)+$` against a long adversarial string will throw
// RegexMatchTimeoutException instead of hanging indefinitely.  Use
// `compileWithTimeout` to override the timeout for known-safe patterns.
//
// Note: `isMatch`, `matchOne`, and `replace` propagate
// RegexMatchTimeoutException as an unchecked exception on timeout.
// A future `std/regex.l` wrapper will map these to Result[_, RegexError].

@axiom("System.Text.RegularExpressions.Regex / .Match conform to their documented .NET contracts")
package Std.Regex

import Std.Core

extern type Regex       = "System.Text.RegularExpressions.Regex"
extern type Match       = "System.Text.RegularExpressions.Match"
extern type TimeSpan    = "System.TimeSpan"
extern type RegexOptions = "System.Text.RegularExpressions.RegexOptions"

// ─── Private BCL bindings ────────────────────────────────────────────────────

// TimeSpan.FromSeconds(double) — creates a timeout duration.
@externTarget("System.TimeSpan.FromSeconds")
func timeSpanFromSeconds(seconds: in Double): TimeSpan = ()

// RegexOptions.None (flags value 0).
@externTarget("System.Text.RegularExpressions.RegexOptions.None")
func regexOptionsNone(): RegexOptions = ()

// 3-argument Regex constructor: pattern, options, matchTimeout.
// The FFI picks this overload over the 1-arg ctor when 3 args are supplied.
@externTarget("System.Text.RegularExpressions.Regex..ctor")
func compileRaw(pattern: in String, options: in RegexOptions, timeout: in TimeSpan): Regex = ()

// ─── Public API ──────────────────────────────────────────────────────────────

/// Compile a regex pattern with a default 1-second match timeout.
///
/// Any match operation on the returned Regex that runs for more than
/// one second will throw RegexMatchTimeoutException instead of hanging.
/// For trusted, simple patterns that can never catastrophically backtrack,
/// use `compileWithTimeout` with a longer or disabled timeout.
@stable(since="1.0")
pub func compile(pattern: in String): Regex {
  compileRaw(pattern, regexOptionsNone(), timeSpanFromSeconds(1.0))
}

/// Compile a regex pattern with a custom timeout in seconds.
///
/// `seconds` must be positive.  Typical values: 5.0 for interactive
/// workloads, 60.0 for batch pipelines.  Use `compile` for the common
/// case; only override when 1 second is too tight for a known pattern.
@stable(since="1.0")
pub func compileWithTimeout(pattern: in String, seconds: in Double): Regex
  requires: seconds > 0.0
{
  compileRaw(pattern, regexOptionsNone(), timeSpanFromSeconds(seconds))
}

@externTarget("System.Text.RegularExpressions.Regex.IsMatch")
pub func isMatch(r: in Regex, input: in String): Bool = ()

@externTarget("System.Text.RegularExpressions.Regex.Match")
pub func matchOne(r: in Regex, input: in String): Match = ()

@externTarget("System.Text.RegularExpressions.Regex.Replace")
pub func replace(r: in Regex, input: in String, replacement: in String): String = ()

// ─── Match inspection ────────────────────────────────────────────────────────
//
// Direct method-style works on a `Match` value obtained from `matchOne`:
//   m.success  — Match.Success (Bool)
//   m.value    — Match.Value   (String — full match text)
//   m.length   — Match.Length  (Int)
//   m.index    — Match.Index   (Int)
//
// Group access (m.Groups[i]) needs an indexer into a non-array container
// and is deferred until GroupCollection.get_Item is wired cleanly.
