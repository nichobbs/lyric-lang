// std/_kernel_jvm/regex.l - JVM host boundary for java.util.regex.
//
// Mirrors _kernel/regex.l for the JVM target.
//
// **KNOWN GAP — ReDoS vulnerability on JVM (#330):**
// Unlike `_kernel/regex.l` which compiles every pattern with a
// 1-second `matchTimeout` via the .NET `Regex(string, RegexOptions,
// TimeSpan)` overload, `java.util.regex.Pattern` has no native
// match timeout — adversarial patterns like `(a+)+$` against long
// input still hang the matching thread indefinitely.  A proper fix
// requires either (a) a host-side shim that runs `Matcher.find()`
// on a daemon thread and interrupts after a timeout, or (b) routing
// JVM regex through `com.google.re2j` (linear-time) instead of
// `java.util.regex`.  Until one of those lands, the JVM target
// remains exposed.  Tracked in #330.
//
// Pattern maps to java.util.regex.Pattern (compiled regex).
// Match maps to java.util.regex.Matcher (stateful match cursor).
//
// Three operations require shims:
//   isMatch  — Java needs pattern.matcher(input).find(); two calls.
//   matchOne — shim calls pattern.matcher(input), advances via find(),
//              and returns the Matcher so callers can read group()/
//              start()/end().  A Matcher where find() returned false
//              has success == false.
//   replace  — pattern.matcher(input).replaceAll(replacement) replaces
//              all non-overlapping occurrences, matching .NET semantics.
//
// compile routes directly to Pattern.compile since the signatures match.
//
// Bootstrap-grade surface: compile, isMatch, matchOne, replace.
// Named groups and match iteration are Phase 6 follow-ups.
package Std.Regex

import Std.Core

extern type Regex = "java.util.regex.Pattern"
extern type Match = "java.util.regex.Matcher"

// java.util.regex.Pattern.compile(String) — static factory method.
@externTarget("java.util.regex.Pattern.compile")
pub func compile(pattern: in String): Regex = ()

// Shim: pattern.matcher(input).find().
@externTarget("lyric.stdlib.jvm.RegexHost.isMatch")
pub func isMatch(r: in Regex, input: in String): Bool = ()

// Shim: calls pattern.matcher(input), advances with find(), returns
// the Matcher.  Callers check m.success (Matcher.find() result stored
// in the wrapper), m.value (Matcher.group()), m.index (Matcher.start()).
@externTarget("lyric.stdlib.jvm.RegexHost.matchOne")
pub func matchOne(r: in Regex, input: in String): Match = ()

// Shim: pattern.matcher(input).replaceAll(replacement).
@externTarget("lyric.stdlib.jvm.RegexHost.replace")
pub func replace(r: in Regex, input: in String, replacement: in String): String = ()

// =====================================================================
// Match inspection.
//
// After matchOne(r, input), inspect the Matcher via:
//   m.success  — whether find() returned true
//   m.value    — Matcher.group()   (full matched text)
//   m.index    — Matcher.start()   (byte offset of match start)
//   m.length   — Matcher.end() - Matcher.start()
//
// Group access (Matcher.group(int)) is a Phase 6 follow-up.
// =====================================================================
