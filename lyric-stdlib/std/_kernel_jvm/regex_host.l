// std/_kernel_jvm/regex_host.l — JVM kernel boundary for regex.
//
// Mirrors _kernel/regex_host.l for the JVM target.  All operations that
// require two Java API calls (Pattern.matcher(input) + find/replaceAll)
// route through lyric.stdlib.jvm.RegexHost shims, which already exist in
// the stdlib shim JAR and are used by Std.RegexSafe on the JVM path.
//
// java.util.regex.Pattern has no native match timeout.
//
// **KNOWN GAP — ReDoS vulnerability on JVM (#330 / #1103):**
// Unlike the .NET kernel which compiles every pattern with a
// 1-second matchTimeout via the 3-arg Regex ctor, Pattern has
// no timeout mechanism.  Adversarial patterns like `(a+)+$` against
// long input can hang the matching thread indefinitely on JVM.
//
// The intended fix (#1103) is the standard "interruptible
// CharSequence" pattern:
//
//   1. The shim wraps the input String in an
//      `InterruptibleCharSequence` whose `charAt(int)` throws
//      `RuntimeException` (NOT `InterruptedException`, which
//      `CharSequence.charAt` cannot declare) when
//      `Thread.interrupted()` is true.
//   2. Before calling `matcher.find()` / `matcher.matches()`, the
//      shim records the calling thread and schedules a daemon
//      `ScheduledExecutorService` task to call `thread.interrupt()`
//      after the configured deadline.
//   3. If the match completes in time the scheduled task is
//      cancelled.  If the deadline fires, the thrown
//      RuntimeException unwinds the matcher and the shim catches
//      it, clears the thread's interrupt flag, and rethrows a
//      sentinel exception that the kernel maps to
//      `Err(TimedOut(message))`.
//
// That work is the responsibility of the external `lyric-stdlib-shim`
// JAR project (it owns every `lyric.stdlib.jvm.*` class).  Until the
// shim ships:
//   - hostCompile returns a raw java.util.regex.Pattern with no timeout.
//   - hostCompileWithTimeout accepts a seconds parameter but ignores it;
//     the lyric.stdlib.jvm.RegexHost.compileWithTimeout shim stub calls
//     Pattern.compile(pattern) and discards seconds.  The stub must be
//     added to the stdlib shim JAR alongside isMatch / matchOne / replace.
//   - The isTimeout classifier in Std.Regex / Std.RegexSafe will never
//     trigger on JVM until the daemon-thread shim is in place.
//
// The Lyric-side `requires:` clause on `hostCompileWithTimeout` (`seconds > 0.0`)
// preserves the .NET contract so callers that pass a sensible timeout
// don't silently get a no-op on JVM later — the precondition fires
// at the kernel boundary regardless of target.
//
// Functions are prefixed `host*` following the Std.HttpHost convention
// to prevent name-shadowing recursion when Std.Regex (std/regex.l)
// calls RxHost.hostCompile(...) etc.
//
// The public Lyric API lives in std/regex.l (Std.Regex).  Import
// Std.RegexHost only in stdlib internals that need the raw JVM types.

@axiom("lyric.stdlib.jvm.RegexHost operations conform to their documented JVM / java.util.regex contracts")
package Std.RegexHost

import Std.Core

// java.util.regex.Pattern — compiled regex (existing JDK type).
// java.util.regex.Matcher — stateful match cursor (existing JDK type).
extern type Regex = "java.util.regex.Pattern"
extern type Match = "java.util.regex.Matcher"

// ─── Compilation ─────────────────────────────────────────────────────────────

// Default compile: routes to java.util.regex.Pattern.compile(String).
// No timeout protection — see KNOWN GAP above.
@externTarget("java.util.regex.Pattern.compile")
pub func hostCompile(pattern: in String): Regex = ()

// Custom-timeout compile: timeout parameter is accepted but IGNORED on JVM
// until the daemon-thread shim (#1103) lands.  Routes to a RegexHost stub
// that calls Pattern.compile(pattern) and discards seconds.  The stub must
// be added to the stdlib shim JAR; see #1103.
@externTarget("lyric.stdlib.jvm.RegexHost.compileWithTimeout")
pub func hostCompileWithTimeout(pattern: in String, seconds: in Double): Regex
  requires: seconds > 0.0
  = ()

// ─── Match operations ────────────────────────────────────────────────────────
//
// Shims exist in the stdlib shim JAR:
//   isMatch  — Pattern.matcher(input).find()
//   matchOne — Pattern.matcher(input); advances with find(); returns Matcher
//   replace  — Pattern.matcher(input).replaceAll(replacement)

@externTarget("lyric.stdlib.jvm.RegexHost.isMatch")
pub func hostIsMatch(r: in Regex, input: in String): Bool = ()

@externTarget("lyric.stdlib.jvm.RegexHost.matchOne")
pub func hostMatchOne(r: in Regex, input: in String): Match = ()

@externTarget("lyric.stdlib.jvm.RegexHost.replace")
pub func hostReplace(r: in Regex, input: in String, replacement: in String): String = ()

// ─── Match inspection ────────────────────────────────────────────────────────
//
// After hostMatchOne(r, input), inspect the Matcher via:
//   m.success  — whether find() returned true
//   m.value    — Matcher.group()   (full matched text)
//   m.index    — Matcher.start()   (byte offset of match start)
//   m.length   — Matcher.end() - Matcher.start()
//
// Group access (Matcher.group(int)) is a Phase 6 follow-up.
