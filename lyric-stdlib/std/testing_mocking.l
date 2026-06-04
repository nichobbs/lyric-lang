//! std/testing_mocking.l — D-progress-123 (G7 StubCounter codegen)
//!
//! StubCounter is now a native Lyric `protected type` instead of the
//! F# shim `Lyric.Stdlib.StubCounter` / `StubCounterHost`.  The public
//! API (makeStubCounter, stubCounterIncrement, stubCounterGet,
//! stubCounterReset) is identical to the extern version so all call
//! sites continue to work without change.
//!
//! Resolution order: the import resolver checks top-level stdlib files
//! before `_kernel/`, so this file shadows `_kernel/testing_mocking.l`
//! on the .NET target (the JVM kernel file is still live for JVM).
//!
//! Typical usage:
//!
//!   @stubbable
//!   pub interface Clock {
//!     pub func now(): Long
//!   }
//!
//!   func main(): Unit {
//!     val ticks = makeStubCounter()
//!     val clock = ClockStub(now_value = 1000, now_counter = ticks)
//!     val _ = clock.now()
//!     val _ = clock.now()
//!     println(toString(stubCounterGet(ticks)))   // prints "2"
//!   }
package Std.Testing.Mocking

/// Thread-safe call counter for @stubbable mocking.  Each stub
/// method's auto-synthesised body increments its counter on entry;
/// tests read the counter at the end to assert the expected call count.
@stable(since = "1.0")
pub protected type StubCounter {
  var count: Int = 0
  entry increment() {
    count = count + 1
  }
  entry reset() {
    count = 0
  }
  func get(): Int {
    return count
  }
}

/// Construct a fresh call-counter starting at 0.
@stable(since = "1.0")
pub func makeStubCounter(): StubCounter {
  return StubCounter()
}

/// Increment the counter by one.  The auto-synthesised stub method
/// bodies call this internally; tests rarely need it directly.
@stable(since = "1.0")
pub func stubCounterIncrement(c: in StubCounter): Unit {
  c.increment()
}

/// Read the current count.  Use in test assertions:
///
///     assertEqualInt(stubCounterGet(ticks), 3, "now() called 3 times")
@stable(since = "1.0")
pub func stubCounterGet(c: in StubCounter): Int {
  return c.get()
}

/// Reset the counter back to 0.  Useful when reusing a stub across
/// multiple test scenarios within one process.
@stable(since = "1.0")
pub func stubCounterReset(c: in StubCounter): Unit {
  c.reset()
}
