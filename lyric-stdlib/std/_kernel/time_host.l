//! std/_kernel/time_host.l - host boundary for System.DateTime / System.TimeSpan.
//!
//! Holds every extern declaration that `Std.Time` formerly declared
//! inline.  Kernel function names carry a `host` prefix so they don't
//! collide with the user-facing names in `Std.Time` when the test
//! inliner merges every stdlib file into one user package.
//!
//! The extern types (`Instant`, `Duration`, `DateTimeOffset`) keep
//! their canonical names because they're the user-facing types —
//! `Std.Time` re-exports them implicitly via the trampoline (the type
//! aliases are visible package-wide once declared in this file and
//! `Std.Time` imports it).
//!
//! All members — static factories, operators, fields, properties,
//! and value-type instance members — are auto-FFI calls on the
//! extern-type aliases; only the out-param `DateTime.TryParse`
//! bridge keeps its `@externTarget` wrapper (out params have no
//! auto-FFI call-site surface).
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

extern type NetStopwatch = "System.Diagnostics.Stopwatch"

extern type NetThread = "System.Threading.Thread"

// =====================================================================
// Construction.
// =====================================================================
pub func hostNow(): Instant {
  Instant.UtcNow
}

pub func hostZeroDuration(): Duration {
  Duration.Zero
}

// The out-param bridge to DateTime.TryParse; package-private — only
// hostParseInstantOpt below calls it (the native backend cannot
// express out params, so the shared surface routes through the Option
// seam — D-N-027, same idiom as Std.UuidHost's hostParseCanonicalGuid).
// stays @externTarget: out params have no auto-FFI call-site surface.
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
pub func hostMillis(n: in Double): Duration {
  Duration.FromMilliseconds(n)
}

pub func hostSeconds(n: in Double): Duration {
  Duration.FromSeconds(n)
}

pub func hostMinutes(n: in Double): Duration {
  Duration.FromMinutes(n)
}

pub func hostHours(n: in Double): Duration {
  Duration.FromHours(n)
}

pub func hostDays(n: in Double): Duration {
  Duration.FromDays(n)
}

// =====================================================================
// Duration arithmetic.  DateTime/TimeSpan operators are static
// op_* methods, spelled as explicit static calls on the aliases.
// =====================================================================
pub func hostSince(later: in Instant, earlier: in Instant): Duration {
  Instant.op_Subtraction(later, earlier)
}

pub func hostPlus(t: in Instant, d: in Duration): Instant {
  Instant.op_Addition(t, d)
}

// =====================================================================
// Inspection — instance properties of the TimeSpan value type,
// dispatched through the receiver's address (ldloca + call).
// =====================================================================
pub func hostTotalMillis(d: in Duration): Double {
  d.TotalMilliseconds
}

pub func hostTotalSeconds(d: in Duration): Double {
  d.TotalSeconds
}

// =====================================================================
// Calendar arithmetic — instance methods on the DateTime value type.
// =====================================================================
pub func hostAddMonths(t: in Instant, n: in Int): Instant {
  t.AddMonths(n)
}

pub func hostAddYears(t: in Instant, n: in Int): Instant {
  t.AddYears(n)
}

pub func hostAddDays(t: in Instant, n: in Double): Instant {
  t.AddDays(n)
}

// =====================================================================
// Epoch conversions.
// =====================================================================
pub func hostDtoFromEpochMillis(n: in Long): DateTimeOffset {
  DateTimeOffset.FromUnixTimeMilliseconds(n)
}

pub func hostDtoFromEpochSeconds(n: in Long): DateTimeOffset {
  DateTimeOffset.FromUnixTimeSeconds(n)
}

pub func hostDtoUtcDateTime(d: in DateTimeOffset): Instant {
  d.UtcDateTime
}

// =====================================================================
// Comparison.
// =====================================================================
pub func hostInstantBefore(a: in Instant, b: in Instant): Bool {
  Instant.op_LessThan(a, b)
}

pub func hostInstantAfter(a: in Instant, b: in Instant): Bool {
  Instant.op_GreaterThan(a, b)
}

pub func hostInstantEquals(a: in Instant, b: in Instant): Bool {
  Instant.op_Equality(a, b)
}

pub func hostDurationLess(a: in Duration, b: in Duration): Bool {
  Duration.op_LessThan(a, b)
}

pub func hostDurationGreater(a: in Duration, b: in Duration): Bool {
  Duration.op_GreaterThan(a, b)
}

pub func hostAddDurations(a: in Duration, b: in Duration): Duration {
  Duration.op_Addition(a, b)
}

pub func hostSubDurations(a: in Duration, b: in Duration): Duration {
  Duration.op_Subtraction(a, b)
}

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
func hostInstantToStringFmt(value: in Instant, fmt: in String): String {
  value.ToString(fmt)
}

pub func hostInstantToString(value: in Instant): String {
  hostInstantToStringFmt(value, "o")
}

// TryParse of a "Z"-suffixed string yields a LOCAL-kind DateTime with
// the clock time shifted to the host timezone; normalize back to UTC
// so the parse seam returns the same instant `toIsoString` printed
// regardless of the machine's timezone (D-N-027).
func hostToUniversalTime(t: in Instant): Instant {
  t.ToUniversalTime()
}

// ─── Monotonic clock ──────────────────────────────────────────────────────────
pub func hostStopwatchTimestamp(): Long {
  NetStopwatch.GetTimestamp()
}

pub func hostStopwatchFrequency(): Long {
  NetStopwatch.Frequency
}

// Consumers: compute nanos in Std.Time.monotonicNanos using these two
// building blocks so the formula lives in non-axiom Lyric code.
// ─── Epoch millis — current time as Unix milliseconds ────────────────────────
pub func hostDtoUtcNow(): DateTimeOffset {
  DateTimeOffset.UtcNow
}

pub func hostDtoToEpochMillis(d: in DateTimeOffset): Long {
  d.ToUnixTimeMilliseconds()
}

// ─── Synchronous sleep — block the calling thread for `ms` milliseconds ───────
// Backs Std.Time.sleepMillis (used by `lyric run/build --watch`'s poll loop).
pub func hostSleepMillis(ms: in Int): Unit {
  NetThread.Sleep(ms)
}

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
