//! std/_kernel_jvm/regex_host.l — JVM kernel boundary for regex.
//!
//! Mirrors _kernel/regex_host.l for the JVM target: the same five-function
//! surface over java.util.regex.Pattern / Matcher, as pure Lyric over the
//! JVM auto-FFI.  The previous version routed isMatch / matchOne / replace /
//! compileWithTimeout through a phantom `lyric.stdlib.jvm.RegexHost` class
//! that never existed at runtime, which left those operations non-functional
//! on this target (docs/59 F-1c).
//!
//! **ReDoS timeout enforcement (#330 / #1103 / #7283):**
//! `java.util.regex.Pattern` has no timeout of its own (unlike the BCL
//! `Regex`, whose 3-arg constructor bakes a `matchTimeout` into the compiled
//! pattern). `Regex` here is therefore a small record pairing the compiled
//! `Pattern` with a timeout in milliseconds, and every match operation
//! (`hostIsMatch` / `hostMatchOne` / `hostReplace`) runs on the calling
//! thread over a `DeadlineChars` view of its input: a
//! `java.lang.CharSequence` whose `charAt` checks `System.nanoTime()` every
//! `clockCheckInterval` reads and panics once the deadline has passed. The
//! backtracking engine reads its input through `charAt`, so a runaway match
//! is stopped by its own reads, promptly, and nothing is left running.
//!
//! This replaces a design that started a virtual thread per operation and
//! raced it with `Thread.join(timeoutMs)`. That cost a thread start, two
//! atomics, a closure and a semaphore permit on every call, around 40 us per
//! match against under 1 us for this version. It could also only abandon a
//! timed-out match, which kept running on a shared carrier thread until it
//! finished on its own, so it needed a process-wide concurrency cap (#6576).
//! A stopped match needs neither.
//!
//! The panic message contains "time-out", which `Std.Regex.isTimeout` and
//! `Std.RegexSafe` use to classify the failure as `TimedOut`. Any other fault
//! the engine raises (for example an out-of-range `$n` in a replacement)
//! propagates unchanged.
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
extern type JPattern = "java.util.regex.Pattern"

extern type Match = "java.util.regex.Matcher"

extern type JCharSequence = "java.lang.CharSequence"

extern type JSystem = "java.lang.System"

// ─── Compilation ─────────────────────────────────────────────────────────────
// Default compile: routes to java.util.regex.Pattern.compile(String).
// Throws PatternSyntaxException (a Bug to Lyric callers) on invalid syntax.
@externTarget("java.util.regex.Pattern.compile")
func rawCompile(pattern: in String): JPattern = ()

/// A compiled pattern with its match timeout baked in (milliseconds) — the
/// JVM-side equivalent of the BCL 3-arg `Regex(pattern, options,
/// matchTimeout)` constructor's embedded deadline. Opaque to every consumer
/// (`Std.Regex` / `Std.RegexSafe` only ever pass this back through, never
/// inspect it), so this record shape is a JVM-only internal — the `.NET`
/// kernel keeps `Regex` as a bare `Pattern`-equivalent alias.
pub record Regex {
  pattern: JPattern
  timeoutMs: Long
}

// Matches _kernel/regex_host.l's default 1-second match timeout.
val defaultTimeoutMs: Long = 1000i64

/// Compile a regex pattern with the default 1-second match timeout.
pub func hostCompile(pattern: in String): Regex {
  Regex(pattern = rawCompile(pattern), timeoutMs = defaultTimeoutMs)
}

/// Compile with a custom timeout in seconds.  Enforced on every match
/// operation by the deadline-checked input (see module header).
pub func hostCompileWithTimeout(pattern: in String, seconds: in Double): Regex
  requires: seconds > 0.0
{
  Regex(pattern = rawCompile(pattern), timeoutMs = secondsToDeadlineMs(seconds))
}

// `seconds > 0.0` is enforced by `requires:` above, but a very small
// fractional-second value (e.g. 0.0005) truncates to 0 milliseconds via
// `.toLong()`, which would make every match time out at its first clock
// check. Clamp to a 1ms floor.
func secondsToDeadlineMs(seconds: in Double): Long {
  val ms = (seconds * 1000.0).toLong()
  if ms < 1i64 {
    1i64
  } else {
    ms
  }
}

// ─── Deadline-checked input ──────────────────────────────────────────────────
// Reads between clock checks: frequent enough that a runaway match stops
// within microseconds of its deadline, rare enough that `System.nanoTime()`
// is not a measurable share of an ordinary match.
val clockCheckInterval: Int = 1024

// The match input as a `CharSequence` that enforces `deadlineNanos` from its
// own `charAt` while `armed`. One instance per operation, confined to the
// calling thread, so the counters need no synchronisation. Disarmed once the
// operation returns, so a `Matcher` handed back by `hostMatchOne` can still be
// inspected afterwards.
record DeadlineChars {
  text: String
  op: String
  timeoutMs: Long
  deadlineNanos: Long
  var armed: Bool
  var reads: Int
}

impl JCharSequence for DeadlineChars {
  func length(): Int {
    self.text.length
  }

  func charAt(index: in Int): Char {
    self.reads = self.reads + 1
    if self.reads >= clockCheckInterval {
      self.reads = 0
      // Subtraction, not `>`, so the comparison survives `nanoTime` wrap.
      if self.armed and JSystem.nanoTime() - self.deadlineNanos > 0i64 {
        panic(timeoutMessage(self.op, self.timeoutMs))
      }
    }
    self.text[index]
  }

  // Group and replacement extraction copy out a plain `String`; the engine
  // never matches against a sub-sequence, so it needs no deadline of its own.
  func subSequence(from: in Int, until: in Int): JCharSequence {
    self.text.substring(from, until - from)
  }

  func toString(): String {
    self.text
  }
}

func armedInput(input: in String, op: in String, timeoutMs: in Long): DeadlineChars {
  DeadlineChars(
    text = input,
    op = op,
    timeoutMs = timeoutMs,
    deadlineNanos = JSystem.nanoTime() + timeoutMs * 1000000i64,
    armed = true,
    reads = 0
  )
}

// Deadline-exceeded message: MUST contain the literal substring "time-out"
// (see the module header).
func timeoutMessage(op: in String, timeoutMs: in Long): String {
  op + " exceeded its configured time-out of " + timeoutMs.toString() + "ms"
}

// ─── Match operations ────────────────────────────────────────────────────────
/// True when `input` contains at least one match: Pattern.matcher + find(),
/// bounded by `r`'s compiled-in timeout.
pub func hostIsMatch(r: in Regex, input: in String): Bool {
  matchFind(r.pattern, armedInput(input, "regex match", r.timeoutMs))
}

func matchFind(p: in JPattern, input: in DeadlineChars): Bool {
  val m = p.matcher(input)
  m.find()
}

/// First-match cursor: Pattern.matcher advanced by one find(), so
/// group()/start()/end() on the returned Matcher describe the first match
/// (mirroring .NET's Regex.Match, whose result is already positioned).
/// The find() is bounded by `r`'s compiled-in timeout; later operations on
/// the returned Matcher are not.
pub func hostMatchOne(r: in Regex, input: in String): Match {
  var chars = armedInput(input, "regex match-one", r.timeoutMs)
  val m = r.pattern.matcher(chars)
  advanceToFirstMatch(m)
  chars.armed = false
  m
}

// The find() result is deliberately consumed by the tail-position
// Bool-to-Unit coercion (the same pattern as process_host.l hostWait —
// a non-tail discarded auto-FFI call would be elided entirely, #5379);
// "no match found" is observable on the Matcher itself.
func advanceToFirstMatch(m: in Match): Unit {
  m.find()
}

/// Replace every match of `r` in `input`: Pattern.matcher + replaceAll,
/// bounded by `r`'s compiled-in timeout.
pub func hostReplace(r: in Regex, input: in String, replacement: in String): String {
  doReplace(r.pattern, armedInput(input, "regex replace", r.timeoutMs), replacement)
}

func doReplace(p: in JPattern, input: in DeadlineChars, replacement: in String): String {
  val m = p.matcher(input)
  m.replaceAll(replacement)
}

// ─── Match inspection ────────────────────────────────────────────────────────
//
// After hostMatchOne(r, input), the returned java.util.regex.Matcher is
// positioned on the first match (when one exists).  Group access
// (Matcher.group(int)) is a Phase 6 follow-up.
