// std/_kernel/time_host.l - host boundary for System.DateTime / System.TimeSpan.
//
// Holds every `@externTarget` and `extern type` declaration that
// `Std.Time` formerly declared inline.  Kernel function names carry a
// `host` prefix so they don't collide with the user-facing names in
// `Std.Time` when the test inliner merges every stdlib file into one
// user package.
//
// The extern types (`Instant`, `Duration`, `DateTimeOffset`,
// `TimeZone`) keep their canonical names because they're the user-
// facing types — `Std.Time` re-exports them implicitly via the
// trampoline (the type aliases are visible package-wide once
// declared in this file and `Std.Time` imports it).
//
// Internal: only `Std.Time` should import this; per
// `compiler/lyric/std/_kernel/README.md` the kernel is the audited
// extern boundary, not a general-purpose API.

@axiom("System.DateTime / System.TimeSpan / System.DateTimeOffset / System.TimeZoneInfo conform to their documented .NET contracts")
package Std.TimeHost

import Std.Core

// =====================================================================
// Wire-level type aliases.
// =====================================================================

extern type Instant         = "System.DateTime"
extern type Duration        = "System.TimeSpan"
extern type DateTimeOffset  = "System.DateTimeOffset"
extern type TimeZone        = "System.TimeZoneInfo"

// =====================================================================
// Construction.
// =====================================================================

@externTarget("System.DateTime.UtcNow")
pub func hostNow(): Instant = ()

@externTarget("System.TimeSpan.Zero")
pub func hostZeroDuration(): Duration = ()

@externTarget("System.DateTime.TryParse")
pub func hostTryParseInstant(s: in String, value: out Instant): Bool = ()

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
// IANA / Windows timezone lookup.
// =====================================================================

@externTarget("System.TimeZoneInfo.FindSystemTimeZoneById")
pub func hostFindTimeZone(id: in String): TimeZone = ()

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
// =====================================================================

@externTarget("System.Convert.ToString")
pub func hostInstantToString(value: in Instant): String = ()
