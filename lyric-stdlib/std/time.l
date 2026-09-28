//! std/time.l - Time and date primitives.
//!
//! User-facing wrappers over `Std.TimeHost`, whose kernel twins own
//! the trusted time boundary per target: `System.DateTime` /
//! `System.TimeSpan` / `System.DateTimeOffset` on .NET (`_kernel/`),
//! `java.time.*` on the JVM (`_kernel_jvm/`), and nanosecond-count
//! records over lyric-rt's CLOCK_REALTIME on native
//! (`_kernel_native/`, D-N-027).  See `docs/14-native-stdlib-plan.md`
//! §6 P0/4.
//!
//! All times are UTC unless stated otherwise.  The wrappers
//! deliberately avoid local-time conversion to keep behaviour
//! reproducible across machines.
@runtime_checked
package Std.Time

import Std.Core
import Std.TimeHost

// brings `Instant`, `Duration`, … and `host*` fns into scope
// =====================================================================
// Construction.
// =====================================================================
/// Current UTC time.
@stable(since = "1.0")
pub func now(): Instant {
  hostNow()
}

/// `TimeSpan.Zero` — useful as a fold initial value.
@stable(since = "1.0")
pub func zeroDuration(): Duration {
  hostZeroDuration()
}

/// Parse a timestamp; returns `None` if the host refuses.  The
/// guaranteed cross-target contract is the `toIsoString` round-trip
/// (ISO-8601 UTC instants); each host may additionally accept its
/// platform's wider set (.NET `DateTime.TryParse` is lenient, JVM
/// `Instant.parse` and the native parser are strict ISO).  Routed
/// through the exception-free Option seam every kernel twin
/// implements (D-N-027; the former Bool+out shape cannot be
/// expressed on native).
@stable(since = "1.0")
pub func parseOptInstant(s: in String): Option[Instant] {
  hostParseInstantOpt(s)
}

// =====================================================================
// Duration constructors (in fractional milliseconds, seconds, etc.).
//
// Bounds match the tightest of the three kernel twins' representable
// range: native stores a `Duration` as a signed 64-bit nanosecond count
// (~292 years), tighter than .NET's `TimeSpan` (100 ns ticks) or the
// JVM's `java.time.Duration` (seconds + nanos).  The JVM host would
// otherwise map `NaN` to a zero duration and saturate huge magnitudes
// instead of throwing like .NET and native (#7252), so `n == n` (the
// self-inequality idiom for "not NaN") is required here too.
// =====================================================================
@pure
@stable(since = "1.0")
pub func millis(n: in Double): Duration
  requires: n == n and n >= -9223372036854.775807 and n <= 9223372036854.775807
{
  hostMillis(n)
}

@pure
@stable(since = "1.0")
pub func seconds(n: in Double): Duration
  requires: n == n and n >= -9223372036.854775807 and n <= 9223372036.854775807
{
  hostSeconds(n)
}

@pure
@stable(since = "1.0")
pub func minutes(n: in Double): Duration
  requires: n == n and n >= -153722867.28091294 and n <= 153722867.28091294
{
  hostMinutes(n)
}

@pure
@stable(since = "1.0")
pub func hours(n: in Double): Duration
  requires: n == n and n >= -2562047.7880152157 and n <= 2562047.7880152157
{
  hostHours(n)
}

@pure
@stable(since = "1.0")
pub func days(n: in Double): Duration
  requires: n == n and n >= -106751.99116730064 and n <= 106751.99116730064
{
  hostDays(n)
}

// =====================================================================
// Duration arithmetic.
//
// `op_Subtraction` between two `DateTime`s yields a `TimeSpan`.
// Lyric users see `since(later, earlier)` to avoid op-name surprise.
// =====================================================================
@stable(since = "1.0")
pub func since(later: in Instant, earlier: in Instant): Duration {
  hostSince(later, earlier)
}

@stable(since = "1.0")
pub func plus(t: in Instant, d: in Duration): Instant {
  hostPlus(t, d)
}

// =====================================================================
// Inspection.
// =====================================================================
@stable(since = "1.0")
pub func totalMillis(d: in Duration): Double {
  hostTotalMillis(d)
}

@stable(since = "1.0")
pub func totalSeconds(d: in Duration): Double {
  hostTotalSeconds(d)
}

// =====================================================================
// Calendar arithmetic.
//
// `addMonths` / `addYears` use BCL `DateTime.AddMonths` / `AddYears`
// semantics, which preserve day-of-month where possible
// (e.g. Jan 31 + 1 month → Feb 28 / 29) — that's a safer default
// than naive 30-day-per-month addition.  Returns the new `Instant`.
// =====================================================================
// `months`/`years` bounds match .NET's `DateTime.AddMonths`/`AddYears`,
// which throw `ArgumentOutOfRangeException` outside these ranges before
// even attempting the calendar arithmetic.
@stable(since = "1.0")
pub func addMonths(t: in Instant, n: in Int): Instant
  requires: n >= -120000 and n <= 120000
{
  hostAddMonths(t, n)
}

@stable(since = "1.0")
pub func addYears(t: in Instant, n: in Int): Instant
  requires: n >= -10000 and n <= 10000
{
  hostAddYears(t, n)
}

@stable(since = "1.0")
pub func addDays(t: in Instant, n: in Double): Instant {
  hostAddDays(t, n)
}

// =====================================================================
// Epoch conversions (Unix milliseconds <-> DateTime).
//
// Routes through `DateTimeOffset.FromUnixTimeMilliseconds` and
// `DateTimeOffset.UtcDateTime`, then back via `ToUnixTimeMilliseconds`.
// Matching extern aliases live alongside `Instant` so the user sees
// the conversion as a one-call operation.
// =====================================================================
func dtoFromEpochMillis(n: in Long): DateTimeOffset {
  hostDtoFromEpochMillis(n)
}

func dtoFromEpochSeconds(n: in Long): DateTimeOffset {
  hostDtoFromEpochSeconds(n)
}

func dtoUtcDateTime(d: in DateTimeOffset): Instant {
  hostDtoUtcDateTime(d)
}

// The common range every target's `Instant` representation can hold: the
// tightest bound is native's signed 64-bit nanosecond count (~292 years
// either side of the epoch, #5216) — far narrower than .NET's DateTime
// (years 1..9999) or java.time.Instant's (~±1e9 years).  `fromEpochMillis`/
// `fromEpochSeconds` panic outside it (matching .NET/native's own
// out-of-range behaviour); `tryFromEpochMillis`/`tryFromEpochSeconds` give
// the exception-free Option form.
/// Construct an `Instant` from a Unix epoch-millis value.  Lyric-side
/// composes the two BCL calls so callers see a single helper.
@stable(since = "1.0")
pub func fromEpochMillis(n: in Long): Instant
  requires: n >= -9223372036854i64 and n <= 9223372036854i64
{
  dtoUtcDateTime(dtoFromEpochMillis(n))
}

/// Construct an `Instant` from a Unix epoch-seconds value.
@stable(since = "1.0")
pub func fromEpochSeconds(n: in Long): Instant
  requires: n >= -9223372036i64 and n <= 9223372036i64
{
  dtoUtcDateTime(dtoFromEpochSeconds(n))
}

/// `fromEpochMillis`, but `None` instead of a panic when `n` is outside
/// the common representable range (~292 years either side of the epoch).
@experimental
pub func tryFromEpochMillis(n: in Long): Option[Instant] {
  if n < -9223372036854i64 or n > 9223372036854i64 {
    None
  } else {
    Some(value = fromEpochMillis(n))
  }
}

/// `fromEpochSeconds`, but `None` instead of a panic when `n` is outside
/// the common representable range (~292 years either side of the epoch).
@experimental
pub func tryFromEpochSeconds(n: in Long): Option[Instant] {
  if n < -9223372036i64 or n > 9223372036i64 {
    None
  } else {
    Some(value = fromEpochSeconds(n))
  }
}

// =====================================================================
// Comparison.
//
// `DateTime.op_LessThan` / `op_GreaterThan` resolve via auto-FFI
// when the user writes `a < b` on `Instant` values, but the named
// helpers below are clearer in code and match `Duration` shape
// where operators don't always lower cleanly.
// =====================================================================
@stable(since = "1.0")
pub func instantBefore(a: in Instant, b: in Instant): Bool {
  hostInstantBefore(a, b)
}

@stable(since = "1.0")
pub func instantAfter(a: in Instant, b: in Instant): Bool {
  hostInstantAfter(a, b)
}

@stable(since = "1.0")
pub func instantEquals(a: in Instant, b: in Instant): Bool {
  hostInstantEquals(a, b)
}

@stable(since = "1.0")
pub func durationLess(a: in Duration, b: in Duration): Bool {
  hostDurationLess(a, b)
}

@stable(since = "1.0")
pub func durationGreater(a: in Duration, b: in Duration): Bool {
  hostDurationGreater(a, b)
}

@stable(since = "1.0")
pub func addDurations(a: in Duration, b: in Duration): Duration {
  hostAddDurations(a, b)
}

@stable(since = "1.0")
pub func subDurations(a: in Duration, b: in Duration): Duration {
  hostSubDurations(a, b)
}

// =====================================================================
// ISO-8601 formatting.
//
// `DateTime.ToString("o")` produces a round-trippable ISO-8601-with-
// fractional-seconds string ("2024-12-31T23:59:59.9999999Z" for UTC
// Instants).  The "o" format specifier guarantees the inverse round
// trip via `parseOptInstant`.
// =====================================================================
/// Format an `Instant` as an ISO-8601 round-trippable string.
@stable(since = "1.0")
pub func toIsoString(t: in Instant): String {
  hostInstantToString(t)
}

// =====================================================================
// Monotonic clock.
// =====================================================================
/// Current UTC time as Unix milliseconds since the epoch.
@stable(since = "1.0")
pub func nowEpochMillis(): Long {
  hostEpochMillis()
}

/// Nanoseconds from an unspecified epoch using the platform's monotonic
/// high-resolution clock.  The clock never goes backwards, even during
/// NTP adjustments.  Use differences between two calls to measure
/// elapsed time; do not compare values across processes.
///
/// .NET: backed by System.Diagnostics.Stopwatch (GetTimestamp/Frequency).
/// JVM:  backed by java.lang.System.nanoTime.
/// Native: backed by CLOCK_MONOTONIC via lyric-rt.
@stable(since = "1.0")
pub func monotonicNanos(): Long {
  hostMonotonicNanos()
}

/// Block the calling thread for `ms` milliseconds.  A non-positive `ms` returns
/// immediately.  Synchronous (unlike `Std.Task.delay`, which is awaitable);
/// intended for simple poll loops such as `lyric run/build --watch`.
///
/// Implemented on `dotnet` (`Thread.Sleep`), `jvm` (`Thread.sleep`), and
/// native (`lyric_rt`) — works on every target.
pub func sleepMillis(ms: in Int): Unit {
  if ms <= 0 {
    return
  }
  hostSleepMillis(ms)
}
