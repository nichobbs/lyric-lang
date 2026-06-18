// std/regex.l — Public Std.Regex API.
//
// Builds a safe, ReDoS-resistant regex surface over Std.RegexHost.
// Every compiled pattern carries a 1-second match timeout by default.
// Use `compileWithTimeout` to override.  Result-prefixed functions map
// timeout and invalid-pattern exceptions to typed errors instead of
// letting them propagate as unhandled panics.
//
// ReDoS posture:
//   .NET — RegexMatchTimeoutException fires after the configured deadline.
//   JVM  — lyric.stdlib.jvm.RegexHost interrupts Matcher.find() on a
//           daemon thread after the deadline; throws RuntimeException
//           with "time-out" in the message.
//
// Recommended usage for user-controlled patterns: tryCompile + tryIsMatch.
// Hard-coded, non-backtracking patterns can use compile + isMatch directly.
//
// Note: matchOne / matchAll group-capture APIs are deferred to a follow-up
// PR (#330 Phase 2) that adds @externTarget field-extractor externs for the
// .NET Match type to the kernel.  Use isMatch for boolean checks and
// tryIsMatch for the ReDoS-safe path.

@runtime_checked
package Std.Regex

import Std.Core
import Std.RegexHost as RxHost

// ─── Error type ──────────────────────────────────────────────────────────────

/// Errors returned by the Result-shaped regex API.
@stable(since="1.0")
pub union RegexError {
  /// The regex engine exceeded the pattern's match timeout.  The usual
  /// root cause is catastrophic backtracking on adversarial input.
  case TimedOut(message: String)
  /// The pattern string is syntactically invalid, or another unexpected
  /// BCL/JVM exception was thrown during compilation or matching.
  case InvalidPattern(message: String)
}

/// Format a `RegexError` as a human-readable string.
@stable(since="1.0")
pub func errorMessage(e: in RegexError): String {
  match e {
    case TimedOut(m)       -> "regex match timed out: " + m
    case InvalidPattern(m) -> "invalid regex pattern: " + m
  }
}

// ─── Opaque handle ───────────────────────────────────────────────────────────

/// A compiled regular expression with an embedded match timeout.
///
/// Obtain via `compile` or `compileWithTimeout`.  Pass to `isMatch`,
/// `replace`, or the Result-returning `try*` variants.  The timeout is
/// baked in at compile time; every match operation automatically enforces it.
@stable(since="1.0")
pub opaque type CompiledRegex {
  handle: RxHost.Regex
}

// ─── Compilation ─────────────────────────────────────────────────────────────

/// Compile a regex pattern with the default 1-second match timeout.
///
/// Throws on invalid pattern syntax.  For user-controlled patterns use
/// `tryCompile` instead.
@stable(since="1.0")
pub func compile(pattern: in String): CompiledRegex {
  CompiledRegex(handle = RxHost.hostCompile(pattern))
}

/// Compile a regex pattern with a custom timeout in seconds.
///
/// `seconds` must be positive.  Typical values: 5.0 for interactive
/// workloads, 60.0 for long-running batch pipelines.
@stable(since="1.0")
pub func compileWithTimeout(pattern: in String, seconds: in Double): CompiledRegex
  requires: seconds > 0.0
{
  CompiledRegex(handle = RxHost.hostCompileWithTimeout(pattern, seconds))
}

/// Compile a regex pattern, returning `Err(InvalidPattern)` on invalid syntax.
///
/// Use this when the pattern comes from outside the program (config file,
/// network input, user-typed search box).
@stable(since="1.0")
pub func tryCompile(pattern: in String): Result[CompiledRegex, RegexError] {
  return try {
    Ok(value = compile(pattern))
  } catch Bug as b {
    Err(error = InvalidPattern(message = b.message))
  }
}

// ─── Boolean match ────────────────────────────────────────────────────────────

/// Return true when `input` contains at least one match for `r`.
///
/// Throws `Bug` on timeout (use `tryIsMatch` for Result behaviour).
@stable(since="1.0")
pub func isMatch(r: in CompiledRegex, input: in String): Bool {
  RxHost.hostIsMatch(r.handle, input)
}

/// Return true / false, or `Err(TimedOut)` when the match exceeds the
/// compiled timeout.
@stable(since="1.0")
pub func tryIsMatch(r: in CompiledRegex, input: in String): Result[Bool, RegexError] {
  return try {
    Ok(value = RxHost.hostIsMatch(r.handle, input))
  } catch Bug as b {
    Err(error = classifyBug(b.message))
  }
}

// ─── Replace ─────────────────────────────────────────────────────────────────

/// Replace every match of `r` in `input` with `replacement`.
///
/// Throws `Bug` on timeout (use `tryReplace` for Result behaviour).
@stable(since="1.0")
pub func replace(r: in CompiledRegex, input: in String, replacement: in String): String {
  RxHost.hostReplace(r.handle, input, replacement)
}

/// Replace every match, or `Err(TimedOut)` on regex-engine overrun.
@stable(since="1.0")
pub func tryReplace(
  r:           in CompiledRegex,
  input:       in String,
  replacement: in String
): Result[String, RegexError] {
  return try {
    Ok(value = RxHost.hostReplace(r.handle, input, replacement))
  } catch Bug as b {
    Err(error = classifyBug(b.message))
  }
}

// ─── Private helpers ─────────────────────────────────────────────────────────

func classifyBug(msg: in String): RegexError {
  if isTimeout(msg) { TimedOut(message = msg) }
  else              { InvalidPattern(message = msg) }
}

// Best-effort classifier: scans for "time-out" (en-US BCL / JVM shim phrase).
// The BCL message is satellite-resource-localised in non-en-US runtimes; when
// the phrase is absent we conservatively map to InvalidPattern.  Callers that
// distinguish TimedOut from InvalidPattern for retry/reporting logic will make
// the wrong decision on non-en-US deployments.  A locale-stable classifier
// requires exposing the exception's runtime class as a separate Bug field —
// tracked in #1100.
//
// Public so the compatibility shim Std.RegexSafe can reuse it (#1108).
pub func isTimeout(msg: in String): Bool {
  val needle = "time-out"
  val nLen = needle.length
  val mLen = msg.length
  if mLen < nLen { return false }
  var i = 0
  while i <= mLen - nLen {
    var j = 0
    var ok = true
    while ok and j < nLen {
      if msg[i + j] != needle[j] { ok = false }
      j = j + 1
    }
    if ok { return true }
    i = i + 1
  }
  false
}
