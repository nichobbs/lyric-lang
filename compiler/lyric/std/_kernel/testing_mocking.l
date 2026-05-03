// std/testing_mocking.l — Phase 4 / D-progress-073.
//
// Test-mocking helpers built on top of `@stubbable`.  The
// auto-synthesised stub records carry one `<method>_counter` field
// per non-Unit method; tests can read the counter after exercising
// the stub to assert the dependency was called the expected number
// of times.  Pair with `Std.Testing.assertEqualInt`.
//
// Bootstrap-grade scope:
//   * Counter only — no per-call argument capture, no replay-on-
//     n-th-call mode (Phase 4 follow-ups).
//   * `Stub.failing(...)` (panic-on-call) lives in a future
//     revision; today's `_value` field can be set to a default
//     value plus a separate `_should_fail` Bool gating panic.
//
// Typical usage:
//
//   @stubbable
//   pub interface Clock {
//     pub func now(): Long
//   }
//
//   func main(): Unit {
//     val ticks = makeStubCounter()
//     val clock = ClockStub(now_value = 1000, now_counter = ticks)
//     val _ = clock.now()
//     val _ = clock.now()
//     println(toString(stubCounterGet(ticks)))   // prints "2"
//   }
package Std.Testing.Mocking

extern type StubCounter = "Lyric.Stdlib.StubCounter"

/// Construct a fresh call-counter starting at 0.
@externTarget("Lyric.Stdlib.StubCounterHost.Make")
pub func makeStubCounter(): StubCounter = ()

/// Increment the counter by one.  The auto-synthesised stub method
/// bodies call this internally; tests rarely need it directly.
@externTarget("Lyric.Stdlib.StubCounterHost.Increment")
pub func stubCounterIncrement(c: in StubCounter): Unit = ()

/// Read the current count.  Use in test assertions:
///
///     assertEqualInt(stubCounterGet(ticks), 3, "now() called 3 times")
@externTarget("Lyric.Stdlib.StubCounterHost.Get")
pub func stubCounterGet(c: in StubCounter): Int = ()

/// Reset the counter back to 0.  Useful when reusing a stub across
/// multiple test scenarios within one process.
@externTarget("Lyric.Stdlib.StubCounterHost.Reset")
pub func stubCounterReset(c: in StubCounter): Unit = ()
