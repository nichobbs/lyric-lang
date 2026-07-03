//! std/_kernel_native/time_host.l — native-target clock boundary.
//!
//! The `--target native` twin of `_kernel/time_host.l`, selected by the
//! native source loader by basename.  Implements the exception-free
//! clock seams (issue #4752) that `Std.Time` delegates to, over the
//! audited lyric-rt helpers (CLOCK_REALTIME / CLOCK_MONOTONIC) and
//! usleep(3).
//!
//! Scope: the epoch/monotonic seams and synchronous sleep.  The
//! calendar surface (`Instant` / `Duration` / `DateTimeOffset` /
//! `TimeZone` and their arithmetic) wraps .NET types with no native
//! representation yet (issue #4752); the `Std.Time` functions built on
//! it stay compile-time-unreachable on native until then.
@axiom("POSIX clock and sleep calls via lyric-rt conform to their documented contracts")
package Std.TimeHost

extern func rtEpochMillis(): Long = "lyric_epoch_millis"

extern func rtMonotonicNanos(): Long = "lyric_monotonic_nanos"

extern func cUsleep(us: Int): Int = "usleep"

pub func hostEpochMillis(): Long {
  rtEpochMillis()
}

pub func hostMonotonicNanos(): Long {
  rtMonotonicNanos()
}

pub func hostSleepMillis(ms: in Int): Unit {
  // usleep(3) rejects arguments of one second or more on some
  // platforms, so sleep in 500 ms slices.
  var remaining = ms
  while remaining > 0 {
    var chunk = remaining
    if chunk > 500 {
      chunk = 500
    }
    val _ignored = cUsleep(chunk * 1000)
    remaining = remaining - chunk
  }
}
