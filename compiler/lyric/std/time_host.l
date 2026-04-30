// std/time_host.l - trusted host boundary for clocks and timers.
//
// Public time APIs avoid a hidden global clock by exposing SystemClock
// as an explicit value that can be injected where needed.

@axiom("System time and timer operations conform to their documented .NET contracts")
package Std.TimeHost

extern package System.Time {
  pub exposed type InstantHandle
  pub exposed type DurationHandle

  pub func nowUtc(): InstantHandle

  pub func parseInstantIso8601(text: in String): InstantHandle
    requires: text.length > 0

  pub func instantToIso8601(value: in InstantHandle): String

  pub func durationFromMillis(ms: in Long): DurationHandle
    requires: ms >= 0

  pub func durationTotalMillis(value: in DurationHandle): Long

  pub async func sleep(value: in DurationHandle): Unit
}
