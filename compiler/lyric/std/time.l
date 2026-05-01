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
