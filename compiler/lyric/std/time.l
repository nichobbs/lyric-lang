// std/time.l - Time and date primitives.
//
// User-facing wrappers over `Std.TimeHost` (in `_kernel/`), which
// owns the trusted boundary against `System.DateTime`,
// `System.TimeSpan`, `System.DateTimeOffset`, and
// `System.TimeZoneInfo`.  See `docs/14-native-stdlib-plan.md` §6 P0/4.
//
// All times are UTC unless stated otherwise.  The wrappers
// deliberately avoid local-time conversion to keep behaviour
// reproducible across machines.

package Std.Time

import Std.Core
import Std.TimeHost     // brings `Instant`, `Duration`, … and `host*` fns into scope

// =====================================================================
// Construction.
// =====================================================================

/// Current UTC time.
pub func now(): Instant { hostNow() }

/// `TimeSpan.Zero` — useful as a fold initial value.
pub func zeroDuration(): Duration { hostZeroDuration() }

/// Parse an ISO-8601-ish timestamp; returns `None` if the BCL refuses.
pub func parseOptInstant(s: in String): Option[Instant] {
  var v: Instant = default()
  if hostTryParseInstant(s, v) { Some(value = v) } else { None }
}

// =====================================================================
// Duration constructors (in fractional milliseconds, seconds, etc.).
// =====================================================================

pub func millis(n: in Double): Duration  { hostMillis(n) }
pub func seconds(n: in Double): Duration { hostSeconds(n) }
pub func minutes(n: in Double): Duration { hostMinutes(n) }
pub func hours(n: in Double): Duration   { hostHours(n) }
pub func days(n: in Double): Duration    { hostDays(n) }

// =====================================================================
// Duration arithmetic.
//
// `op_Subtraction` between two `DateTime`s yields a `TimeSpan`.
// Lyric users see `since(later, earlier)` to avoid op-name surprise.
// =====================================================================

pub func since(later: in Instant, earlier: in Instant): Duration {
  hostSince(later, earlier)
}

pub func plus(t: in Instant, d: in Duration): Instant {
  hostPlus(t, d)
}

// =====================================================================
// Inspection.
// =====================================================================

pub func totalMillis(d: in Duration): Double  { hostTotalMillis(d) }
pub func totalSeconds(d: in Duration): Double { hostTotalSeconds(d) }

// =====================================================================
// Calendar arithmetic.
//
// `addMonths` / `addYears` use BCL `DateTime.AddMonths` / `AddYears`
// semantics, which preserve day-of-month where possible
// (e.g. Jan 31 + 1 month → Feb 28 / 29) — that's a safer default
// than naive 30-day-per-month addition.  Returns the new `Instant`.
// =====================================================================

pub func addMonths(t: in Instant, n: in Int): Instant {
  hostAddMonths(t, n)
}

pub func addYears(t: in Instant, n: in Int): Instant {
  hostAddYears(t, n)
}

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

pub func dtoFromEpochMillis(n: in Long): DateTimeOffset {
  hostDtoFromEpochMillis(n)
}

pub func dtoFromEpochSeconds(n: in Long): DateTimeOffset {
  hostDtoFromEpochSeconds(n)
}

pub func dtoUtcDateTime(d: in DateTimeOffset): Instant {
  hostDtoUtcDateTime(d)
}

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

pub func findTimeZone(id: in String): TimeZone {
  hostFindTimeZone(id)
}

// =====================================================================
// Comparison.
//
// `DateTime.op_LessThan` / `op_GreaterThan` resolve via auto-FFI
// when the user writes `a < b` on `Instant` values, but the named
// helpers below are clearer in code and match `Duration` shape
// where operators don't always lower cleanly.
// =====================================================================

pub func instantBefore(a: in Instant, b: in Instant): Bool {
  hostInstantBefore(a, b)
}

pub func instantAfter(a: in Instant, b: in Instant): Bool {
  hostInstantAfter(a, b)
}

pub func instantEquals(a: in Instant, b: in Instant): Bool {
  hostInstantEquals(a, b)
}

pub func durationLess(a: in Duration, b: in Duration): Bool {
  hostDurationLess(a, b)
}

pub func durationGreater(a: in Duration, b: in Duration): Bool {
  hostDurationGreater(a, b)
}

pub func addDurations(a: in Duration, b: in Duration): Duration {
  hostAddDurations(a, b)
}

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
pub func toIsoString(t: in Instant): String {
  hostInstantToString(t)
}
