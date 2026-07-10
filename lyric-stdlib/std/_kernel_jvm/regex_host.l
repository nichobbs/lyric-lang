//! std/_kernel_jvm/regex_host.l — JVM kernel boundary for regex.
//!
//! Mirrors _kernel/regex_host.l for the JVM target: the same five-function
//! surface over java.util.regex.Pattern / Matcher, as pure Lyric over the
//! JVM auto-FFI.  The previous version routed isMatch / matchOne / replace /
//! compileWithTimeout through a phantom `lyric.stdlib.jvm.RegexHost` class
//! that never existed at runtime, which left those operations non-functional
//! on this target (docs/59 F-1c).
//!
//! **KNOWN GAP — ReDoS vulnerability on JVM (#330 / #1103):**
//! Unlike the .NET kernel, which compiles every pattern with a 1-second
//! matchTimeout via the 3-arg Regex ctor, java.util.regex.Pattern has no
//! match-timeout mechanism.  Adversarial patterns like `(a+)+$` against
//! long input can occupy the matching thread indefinitely on JVM.  The
//! intended fix (#1103) is the standard interruptible-CharSequence pattern
//! (a wrapper whose charAt observes a daemon-scheduled deadline interrupt).
//! Until #1103 lands:
//!   - hostCompile compiles with no timeout;
//!   - hostCompileWithTimeout ACCEPTS the seconds parameter but does not
//!     enforce it (the signature and its `requires:` are kept so .NET-and-
//!     JVM-portable callers keep one contract, and so a sensible timeout
//!     passed today starts working the moment #1103 lands);
//!   - the isTimeout classifier in Std.Regex / Std.RegexSafe never fires
//!     on JVM.
//!
//! Replacement-string semantics: Matcher.replaceAll treats `$n` group
//! references the same way .NET substitutions do; Java additionally
//! treats backslash as an escape in the replacement.
//!
//! Functions are prefixed `host*` following the Std.HttpHost convention
//! to prevent name-shadowing recursion when Std.Regex (std/regex.l)
//! calls RxHost.hostCompile(...) etc.
//!
//! The public Lyric API lives in std/regex.l (Std.Regex).  Import
//! Std.RegexHost only in stdlib internals that need the raw JVM types.
@axiom("java.util.regex.Pattern and java.util.regex.Matcher conform to their documented JVM contracts")
package Std.RegexHost

import Std.Core

// java.util.regex.Pattern — compiled regex (existing JDK type).
// java.util.regex.Matcher — stateful match cursor (existing JDK type).
extern type Regex = "java.util.regex.Pattern"

extern type Match = "java.util.regex.Matcher"

// ─── Compilation ─────────────────────────────────────────────────────────────
// Default compile: routes to java.util.regex.Pattern.compile(String).
// Throws PatternSyntaxException (a Bug to Lyric callers) on invalid syntax.
// No timeout protection — see KNOWN GAP above.
@externTarget("java.util.regex.Pattern.compile")
pub func hostCompile(pattern: in String): Regex = ()

/// Compile with a custom timeout in seconds.  The timeout is accepted but
/// NOT ENFORCED on JVM pending #1103 (Pattern has no timeout mechanism);
/// the `requires:` preserves the cross-target contract at the boundary.
pub func hostCompileWithTimeout(pattern: in String, seconds: in Double): Regex
  requires: seconds > 0.0
{
  hostCompile(pattern)
}

// ─── Match operations ────────────────────────────────────────────────────────
/// True when `input` contains at least one match: Pattern.matcher + find().
pub func hostIsMatch(r: in Regex, input: in String): Bool {
  val m = r.matcher(input)
  m.find()
}

/// First-match cursor: Pattern.matcher advanced by one find(), so
/// group()/start()/end() on the returned Matcher describe the first match
/// (mirroring .NET's Regex.Match, whose result is already positioned).
pub func hostMatchOne(r: in Regex, input: in String): Match {
  val m = r.matcher(input)
  advanceToFirstMatch(m)
  m
}

// The find() result is deliberately consumed by the tail-position
// Bool-to-Unit coercion (the same pattern as process_host.l hostWait —
// a non-tail discarded auto-FFI call would be elided entirely, #5379);
// "no match found" is observable on the Matcher itself.
func advanceToFirstMatch(m: in Match): Unit {
  m.find()
}

/// Replace every match of `r` in `input`: Pattern.matcher + replaceAll.
pub func hostReplace(r: in Regex, input: in String, replacement: in String): String {
  val m = r.matcher(input)
  m.replaceAll(replacement)
}

// ─── Match inspection ────────────────────────────────────────────────────────
//
// After hostMatchOne(r, input), the returned java.util.regex.Matcher is
// positioned on the first match (when one exists).  Group access
// (Matcher.group(int)) is a Phase 6 follow-up.
