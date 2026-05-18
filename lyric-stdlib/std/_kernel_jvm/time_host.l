// std/_kernel_jvm/time_host.l - JVM host boundary for java.time.*.
//
// Mirrors _kernel/time_host.l for the JVM target.  The java.time
// package (JSR-310) maps cleanly onto Lyric's time model:
//
//   Instant        = java.time.Instant        (UTC point in time)
//   Duration       = java.time.Duration       (elapsed time)
//   DateTimeOffset = java.time.OffsetDateTime  (instant + UTC offset)
//   TimeZone       = java.time.ZoneId          (IANA timezone name)
//
// Shims are required wherever the JVM API diverges:
//
//   - Duration constructors: java.time.Duration.ofMillis(long) takes
//     long, not Double; shims convert (long)(n) with truncation.
//   - hostSince: java.time.Duration.between(start, end) takes the
//     earlier arg first, opposite of the .NET op_Subtraction ordering.
//   - hostPlus / arithmetic: instance methods on Instant / Duration.
//   - hostTotalMillis / hostTotalSeconds: return long, not Double.
//   - Calendar arithmetic (addMonths, addYears, addDays): requires
//     Instant → OffsetDateTime → manipulate → toInstant roundtrip.
//   - Epoch DTO construction: returns OffsetDateTime (UTC offset zero).
//   - Comparison: isBefore / isAfter are instance methods; Duration
//     comparisons need compareTo.
//
// Internal: only Std.Time should import this.

@axiom("java.time.* operations conform to their documented JVM / ISO 8601 contracts")
package Std.TimeHost

import Std.Core

// =====================================================================
// Wire-level type aliases.
// =====================================================================

extern type Instant        = "java.time.Instant"
extern type Duration       = "java.time.Duration"
extern type DateTimeOffset = "java.time.OffsetDateTime"
extern type TimeZone       = "java.time.ZoneId"

// =====================================================================
// Construction.
// =====================================================================

// java.time.Instant.now() — UTC clock, nanosecond resolution.
@externTarget("java.time.Instant.now")
pub func hostNow(): Instant = ()

// java.time.Duration.ZERO — static field.
@externTarget("java.time.Duration.ZERO")
pub func hostZeroDuration(): Duration = ()

// Java's Instant.parse throws DateTimeParseException on failure;
// shim wraps in try/catch and writes result via out parameter.
@externTarget("lyric.stdlib.jvm.TimeHost.tryParseInstant")
pub func hostTryParseInstant(s: in String, value: out Instant): Bool = ()

// =====================================================================
// Duration constructors.  All shims convert Double to long via (long).
// =====================================================================

@externTarget("lyric.stdlib.jvm.TimeHost.ofMillis")
pub func hostMillis(n: in Double): Duration = ()

@externTarget("lyric.stdlib.jvm.TimeHost.ofSeconds")
pub func hostSeconds(n: in Double): Duration = ()

@externTarget("lyric.stdlib.jvm.TimeHost.ofMinutes")
pub func hostMinutes(n: in Double): Duration = ()

@externTarget("lyric.stdlib.jvm.TimeHost.ofHours")
pub func hostHours(n: in Double): Duration = ()

@externTarget("lyric.stdlib.jvm.TimeHost.ofDays")
pub func hostDays(n: in Double): Duration = ()

// =====================================================================
// Duration arithmetic on Instant.
// =====================================================================

// Shim: Duration.between(earlier, later) — note argument order inversion
// vs .NET's op_Subtraction(later, earlier).
@externTarget("lyric.stdlib.jvm.TimeHost.since")
pub func hostSince(later: in Instant, earlier: in Instant): Duration = ()

// Shim: later.plus(d) — instance method on Instant.
@externTarget("lyric.stdlib.jvm.TimeHost.plus")
pub func hostPlus(t: in Instant, d: in Duration): Instant = ()

// =====================================================================
// Inspection.  Shims convert long return to Double.
// =====================================================================

@externTarget("lyric.stdlib.jvm.TimeHost.totalMillis")
pub func hostTotalMillis(d: in Duration): Double = ()

@externTarget("lyric.stdlib.jvm.TimeHost.totalSeconds")
pub func hostTotalSeconds(d: in Duration): Double = ()

// =====================================================================
// Calendar arithmetic.  All require Instant → OffsetDateTime(UTC)
// → plus/minus → toInstant roundtrip via shims.
// =====================================================================

@externTarget("lyric.stdlib.jvm.TimeHost.addMonths")
pub func hostAddMonths(t: in Instant, n: in Int): Instant = ()

@externTarget("lyric.stdlib.jvm.TimeHost.addYears")
pub func hostAddYears(t: in Instant, n: in Int): Instant = ()

@externTarget("lyric.stdlib.jvm.TimeHost.addDays")
pub func hostAddDays(t: in Instant, n: in Double): Instant = ()

// =====================================================================
// Epoch conversions.  Produce OffsetDateTime at UTC offset zero.
// =====================================================================

// Shim: OffsetDateTime.ofInstant(Instant.ofEpochMilli(n), ZoneOffset.UTC).
@externTarget("lyric.stdlib.jvm.TimeHost.dtoFromEpochMillis")
pub func hostDtoFromEpochMillis(n: in Long): DateTimeOffset = ()

// Shim: OffsetDateTime.ofInstant(Instant.ofEpochSecond(n), ZoneOffset.UTC).
@externTarget("lyric.stdlib.jvm.TimeHost.dtoFromEpochSeconds")
pub func hostDtoFromEpochSeconds(n: in Long): DateTimeOffset = ()

// Shim: offsetDateTime.toInstant().
@externTarget("lyric.stdlib.jvm.TimeHost.dtoToInstant")
pub func hostDtoUtcDateTime(d: in DateTimeOffset): Instant = ()

// =====================================================================
// IANA timezone lookup.
// =====================================================================

// java.time.ZoneId.of(id) — throws ZoneRulesException for unknown ids.
@externTarget("java.time.ZoneId.of")
pub func hostFindTimeZone(id: in String): TimeZone = ()

// =====================================================================
// Comparison.
// =====================================================================

// java.time.Instant.isBefore(other) — instance method.
@externTarget("java.time.Instant.isBefore")
pub func hostInstantBefore(a: in Instant, b: in Instant): Bool = ()

// java.time.Instant.isAfter(other) — instance method.
@externTarget("java.time.Instant.isAfter")
pub func hostInstantAfter(a: in Instant, b: in Instant): Bool = ()

// java.time.Instant.equals(other) — instance method.
@externTarget("java.time.Instant.equals")
pub func hostInstantEquals(a: in Instant, b: in Instant): Bool = ()

// Shim: a.compareTo(b) < 0.
@externTarget("lyric.stdlib.jvm.TimeHost.durationLess")
pub func hostDurationLess(a: in Duration, b: in Duration): Bool = ()

// Shim: a.compareTo(b) > 0.
@externTarget("lyric.stdlib.jvm.TimeHost.durationGreater")
pub func hostDurationGreater(a: in Duration, b: in Duration): Bool = ()

// java.time.Duration.plus(other) — instance method.
@externTarget("java.time.Duration.plus")
pub func hostAddDurations(a: in Duration, b: in Duration): Duration = ()

// java.time.Duration.minus(other) — instance method.
@externTarget("java.time.Duration.minus")
pub func hostSubDurations(a: in Duration, b: in Duration): Duration = ()

// =====================================================================
// ISO-8601 formatting.
// =====================================================================

// java.time.Instant.toString() returns ISO-8601 (e.g. "2021-01-01T00:00:00Z").
@externTarget("java.time.Instant.toString")
pub func hostInstantToString(value: in Instant): String = ()

// ─── Monotonic clock ──────────────────────────────────────────────────────────

// System.nanoTime() returns nanoseconds directly; model it as a
// 1 GHz stopwatch so Std.Time.monotonicNanos uses the same formula on both platforms.
@externTarget("java.lang.System.nanoTime")
pub func hostStopwatchTimestamp(): Long = ()

pub func hostStopwatchFrequency(): Long { 1000000000 }
