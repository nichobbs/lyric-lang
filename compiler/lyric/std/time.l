// std/time.l - Time and date primitives.
//
// Two `extern type` aliases over `System.DateTime` and
// `System.TimeSpan`; the rest of the surface is `@externTarget`
// helpers around the canonical BCL operations (UTC now, parsing,
// arithmetic).
//
// All times are UTC unless stated otherwise.  The wrapper
// deliberately avoids local-time conversion to keep behaviour
// reproducible across machines.
package Std.Time

import Std.Core

extern type Instant  = "System.DateTime"
extern type Duration = "System.TimeSpan"

// =====================================================================
// Construction.
// =====================================================================

/// Current UTC time.
@externTarget("System.DateTime.UtcNow")
pub func now(): Instant = ()

/// `TimeSpan.Zero` — useful as a fold initial value.
@externTarget("System.TimeSpan.Zero")
pub func zeroDuration(): Duration = ()

/// Parse an ISO-8601-ish timestamp; returns `None` if the BCL refuses.
@externTarget("System.DateTime.TryParse")
pub func hostTryParseInstant(s: in String, value: out Instant): Bool = ()

pub func parseOptInstant(s: in String): Option[Instant] {
  var v: Instant = default()
  if hostTryParseInstant(s, v) { Some(value = v) } else { None }
}

// =====================================================================
// Duration constructors (in fractional milliseconds, seconds, etc.).
// =====================================================================

@externTarget("System.TimeSpan.FromMilliseconds")
pub func millis(n: in Double): Duration = ()

@externTarget("System.TimeSpan.FromSeconds")
pub func seconds(n: in Double): Duration = ()

@externTarget("System.TimeSpan.FromMinutes")
pub func minutes(n: in Double): Duration = ()

@externTarget("System.TimeSpan.FromHours")
pub func hours(n: in Double): Duration = ()

@externTarget("System.TimeSpan.FromDays")
pub func days(n: in Double): Duration = ()

// =====================================================================
// Duration arithmetic.
//
// `op_Subtraction` between two `DateTime`s yields a `TimeSpan`.
// Lyric users see `since(later, earlier)` to avoid op-name surprise.
// =====================================================================

@externTarget("System.DateTime.op_Subtraction")
pub func since(later: in Instant, earlier: in Instant): Duration = ()

@externTarget("System.DateTime.op_Addition")
pub func plus(t: in Instant, d: in Duration): Instant = ()

// =====================================================================
// Inspection.
// =====================================================================

@externTarget("System.TimeSpan.TotalMilliseconds")
pub func totalMillis(d: in Duration): Double = ()

@externTarget("System.TimeSpan.TotalSeconds")
pub func totalSeconds(d: in Duration): Double = ()

// =====================================================================
// Calendar arithmetic.
//
// `addMonths` / `addYears` use BCL `DateTime.AddMonths` / `AddYears`
// semantics, which preserve day-of-month where possible
// (e.g. Jan 31 + 1 month → Feb 28 / 29) — that's a safer default
// than naive 30-day-per-month addition.  Returns the new `Instant`.
// =====================================================================

@externTarget("System.DateTime.AddMonths")
pub func addMonths(t: in Instant, n: in Int): Instant = ()

@externTarget("System.DateTime.AddYears")
pub func addYears(t: in Instant, n: in Int): Instant = ()

@externTarget("System.DateTime.AddDays")
pub func addDays(t: in Instant, n: in Double): Instant = ()

// =====================================================================
// Epoch conversions (Unix milliseconds <-> DateTime).
//
// Routes through `DateTimeOffset.FromUnixTimeMilliseconds` and
// `DateTimeOffset.UtcDateTime`, then back via `ToUnixTimeMilliseconds`.
// Matching extern aliases live alongside `Instant` so the user sees
// the conversion as a one-call operation.
// =====================================================================

extern type DateTimeOffset = "System.DateTimeOffset"

@externTarget("System.DateTimeOffset.FromUnixTimeMilliseconds")
pub func dtoFromEpochMillis(n: in Long): DateTimeOffset = ()

@externTarget("System.DateTimeOffset.FromUnixTimeSeconds")
pub func dtoFromEpochSeconds(n: in Long): DateTimeOffset = ()

@externTarget("System.DateTimeOffset.UtcDateTime")
pub func dtoUtcDateTime(d: in DateTimeOffset): Instant = ()

/// Construct an `Instant` from a Unix epoch-millis value.  Lyric-side
/// composes the two BCL calls so callers see a single helper.
pub func fromEpochMillis(n: in Long): Instant {
  dtoUtcDateTime(dtoFromEpochMillis(n))
}

/// Construct an `Instant` from a Unix epoch-seconds value.
pub func fromEpochSeconds(n: in Long): Instant {
  dtoUtcDateTime(dtoFromEpochSeconds(n))
}

// =====================================================================
// IANA / Windows timezone lookup.
//
// `System.TimeZoneInfo.FindSystemTimeZoneById` is the cross-platform
// IANA-name lookup on .NET Core+ (`America/New_York`, `Europe/London`
// etc. all resolve on Linux/macOS; on Windows it understands both
// IANA and Windows-style identifiers).  Returns `Result[TimeZone,
// IOError]` so users handle bad ids cleanly rather than catching
// the host's `TimeZoneNotFoundException`.
//
// Bootstrap-grade: only the lookup itself; the projection ops
// (UTC <-> zoned, DST detection) wait until programs need them.
// =====================================================================

extern type TimeZone = "System.TimeZoneInfo"

@externTarget("System.TimeZoneInfo.FindSystemTimeZoneById")
pub func hostFindTimeZone(id: in String): TimeZone = ()
