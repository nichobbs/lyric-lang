// std/time.l - time values, clocks, and timers.
//
// Time is split between pure value wrappers (Instant, Duration) and an
// injectable Clock interface. Code that needs testability should depend
// on Clock rather than constructing SystemClock internally.

@runtime_checked
package Std.Time

import Std.Errors
import Std.TimeHost as HostTime

pub opaque type Instant {
  handle: HostTime.InstantHandle
}

pub opaque type Duration {
  handle: HostTime.DurationHandle
}

pub interface Clock {
  func now(): Instant
}

pub opaque type SystemClock {
  marker: Unit
}

/// Construct the host-backed system clock.
///
/// This is explicit so application wires can inject it and tests can
/// substitute a stub Clock.
pub func SystemClock.make(): SystemClock {
  return SystemClock(marker = ())
}

/// Return the current UTC instant from the host clock.
pub func SystemClock.now(clock: in SystemClock): Instant {
  return Instant(handle = HostTime.nowUtc())
}

/// Parse an ISO 8601 instant.
///
/// # Preconditions as data
/// - `text` must be non-empty.
///
/// # Errors
/// - `InvalidFormat`: empty or invalid ISO 8601 text.
pub func Instant.fromIso8601(text: in String): Result[Instant, ParseError] {
  if text.length == 0 {
    return Err(error = InvalidFormat(input = text, expected = "ISO 8601 instant"))
  }

  return try {
    Ok(value = Instant(handle = HostTime.parseInstantIso8601(text)))
  } catch Bug as b {
    Err(error = InvalidFormat(input = text, expected = "ISO 8601 instant"))
  }
}

/// Format an instant as ISO 8601 UTC text.
@pure
pub func Instant.toIso8601(value: in Instant): String {
  return HostTime.instantToIso8601(value.handle)
}

/// Construct a non-negative duration from seconds.
pub func Duration.seconds(n: in Long): Duration
  requires: n >= 0
{
  return Duration.millis(n * 1000)
}

/// Construct a non-negative duration from milliseconds.
pub func Duration.millis(n: in Long): Duration
  requires: n >= 0
{
  return Duration(handle = HostTime.durationFromMillis(n))
}

/// Return the total whole milliseconds in a duration.
@pure
pub func Duration.totalMillis(value: in Duration): Long {
  return HostTime.durationTotalMillis(value.handle)
}

/// Sleep asynchronously for a duration.
///
/// Timer failures are host Bugs at the moment; cancellation-aware sleep
/// belongs with Phase 5 cancellation-token work.
pub async func Timer.sleepAsync(d: in Duration): Unit {
  await HostTime.sleep(d.handle)
}
