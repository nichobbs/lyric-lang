//! std/_kernel_native/bench_host.l - host boundary for `Std.Bench` on native.
//!
//! Internal: only `Std.Bench` imports this.
@axiom("lyric_rt_allocated_bytes counts the bytes this thread requested through lyric_alloc")
@io
package Std.BenchHost

import Std.Core

extern func rtAllocatedBytes(): Long = "lyric_rt_allocated_bytes"

/// Bytes this thread has allocated through the runtime (`lyric_alloc`).
pub func hostAllocatedBytes(): Long = rtAllocatedBytes()
