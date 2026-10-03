//! std/_kernel/bench_host.l - host boundary for `Std.Bench` on dotnet.
//!
//! Internal: only `Std.Bench` imports this.
@axiom("System.GC.GetAllocatedBytesForCurrentThread conforms to its documented .NET contract")
@io
package Std.BenchHost

import Std.Core

extern type NetGC = "System.GC"

/// Bytes allocated on the managed heap by the current thread.
pub func hostAllocatedBytes(): Long = NetGC.GetAllocatedBytesForCurrentThread()
