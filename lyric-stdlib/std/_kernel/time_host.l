//! std/_kernel/time_host.l - host boundary for System.DateTime / System.TimeSpan.
//!
//! Holds every `@externTarget` and `extern type` declaration that
//! `Std.Time` formerly declared inline.  Kernel function names carry a
//! `host` prefix so they don't collide with the user-facing names in
//! `Std.Time` when the test inliner merges every stdlib file into one
//! user package.
//!
//! The extern types (`Instant`, `Duration`, `DateTimeOffset`) keep
//! their canonical names because they're the user-facing types —
//! `Std.Time` re-exports them implicitly via the trampoline (the type
//! aliases are visible package-wide once declared in this file and
//! `Std.Time` imports it).
//!
//! Internal: only `Std.Time` should import this; per
//! `compiler/lyric/std/_kernel/README.md` the kernel is the audited
//! extern boundary, not a general-purpose API.
@axiom("System.DateTime / System.TimeSpan / System.DateTimeOffset / System.Threading.Thread conform to their documented .NET contracts")
package Std.TimeHost

import Std.Core

// =====================================================================
// Wire-level type aliases.
// =====================================================================
extern type Instant = "System.DateTime"

extern type Duration = "System.TimeSpan"

extern type DateTimeOffset = "System.DateTimeOffset"

// =====================================================================
// Construction.
// =====================================================================
@externTarget("System.DateTime.get_UtcNow")
pub func hostNow(): Instant = ()

@externTarget("System.TimeSpan.Zero")
pub func hostZeroDuration(): Duration = ()

// The out-param bridge to DateTime.TryParse; package-private — only
// hostParseInstantOpt below calls it (the native backend cannot
// express out params, so the shared surface routes through the Option
// seam — D-N-027, same idiom as Std.UuidHost's hostParseCanonicalGuid).
@externTarget("System.DateTime.TryParse")
func hostTryParseInstant(s: in String, value: out Instant): Bool = ()

// Exception-free parse seam all three kernel twins implement
// (D-N-027).  This twin inherits DateTime.TryParse's lenient format
// set; the guaranteed cross-target contract is the toIsoString
// round-trip.
pub func hostParseInstantOpt(s: in String): Option[Instant] {
  var v: Instant = default()
  if hostTryParseInstant(s, v) {
    Some(value = hostToUniversalTime(v))
  } else {
    None
  }
}

// =====================================================================
// Duration constructors (in fractional units).
// =====================================================================
@externTarget("System.TimeSpan.FromMilliseconds")
pub func hostMillis(n: in Double): Duration = ()

@externTarget("System.TimeSpan.FromSeconds")
pub func hostSeconds(n: in Double): Duration = ()

@externTarget("System.TimeSpan.FromMinutes")
pub func hostMinutes(n: in Double): Duration = ()

@externTarget("System.TimeSpan.FromHours")
pub func hostHours(n: in Double): Duration = ()

@externTarget("System.TimeSpan.FromDays")
pub func hostDays(n: in Double): Duration = ()

// =====================================================================
// Duration arithmetic.
// =====================================================================
@externTarget("System.DateTime.op_Subtraction")
pub func hostSince(later: in Instant, earlier: in Instant): Duration = ()

@externTarget("System.DateTime.op_Addition")
pub func hostPlus(t: in Instant, d: in Duration): Instant = ()

// =====================================================================
// Inspection.
// =====================================================================
@externTarget("System.TimeSpan.TotalMilliseconds")
pub func hostTotalMillis(d: in Duration): Double = ()

@externTarget("System.TimeSpan.TotalSeconds")
pub func hostTotalSeconds(d: in Duration): Double = ()

// =====================================================================
// Calendar arithmetic.
// =====================================================================
@externTarget("System.DateTime.AddMonths")
pub func hostAddMonths(t: in Instant, n: in Int): Instant = ()

@externTarget("System.DateTime.AddYears")
pub func hostAddYears(t: in Instant, n: in Int): Instant = ()

@externTarget("System.DateTime.AddDays")
pub func hostAddDays(t: in Instant, n: in Double): Instant = ()

// =====================================================================
// Epoch conversions.
// =====================================================================
@externTarget("System.DateTimeOffset.FromUnixTimeMilliseconds")
pub func hostDtoFromEpochMillis(n: in Long): DateTimeOffset = ()

@externTarget("System.DateTimeOffset.FromUnixTimeSeconds")
pub func hostDtoFromEpochSeconds(n: in Long): DateTimeOffset = ()

@externTarget("System.DateTimeOffset.UtcDateTime")
pub func hostDtoUtcDateTime(d: in DateTimeOffset): Instant = ()

// =====================================================================
// Comparison.
// =====================================================================
@externTarget("System.DateTime.op_LessThan")
pub func hostInstantBefore(a: in Instant, b: in Instant): Bool = ()

@externTarget("System.DateTime.op_GreaterThan")
pub func hostInstantAfter(a: in Instant, b: in Instant): Bool = ()

@externTarget("System.DateTime.op_Equality")
pub func hostInstantEquals(a: in Instant, b: in Instant): Bool = ()

@externTarget("System.TimeSpan.op_LessThan")
pub func hostDurationLess(a: in Duration, b: in Duration): Bool = ()

@externTarget("System.TimeSpan.op_GreaterThan")
pub func hostDurationGreater(a: in Duration, b: in Duration): Bool = ()

@externTarget("System.TimeSpan.op_Addition")
pub func hostAddDurations(a: in Duration, b: in Duration): Duration = ()

@externTarget("System.TimeSpan.op_Subtraction")
pub func hostSubDurations(a: in Duration, b: in Duration): Duration = ()

// =====================================================================
// ISO-8601 formatting.
//
// The previous binding routed through `System.Convert.ToString`,
// which emits the CURRENT CULTURE's default DateTime format
// ("11/29/1973 21:33:09") — not ISO-8601, dropping sub-second
// precision and breaking the documented parse round-trip.  Fixed as
// part of D-N-027: format explicitly with the round-trippable "o"
// specifier.
// =====================================================================
@externTarget("System.DateTime.ToString")
func hostInstantToStringFmt(value: in Instant, fmt: in String): String = ()

pub func hostInstantToString(value: in Instant): String {
  hostInstantToStringFmt(value, "o")
}

// TryParse of a "Z"-suffixed string yields a LOCAL-kind DateTime with
// the clock time shifted to the host timezone; normalize back to UTC
// so the parse seam returns the same instant `toIsoString` printed
// regardless of the machine's timezone (D-N-027).
@externTarget("System.DateTime.ToUniversalTime")
func hostToUniversalTime(t: in Instant): Instant = ()

// ─── Monotonic clock ──────────────────────────────────────────────────────────
@externTarget("System.Diagnostics.Stopwatch.GetTimestamp")
pub func hostStopwatchTimestamp(): Long = ()

@externTarget("System.Diagnostics.Stopwatch.Frequency")
pub func hostStopwatchFrequency(): Long = ()

// Consumers: compute nanos in Std.Time.monotonicNanos using these two
// building blocks so the formula lives in non-axiom Lyric code.
// ─── Epoch millis — current time as Unix milliseconds ────────────────────────
@externTarget("System.DateTimeOffset.get_UtcNow")
pub func hostDtoUtcNow(): DateTimeOffset = ()

@externTarget("System.DateTimeOffset.ToUnixTimeMilliseconds")
pub func hostDtoToEpochMillis(d: in DateTimeOffset): Long = ()

// ─── Synchronous sleep — block the calling thread for `ms` milliseconds ───────
// Backs Std.Time.sleepMillis (used by `lyric run/build --watch`'s poll loop).
@externTarget("System.Threading.Thread.Sleep")
pub func hostSleepMillis(ms: in Int): Unit = ()

// =====================================================================
// Epoch/monotonic seams — the exception-free clock surface both kernel
// twins implement (issue #4752); the native twin backs these with
// lyric-rt's CLOCK_REALTIME / CLOCK_MONOTONIC helpers.
// =====================================================================
pub func hostEpochMillis(): Long {
  hostDtoToEpochMillis(hostDtoUtcNow())
}

pub func hostMonotonicNanos(): Long {
  val nanoTs: Long = hostStopwatchTimestamp()
  val nanoFreq: Long = hostStopwatchFrequency()
  // Two-step formula avoids Int64 overflow for any realistic timer
  // frequency.  `return` binds the leading-`(` line (a bare one would
  // parse as a call continuing the previous statement).
  return (nanoTs / nanoFreq) * 1000000000i64 + (nanoTs % nanoFreq) * 1000000000i64 / nanoFreq
}
