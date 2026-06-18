// Std.RegexSafe — backward-compatible Result wrappers around Std.RegexHost.
//
// New code should prefer `Std.Regex` (std/regex.l) which provides the same
// Result-shaped API with a cleaner `CompiledRegex` opaque type and a pure-
// Lyric `Match` record.  This module is retained for compatibility with
// existing callers that use `Std.RegexSafe.tryCompile` / `tryIsMatch` etc.
// with the raw `Std.RegexHost.Regex` handle.
//
// Tracks lyric-lang #330.

@runtime_checked
package Std.RegexSafe

import Std.Core
import Std.Regex as Rx
import Std.RegexHost as RxKernel

// ─── Error type ──────────────────────────────────────────────────────────────

/// Errors surfaced by the safe regex wrapper.
@stable(since="0.1")
pub union RegexError {
  /// `RegexMatchTimeoutException` from the BCL — the pattern took
  /// longer than the compiled timeout (default 1s) to match.  The
  /// usual root cause is catastrophic backtracking on adversarial
  /// input.  `pattern` carries the regex source text (when known),
  /// `message` the BCL exception's `Message`.
  case TimedOut(message: String)
  /// Any other exception thrown by the BCL — invalid pattern syntax,
  /// `ArgumentNullException`, etc.
  case RegexBug(message: String)
}

@stable(since="0.1")
pub func errorMessage(e: in RegexError): String {
  match e {
    case TimedOut(m) -> "regex match timed out: " + m
    case RegexBug(m) -> "regex error: " + m
  }
}

// ─── Safe wrappers ───────────────────────────────────────────────────────────

/// Compile a pattern with the default 1-second match timeout.
/// Returns `Err(RegexBug)` when the pattern itself is invalid.
// `tryCompile`, `tryIsMatch`, `tryMatchOne`, `tryReplace` are
// prefixed to distinguish them from the `host*`-prefixed kernel functions.
@stable(since="0.1")
pub func tryCompile(pattern: in String): Result[RxKernel.Regex, RegexError] {
  return try {
    Ok(value = RxKernel.hostCompile(pattern))
  } catch Bug as b {
    Err(error = RegexBug(message = b.message))
  }
}

/// Test whether `input` matches `r`.  Returns `Err(TimedOut)` when
/// the match exceeds the compiled timeout.
@stable(since="0.1")
pub func tryIsMatch(r: in RxKernel.Regex, input: in String): Result[Bool, RegexError] {
  return try {
    Ok(value = RxKernel.hostIsMatch(r, input))
  } catch Bug as b {
    classify(b.message)
  }
}

/// Single-match: returns the first match (success-flag on the
/// returned `Match` distinguishes "no match" from "match at offset").
/// `Err(TimedOut)` on regex-engine overrun.
@stable(since="0.1")
pub func tryMatchOne(r: in RxKernel.Regex, input: in String): Result[RxKernel.Match, RegexError] {
  return try {
    Ok(value = RxKernel.hostMatchOne(r, input))
  } catch Bug as b {
    classifyMatch(b.message)
  }
}

/// Replace every match of `r` in `input` with `replacement`.
/// `Err(TimedOut)` on regex-engine overrun.
@stable(since="0.1")
pub func tryReplace(
  r:           in RxKernel.Regex,
  input:       in String,
  replacement: in String
): Result[String, RegexError] {
  return try {
    Ok(value = RxKernel.hostReplace(r, input, replacement))
  } catch Bug as b {
    classifyReplace(b.message)
  }
}

// ─── Private helpers ─────────────────────────────────────────────────────────

func classify(msg: in String): Result[Bool, RegexError] {
  if Rx.isTimeout(msg) { Err(error = TimedOut(message = msg)) }
  else                 { Err(error = RegexBug(message = msg)) }
}

func classifyMatch(msg: in String): Result[RxKernel.Match, RegexError] {
  if Rx.isTimeout(msg) { Err(error = TimedOut(message = msg)) }
  else                 { Err(error = RegexBug(message = msg)) }
}

func classifyReplace(msg: in String): Result[String, RegexError] {
  if Rx.isTimeout(msg) { Err(error = TimedOut(message = msg)) }
  else                 { Err(error = RegexBug(message = msg)) }
}
