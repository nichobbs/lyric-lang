// std/_kernel_jvm/testing_mocking.l - JVM host boundary for test-mocking
// helpers.
//
// Mirrors _kernel/testing_mocking.l for the JVM target.  The
// StubCounter type and all host methods are provided by
// lyric.stdlib.jvm.StubCounter / StubCounterHost, which are
// functionally identical to Lyric.Stdlib.StubCounter on .NET.
// (The counter is a plain AtomicInteger wrapped in a final class.)
package Std.Testing.Mocking

extern type StubCounter = "lyric.stdlib.jvm.StubCounter"

/// Construct a fresh call-counter starting at 0.
@externTarget("lyric.stdlib.jvm.StubCounterHost.make")
pub func makeStubCounter(): StubCounter = ()

/// Increment the counter by one.
@externTarget("lyric.stdlib.jvm.StubCounterHost.increment")
pub func stubCounterIncrement(c: in StubCounter): Unit = ()

/// Read the current count.
@externTarget("lyric.stdlib.jvm.StubCounterHost.get")
pub func stubCounterGet(c: in StubCounter): Int = ()

/// Reset the counter to 0.
@externTarget("lyric.stdlib.jvm.StubCounterHost.reset")
pub func stubCounterReset(c: in StubCounter): Unit = ()
